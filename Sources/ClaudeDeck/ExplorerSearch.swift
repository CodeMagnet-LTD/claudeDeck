import AppKit
import ClaudeDeckCore
import SwiftUI

extension AppModel {
    /// The project the Files panel, Quick Open and Find in Files work on: a project clicked in the
    /// sidebar, else the focused session's project (rooted at its worktree for worktree sessions).
    var explorerProject: Project? {
        let selected = selectedSessionID.flatMap { deck.session($0) }
        if let browsed = browsedProjectID, let p = deck.project(browsed), selected?.projectID != browsed {
            return p
        }
        guard var project = selected.flatMap({ deck.project($0.projectID) }) else { return deck.projects.first }
        if let wd = selected?.workingDirectory, FileManager.default.fileExists(atPath: wd) { project.path = wd }
        return project
    }

    /// The selected session, if its terminal is running (target of "insert @path").
    var insertTargetSession: UUID? {
        selectedSessionID.flatMap { terminals.isRunning($0) ? $0 : nil }
    }
}

/// File menu: Quick Open (⌘P, replaces Print) and Find in Files (⌘⇧F).
struct ExplorerCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Quick Open…") { ExplorerSheets.quickOpen(model: model) }
                .keyboardShortcut("p")
            Button("Find in Files…") { ExplorerSheets.findInFiles(model: model) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}

/// Presents the explorer sheets on the main window. AppKit sheets (not SwiftUI `.sheet`): the
/// Files inspector that would host them may be closed. Non-modal: terminals keep running.
@MainActor
enum ExplorerSheets {
    static let identifier = NSUserInterfaceItemIdentifier("ClaudeDeckExplorerSheet")

    static func quickOpen(model: AppModel) {
        guard let root = model.explorerProject.map({ URL(fileURLWithPath: $0.path) }) else { return }
        present(size: NSSize(width: 600, height: 420), model: model) { close in QuickOpenView(root: root, close: close) }
    }

    static func findInFiles(model: AppModel) {
        guard let root = model.explorerProject.map({ URL(fileURLWithPath: $0.path) }) else { return }
        present(size: NSSize(width: 720, height: 520), model: model) { close in FindInFilesView(root: root, close: close) }
    }

    private static func present<V: View>(size: NSSize, model: AppModel, _ make: (@escaping () -> Void) -> V) {
        guard let parent = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.isMainWindow })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        if let existing = parent.attachedSheet {
            guard existing.identifier == identifier else { return }
            parent.endSheet(existing)
        }
        removeKeyMonitor()
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        sheet.identifier = identifier
        sheet.minSize = NSSize(width: 420, height: 280)
        let close = { [weak parent, weak sheet] in
            guard let parent, let sheet else { return }
            parent.endSheet(sheet)
        }
        sheet.contentViewController = NSHostingController(rootView: make(close).environment(model))
        sheet.setContentSize(size)
        installKeyMonitor(for: sheet)
        parent.beginSheet(sheet) { _ in removeKeyMonitor() }
    }

    // MARK: Keys

    /// Keys the sheets handle themselves while the text field keeps focus.
    enum Key { case up, down, enter(option: Bool), escape }
    /// Set by the presented view (`SheetKeys`); returns true when it consumed the key.
    static var keyHandler: ((Key) -> Bool)?
    private static var keyMonitor: Any?

    /// One monitor at a time, owned here (not by the view) so it never outlives its sheet.
    private static func installKeyMonitor(for sheet: NSWindow) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak sheet] event in
            guard let sheet, event.window === sheet else { return event }
            let key: Key? = switch event.keyCode {
            case 126: .up
            case 125: .down
            case 36, 76: .enter(option: event.modifierFlags.contains(.option))
            case 53: .escape
            default: nil
            }
            guard let key else { return event }
            return MainActor.assumeIsolated { keyHandler?(key) ?? false } ? nil : event
        }
    }

    private static func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        keyHandler = nil
    }
}

/// Routes the sheet's arrow / Return (⌥ for the alternate action) / Escape keys to `handle`.
private struct SheetKeys: ViewModifier {
    typealias Key = ExplorerSheets.Key
    let handle: @MainActor (Key) -> Bool

    func body(content: Content) -> some View {
        content.onAppear { ExplorerSheets.keyHandler = handle }
    }
}

// MARK: - Quick Open

struct QuickOpenView: View {
    @Environment(AppModel.self) private var model
    let root: URL
    let close: () -> Void
    @State private var query = ""
    @State private var files: [String]?
    @State private var results: [FuzzyMatch.Result] = []
    @State private var selected = 0
    @State private var rankTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search files by name", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(results.enumerated()), id: \.element.path) { index, result in
                        QuickOpenRow(result: result, selected: index == selected)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = index; open(option: NSEvent.modifierFlags.contains(.option)) }
                            .listRowBackground(index == selected ? Color.accentColor.opacity(0.22) : Color.clear)
                    }
                }
                .listStyle(.plain)
                .onChange(of: selected) { _, index in proxy.scrollTo(index) }
            }
            .overlay {
                if files == nil { ProgressView().controlSize(.small) }
                else if results.isEmpty { Text("No matching files").foregroundStyle(.secondary) }
            }
            Divider()
            footer
        }
        .onAppear { fieldFocused = true }
        .task {
            let root = self.root
            files = await Task.detached {
                // ls-files -c also lists tracked files deleted from disk.
                Git.listFiles(in: root)?.filter { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }
                    ?? FileListing.walk(root)
            }.value
            rank()
        }
        .onChange(of: query) { _, _ in rank() }
        .modifier(SheetKeys { key in
            switch key {
            case .up: selected = max(0, selected - 1)
            case .down: selected = min(max(results.count - 1, 0), selected + 1)
            case .enter(let option): open(option: option)
            case .escape: close()
            }
            return true
        })
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("↵ Open")
            if model.insertTargetSession != nil { Text("⌥↵ Add to Claude") }
            Spacer()
            if let files { Text("\(files.count) files") }
            Button("Close", action: close)
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func rank() {
        rankTask?.cancel()
        guard let files else { return }
        let query = self.query
        rankTask = Task {
            let ranked = await Task.detached(priority: .userInitiated) {
                query.isEmpty ? files.prefix(200).map { FuzzyMatch.Result(path: $0, score: 0, positions: []) }
                    : FuzzyMatch.rank(query, paths: files)
            }.value
            guard !Task.isCancelled else { return }
            results = ranked
            selected = 0
        }
    }

    private func open(option: Bool) {
        guard results.indices.contains(selected) else { return }
        let url = root.appending(path: results[selected].path)
        if option {
            guard let session = model.insertTargetSession else { return }
            model.insertPaths([url], into: session)
        } else {
            EditorOpener.openDefault(url, model: model)
        }
        close()
    }
}

private struct QuickOpenRow: View {
    let result: FuzzyMatch.Result
    let selected: Bool

    var body: some View {
        let name = (result.path as NSString).lastPathComponent
        let dir = (result.path as NSString).deletingLastPathComponent
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (name as NSString).pathExtension) ?? .data))
                .resizable()
                .frame(width: 16, height: 16)
            highlighted(name, offset: result.path.count - name.count)
                .lineLimit(1)
            Text(dir)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
    }

    /// The file name with matched characters in bold.
    private func highlighted(_ name: String, offset: Int) -> Text {
        let marks = Set(result.positions.map { $0 - offset })
        var attributed = AttributedString()
        for (i, ch) in name.enumerated() {
            var part = AttributedString(String(ch))
            if marks.contains(i) {
                part.font = .body.bold()
                part.foregroundColor = .accentColor
            }
            attributed += part
        }
        return Text(attributed)
    }
}

// MARK: - Find in Files

struct FindInFilesView: View {
    @Environment(AppModel.self) private var model
    let root: URL
    let close: () -> Void
    @State private var query = ""
    @State private var caseSensitive = false
    @State private var regex = false
    @State private var groups: [(path: String, matches: [SearchMatch])] = []
    @State private var searching = false
    @State private var searchedQuery = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    nonisolated private static let limit = 2000

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in Files", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                Toggle(isOn: $caseSensitive) { Text(verbatim: "Aa") }
                    .toggleStyle(.button)
                    .help("Match Case")
                Toggle(isOn: $regex) { Text(verbatim: ".*") }
                    .toggleStyle(.button)
                    .help("Use Regular Expression")
            }
            .padding(12)
            Divider()
            List {
                ForEach(groups, id: \.path) { group in
                    Section {
                        ForEach(group.matches) { match in
                            FindResultRow(match: match, query: searchedQuery, caseSensitive: caseSensitive && !regex)
                                .contentShape(Rectangle())
                                .onTapGesture { activate(match, insert: NSEvent.modifierFlags.contains(.option)) }
                                .contextMenu {
                                    Button("Open") { activate(match, insert: false) }
                                    if model.insertTargetSession != nil {
                                        Button("Add @\(match.path):\(match.line) to Claude") { activate(match, insert: true) }
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text(group.path).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                            Text("\(group.matches.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if searching { ProgressView().controlSize(.small) }
                else if groups.isEmpty && !searchedQuery.isEmpty { Text("No results").foregroundStyle(.secondary) }
            }
            Divider()
            HStack(spacing: 14) {
                Text("Click to open")
                if model.insertTargetSession != nil { Text("⌥-click to add @path#Lline to Claude") }
                Spacer()
                let count = groups.reduce(0) { $0 + $1.matches.count }
                if count > 0 {
                    Text(count >= Self.limit ? String(localized: "First \(count) results") : String(localized: "\(count) results in \(groups.count) files"))
                }
                Button("Close", action: close).buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in search(debounce: true) }
        .onChange(of: caseSensitive) { _, _ in search(debounce: false) }
        .onChange(of: regex) { _, _ in search(debounce: false) }
        .modifier(SheetKeys { key in
            switch key {
            case .enter: search(debounce: false)
            case .escape: close()
            case .up, .down: return false
            }
            return true
        })
    }

    private func search(debounce: Bool) {
        searchTask?.cancel()
        let query = self.query, root = self.root, caseSensitive = self.caseSensitive, regex = self.regex
        guard !query.isEmpty else {
            groups = []; searchedQuery = ""; searching = false
            return
        }
        searchTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            searching = true
            let matches = await Task.detached(priority: .userInitiated) {
                Git.grep(query, in: root, caseSensitive: caseSensitive, regex: regex,
                         inRepo: Git.root(of: root) != nil, limit: Self.limit)
            }.value
            guard !Task.isCancelled else { return }
            var order: [String] = []
            var byPath: [String: [SearchMatch]] = [:]
            for match in matches {
                if byPath[match.path] == nil { order.append(match.path) }
                byPath[match.path, default: []].append(match)
            }
            groups = order.map { ($0, byPath[$0] ?? []) }
            searchedQuery = query
            searching = false
        }
    }

    private func activate(_ match: SearchMatch, insert: Bool) {
        if insert {
            guard let session = model.insertTargetSession else { return }
            model.terminals.type("@\(match.path)#L\(match.line) ", into: session)
        } else {
            EditorOpener.openDefault(root.appending(path: match.path), model: model)
        }
        close()
    }
}

private struct FindResultRow: View {
    let match: SearchMatch
    let query: String
    let caseSensitive: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(match.line)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, alignment: .trailing)
            Text(highlighted)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// First literal occurrence of the query highlighted (regex searches are shown plain).
    private var highlighted: AttributedString {
        var text = AttributedString(match.text)
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        if !query.isEmpty, let range = match.text.range(of: query, options: options),
           let lower = AttributedString.Index(range.lowerBound, within: text),
           let upper = AttributedString.Index(range.upperBound, within: text) {
            text[lower..<upper].backgroundColor = .yellow.opacity(0.35)
            text[lower..<upper].font = .system(size: 12, weight: .bold, design: .monospaced)
        }
        return text
    }
}
