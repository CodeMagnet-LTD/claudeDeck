import AppKit
import ClaudeDeckCore
import Observation
import SwiftUI

/// One file open in the built-in editor. The text itself lives in the NSTextView (a copy per
/// keystroke would be too slow for big files); this tracks load state, dirtiness and the disk copy.
@MainActor
@Observable
final class EditorDocument {
    enum State: Equatable {
        case loading
        case loaded
        case failed(TextFileError)
    }

    enum DiskChange: Equatable {
        case modified
        case deleted
    }

    let url: URL
    let language: SyntaxLanguage
    private(set) var state: State = .loading
    private(set) var isDirty = false {
        didSet { textView?.window?.isDocumentEdited = isDirty }
    }
    private(set) var isSaving = false
    private(set) var saveError: String?
    /// Set while the file changed on disk under unsaved edits (the "Reload / Keep Mine" bar).
    var diskChange: DiskChange?
    private(set) var caret = (line: 1, column: 1, selectedLines: 0)
    private(set) var indentation = Indentation()
    private(set) var lineEnding: LineEnding = .lf

    @ObservationIgnored private(set) var initialText = ""
    @ObservationIgnored private var hasBOM = false
    /// The file's text as last read from or written to disk ("\n" line endings).
    @ObservationIgnored private var diskText: String?
    @ObservationIgnored private var editGeneration = 0
    @ObservationIgnored private weak var textView: CodeTextView?
    @ObservationIgnored private weak var colorizer: SyntaxColorizer?
    @ObservationIgnored private var watcher: FileChangeWatcher?
    @ObservationIgnored private var applyingExternalText = false

    init(url: URL) {
        self.url = url
        language = SyntaxLanguage.detect(fileName: url.lastPathComponent)
        EditorRegistry.register(self)
    }

    var lineEndingLabel: String { lineEnding == .crlf ? "CRLF" : "LF" }

    func load() async {
        let url = self.url
        let result = await Task.detached { () -> Result<TextFileContents, TextFileError> in
            do { return .success(try TextFileIO.read(url)) } catch { return .failure(error as? TextFileError ?? .io(error.localizedDescription)) }
        }.value
        switch result {
        case .success(let contents):
            initialText = contents.text
            diskText = contents.text
            lineEnding = contents.lineEnding
            hasBOM = contents.hasBOM
            indentation = Indentation.detect(contents.text)
            state = .loaded
            startWatching()
        case .failure(let error):
            state = .failed(error)
        }
    }

    func attach(_ textView: CodeTextView, colorizer: SyntaxColorizer) {
        self.textView = textView
        self.colorizer = colorizer
    }

    func close() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: Editing

    func noteEdit() {
        guard !applyingExternalText else { return }
        editGeneration += 1
        if !isDirty { isDirty = true }
    }

    func updateCaret(_ range: NSRange) {
        guard let lines = colorizer?.lines else { return }
        let line = lines.line(containing: range.location)
        let column = range.location - lines.starts[line] + 1
        let lastLine = lines.line(containing: max(range.location, NSMaxRange(range) - 1))
        caret = (line + 1, column, range.length > 0 ? lastLine - line + 1 : 0)
    }

    /// 1-based line numbers of the selection, if any text is selected.
    var selectedLineRange: ClosedRange<Int>? {
        guard let textView, let lines = colorizer?.lines else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        var last = lines.line(containing: NSMaxRange(range) - 1)
        let first = lines.line(containing: range.location)
        // A selection ending right after a newline doesn't include the next line.
        if last > first, lines.starts[last] == NSMaxRange(range) { last -= 1 }
        return (first + 1)...(last + 1)
    }

    // MARK: Saving

    func save() {
        guard state == .loaded, let textView, !isSaving else { return }
        let contents = TextFileContents(text: textView.string, lineEnding: lineEnding, hasBOM: hasBOM)
        let generation = editGeneration
        let url = self.url
        isSaving = true
        Task {
            let error = await Task.detached { () -> TextFileError? in
                do { try TextFileIO.write(contents, to: url); return nil } catch { return error as? TextFileError ?? .io(error.localizedDescription) }
            }.value
            isSaving = false
            if let error {
                saveError = error.message
                FileActions.fail(error.message)
                return
            }
            saveError = nil
            diskText = contents.text
            diskChange = nil
            if editGeneration == generation { isDirty = false }
            if watcher == nil { startWatching() }
        }
    }

    /// Synchronous save for quit / close confirmation. Returns false on failure.
    @discardableResult
    func saveNow() -> Bool {
        guard state == .loaded, let textView else { return true }
        let contents = TextFileContents(text: textView.string, lineEnding: lineEnding, hasBOM: hasBOM)
        do {
            try TextFileIO.write(contents, to: url)
        } catch {
            FileActions.fail(error.message)
            return false
        }
        diskText = contents.text
        isDirty = false
        return true
    }

    // MARK: External changes

    private func startWatching() {
        let watcher = FileChangeWatcher(url: url) { [weak self] in
            Task { @MainActor in await self?.checkDisk() }
        }
        watcher.start()
        self.watcher = watcher
    }

    func checkDisk() async {
        guard state == .loaded else { return }
        let url = self.url
        let result = await Task.detached { () -> Result<TextFileContents, TextFileError> in
            do { return .success(try TextFileIO.read(url)) } catch { return .failure(error as? TextFileError ?? .io(error.localizedDescription)) }
        }.value
        switch result {
        case .success(let contents):
            guard contents.text != diskText else { return } // our own save, or a touch
            if isDirty {
                diskChange = .modified
            } else {
                replaceText(with: contents)
            }
        case .failure:
            if !FileManager.default.fileExists(atPath: url.path) {
                diskChange = .deleted
                // Unsaved from now on: saving recreates the file.
                isDirty = true
            }
        }
    }

    /// "Reload" in the changed-on-disk bar: drop local edits.
    func reloadFromDisk() {
        Task {
            let url = self.url
            guard let contents = try? await Task.detached(operation: { try TextFileIO.read(url) }).value else { return }
            replaceText(with: contents)
        }
    }

    /// "Keep Mine": stay dirty; the next save overwrites the disk copy.
    func keepMine() {
        diskChange = nil
        Task {
            let url = self.url
            if let contents = try? await Task.detached(operation: { try TextFileIO.read(url) }).value {
                diskText = contents.text
            }
        }
    }

    private func replaceText(with contents: TextFileContents) {
        diskText = contents.text
        lineEnding = contents.lineEnding
        hasBOM = contents.hasBOM
        diskChange = nil
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let scroll = textView.enclosingScrollView?.contentView.bounds.origin
        applyingExternalText = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: contents.text)
        storage.setAttributes(textView.typingAttributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textView.undoManager?.removeAllActions()
        applyingExternalText = false
        isDirty = false
        let length = storage.length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        if let scroll { textView.enclosingScrollView?.contentView.scroll(to: scroll) }
        colorizer?.rebuild()
    }

    // MARK: Claude

    /// `@path` (relative to the session's directory when inside it), plus `#Lx-y` for a selection.
    func mention(relativeTo root: URL?) -> String {
        var path = root.map { FileListing.relativePath(of: url, in: $0) } ?? url.path
        if path.contains(" ") { path = "\"\(path)\"" }
        guard let lines = selectedLineRange else { return "@" + path }
        let suffix = lines.lowerBound == lines.upperBound ? "#L\(lines.lowerBound)" : "#L\(lines.lowerBound)-\(lines.upperBound)"
        return "@" + path + suffix
    }
}

/// Open editor documents, for quit / background confirmation.
@MainActor
enum EditorRegistry {
    private final class Box { weak var document: EditorDocument?; init(_ d: EditorDocument) { document = d } }
    private static var boxes: [Box] = []
    static let tabbingIdentifier = "ClaudeDeckEditor"

    static func register(_ document: EditorDocument) {
        boxes.removeAll { $0.document == nil }
        boxes.append(Box(document))
    }

    static var dirtyDocuments: [EditorDocument] { boxes.compactMap(\.document).filter(\.isDirty) }

    static func isEditorWindow(_ window: NSWindow?) -> Bool { window?.tabbingIdentifier == tabbingIdentifier }

    /// Before quitting: asks about unsaved files. False = cancel the quit.
    static func confirmQuit() -> Bool {
        let dirty = dirtyDocuments
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = dirty.count == 1
            ? String(localized: "Save changes to “\(dirty[0].url.lastPathComponent)”?")
            : String(localized: "You have unsaved changes in \(dirty.count) files.")
        alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: String(localized: "Save All"))
        alert.addButton(withTitle: String(localized: "Don’t Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[1].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return dirty.allSatisfy { $0.saveNow() }
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    /// Editor font zoom (⌘+ / ⌘- / ⌘0 while an editor window is key).
    static func zoom(by step: Double?, model: AppModel) {
        model.mutate { deck in
            let range = DeckSettings.fontSizeRange
            deck.settings.editorFontSize = step.map { min(max(deck.settings.editorFontSize + $0, range.lowerBound), range.upperBound) }
                ?? DeckSettings.defaultFontSize
        }
    }
}

/// Opening files: the built-in editor for text files when enabled, otherwise the old behaviour.
@MainActor
enum EditorOpener {
    static func open(_ url: URL, openWindow: OpenWindowAction) {
        openWindow(id: "editor", value: url.standardizedFileURL)
    }

    /// Double-click in the Files panel.
    static func openDefault(_ url: URL, model: AppModel, openWindow: OpenWindowAction) {
        // .pen files belong to Pen.app even though they may look like text.
        if model.deck.settings.openFilesInBuiltInEditor, !PencilApp.isPenFile(url), TextFileIO.looksEditable(url) {
            open(url, openWindow: openWindow)
        } else {
            FileActions.openDefault(url)
        }
    }
}

// MARK: - ⌘S

struct EditorDocumentKey: FocusedValueKey {
    typealias Value = EditorDocument
}

extension FocusedValues {
    var editorDocument: EditorDocument? {
        get { self[EditorDocumentKey.self] }
        set { self[EditorDocumentKey.self] = newValue }
    }
}

struct EditorCommands: Commands {
    @FocusedValue(\.editorDocument) private var document

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") { document?.save() }
                .keyboardShortcut("s")
                .disabled(document == nil)
        }
    }
}

// MARK: - Window

struct EditorWindowView: View {
    let url: URL?

    var body: some View {
        if let url {
            EditorContent(document: EditorDocument(url: url))
        } else {
            Text("No file").foregroundStyle(.secondary).frame(minWidth: 400, minHeight: 300)
        }
    }
}

private struct EditorContent: View {
    @Environment(AppModel.self) private var model
    @State var document: EditorDocument

    var body: some View {
        VStack(spacing: 0) {
            switch document.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if let change = document.diskChange { diskBar(change) }
                CodeEditorView(document: document, fontSize: model.deck.settings.editorFontSize, wrapLines: model.deck.settings.editorWrapLines)
                Divider()
                statusBar
            case .failed(let error):
                unavailable(error)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .navigationTitle(document.url.lastPathComponent)
        .navigationSubtitle((document.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        .toolbar { toolbar }
        .focusedSceneValue(\.editorDocument, document)
        .background(EditorWindowConfigurator(document: document))
        .task { if document.state == .loading { await document.load() } }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: Binding(
                get: { model.deck.settings.editorWrapLines },
                set: { on in model.mutate { $0.settings.editorWrapLines = on } }
            )) {
                Label("Wrap Lines", systemImage: "text.word.spacing")
            }
            .help("Wrap Lines")
            Button {
                addToClaude()
            } label: {
                Label("Add to Claude", systemImage: "at")
            }
            .help(claudeHelp)
            .disabled(targetSession == nil || document.state != .loaded)
            if VSCode.isInstalled {
                Button {
                    VSCode.open(document.url)
                } label: {
                    Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help("Open in VS Code")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([document.url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Reveal in Finder")
        }
    }

    /// The selected session, if its terminal is running.
    private var targetSession: DeckSession? {
        guard let id = model.selectedSessionID, model.terminals.isRunning(id) else { return nil }
        return model.deck.session(id)
    }

    private var claudeHelp: String {
        guard let session = targetSession else { return String(localized: "Select a running session to add this file to it") }
        return String(localized: "Insert @\(document.url.lastPathComponent) into “\(session.name)” (with line numbers when text is selected)")
    }

    private func addToClaude() {
        guard let session = targetSession else { return }
        let root = session.workingDirectory ?? model.deck.project(session.projectID)?.path
        let mention = document.mention(relativeTo: root.map { URL(fileURLWithPath: $0) })
        model.terminals.type(mention + " ", into: session.id)
    }

    // MARK: Bars

    private func diskBar(_ change: EditorDocument.DiskChange) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(change == .deleted ? "The file was deleted on disk. Saving will recreate it." : "The file changed on disk.")
                .font(.callout)
            Spacer()
            if change == .modified {
                Button("Reload") { document.reloadFromDisk() }
                Button("Keep Mine") { document.keepMine() }
            } else {
                Button("OK") { document.diskChange = nil }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12))
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            let caret = document.caret
            if caret.selectedLines > 0 {
                Text("Line \(caret.line), Column \(caret.column) (\(caret.selectedLines) lines selected)")
            } else {
                Text("Line \(caret.line), Column \(caret.column)")
            }
            Spacer()
            Text(document.indentation.usesTabs ? String(localized: "Tabs") : String(localized: "Spaces: \(document.indentation.width)"))
            Text(verbatim: document.lineEndingLabel)
            Text(verbatim: document.language == .plain ? String(localized: "Plain Text") : document.language.displayName)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func unavailable(_ error: TextFileError) -> some View {
        VStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: document.url.path))
                .resizable().frame(width: 64, height: 64)
            Text("Can’t open this file in the editor").font(.headline)
            Text(error.message).foregroundStyle(.secondary)
            HStack {
                Button("Open with Default App") { NSWorkspace.shared.open(document.url) }
                if VSCode.isInstalled {
                    Button("Open in VS Code") { VSCode.open(document.url) }
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension SyntaxLanguage {
    var displayName: String {
        switch self {
        case .plain: "Plain Text"
        case .swift: "Swift"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .json: "JSON"
        case .python: "Python"
        case .go: "Go"
        case .rust: "Rust"
        case .shell: "Shell"
        case .yaml: "YAML"
        case .markdown: "Markdown"
        case .html: "HTML / XML"
        case .css: "CSS"
        case .c: "C-family"
        }
    }
}

// MARK: - NSWindow glue

/// Hooks the hosting NSWindow: native tabbing for editor windows, the edited dot, the proxy icon,
/// and a "save changes?" question before closing.
private struct EditorWindowConfigurator: NSViewRepresentable {
    let document: EditorDocument

    func makeCoordinator() -> CloseGuard { CloseGuard(document: document) }

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingView()
        view.onWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.install(on: window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        if window.isDocumentEdited != document.isDirty { window.isDocumentEdited = document.isDirty }
        // SwiftUI may replace the window delegate after the first show; put the close guard back.
        if window.delegate !== context.coordinator { context.coordinator.install(on: window) }
    }

    final class WindowObservingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    /// Wraps SwiftUI's window delegate: forwards everything, but asks before closing a dirty file.
    @MainActor
    final class CloseGuard: NSObject, NSWindowDelegate {
        let document: EditorDocument
        nonisolated(unsafe) weak var original: NSWindowDelegate?
        private weak var window: NSWindow?
        nonisolated(unsafe) private var closeObserver: NSObjectProtocol?

        init(document: EditorDocument) { self.document = document }

        deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }

        func install(on window: NSWindow) {
            if self.window === window {
                if window.delegate !== self { original = window.delegate; window.delegate = self }
                return
            }
            self.window = window
            window.tabbingIdentifier = EditorRegistry.tabbingIdentifier
            window.tabbingMode = .preferred
            window.representedURL = document.url
            if window.delegate !== self {
                original = window.delegate
                window.delegate = self
            }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.document.close() }
            }
            // Join an existing editor window as a tab (opening from the main window would otherwise
            // make a separate window).
            DispatchQueue.main.async { [weak window] in
                MainActor.assumeIsolated {
                    guard let window, (window.tabbedWindows?.count ?? 1) <= 1 else { return }
                    let host = NSApp.orderedWindows.first {
                        $0 !== window && EditorRegistry.isEditorWindow($0) && $0.isVisible
                    }
                    guard let host else { return }
                    host.addTabbedWindow(window, ordered: .above)
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard document.isDirty else { return original?.windowShouldClose?(sender) ?? true }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Save changes to “\(document.url.lastPathComponent)”?")
            alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.")
            alert.addButton(withTitle: String(localized: "Save"))
            alert.addButton(withTitle: String(localized: "Don’t Save"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.buttons[1].hasDestructiveAction = true
            alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
                MainActor.assumeIsolated {
                    guard let self, let sender else { return }
                    switch response {
                    case .alertFirstButtonReturn:
                        guard self.document.saveNow() else { return }
                    case .alertSecondButtonReturn:
                        break
                    default:
                        return
                    }
                    self.document.discardForClose()
                    sender.close()
                }
            }
            return false
        }

        nonisolated override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            if let original, original.responds(to: selector) { return original }
            return super.forwardingTarget(for: selector)
        }
    }
}

extension EditorDocument {
    /// Closing without saving: stop asking (quit confirmation, window close).
    func discardForClose() {
        isDirty = false
        close()
    }
}
