import AppKit
import ClaudeDeckCore
import SwiftUI
import UniformTypeIdentifiers

/// The main window's detail column: the tab strip (hidden while Sessions is the only tab) over the
/// tab contents. Every editor tab and the Sessions tab stay alive underneath the selected one:
/// terminals must not be re-created, and an editor's text lives in its text view.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tabs = model.tabs
        VStack(spacing: 0) {
            if tabs.tabs.count > 1 {
                TabStrip()
                Divider()
            }
            ZStack {
                layer(.sessions) { DetailView() }
                ForEach(tabs.tabs.filter { $0 != .sessions }, id: \.key) { tab in
                    layer(tab) { TabContent(tab: tab, isSelected: tabs.selected == tab) }
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .focusedSceneValue(\.editorDocument, tabs.selected.fileURL.flatMap { tabs.document(for: $0) })
        .background(MainWindowGlue(tabs: tabs, anyDirty: !tabs.dirtyDocuments.isEmpty))
    }

    private func layer<Content: View>(_ tab: WorkspaceTab, @ViewBuilder _ content: () -> Content) -> some View {
        let selected = model.tabs.selected == tab
        return content()
            .opacity(selected ? 1 : 0)
            .allowsHitTesting(selected)
            .accessibilityHidden(!selected)
            .zIndex(selected ? 1 : 0)
    }

    private var focusedSession: DeckSession? { model.selectedSessionID.flatMap { model.deck.session($0) } }

    private var title: String {
        switch model.tabs.selected {
        case .sessions: model.deck.visiblePanes.isEmpty ? "ClaudeDeck" : focusedSession?.name ?? "ClaudeDeck"
        default: model.tabs.selected.title
        }
    }

    private var subtitle: String {
        switch model.tabs.selected {
        case .sessions:
            model.deck.visiblePanes.isEmpty ? "" : focusedSession.flatMap { model.deck.project($0.projectID)?.path } ?? ""
        case .file(let url): (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        case .diff(let repo, _, _): (repo as NSString).abbreviatingWithTildeInPath
        case .automations: ""
        }
    }
}

/// One non-Sessions tab's content. Diffs exist only while selected (they poll git); editors and
/// Automations stay alive.
private struct TabContent: View {
    @Environment(AppModel.self) private var model
    let tab: WorkspaceTab
    let isSelected: Bool

    var body: some View {
        switch tab {
        case .sessions:
            EmptyView()
        case .file(let url):
            if let document = model.tabs.document(for: url) {
                EditorTabView(document: document, isSelected: isSelected)
                    .id(ObjectIdentifier(document))
            }
        case .diff(let repo, let path, let staged):
            if isSelected { DiffTabView(repo: repo, path: path, staged: staged) }
        case .automations:
            AutomationsView()
        }
    }
}

/// A file tab: header bar with the editor actions over the editor.
private struct EditorTabView: View {
    @Environment(AppModel.self) private var model
    let document: EditorDocument
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(verbatim: (document.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(document.url.path)
                Spacer(minLength: 8)
                EditorActionButtons(document: document)
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.bar)
            Divider()
            EditorBody(document: document, isActive: isSelected)
        }
        // Editing a preview tab keeps it.
        .onChange(of: document.isDirty) { _, dirty in
            if dirty { model.tabs.pin(.file(document.url)) }
        }
    }
}

// MARK: - Strip

private struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @State private var dragging: WorkspaceTab?

    var body: some View {
        let tabs = model.tabs
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs.tabs, id: \.key) { tab in
                        TabItem(tab: tab, dragging: $dragging)
                            .id(tab.key)
                        Divider().frame(height: 16)
                    }
                }
            }
            .onChange(of: tabs.selected) { _, tab in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(tab.key) }
            }
        }
        .frame(height: 30)
        .background(.bar)
    }
}

private struct TabItem: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let tab: WorkspaceTab
    @Binding var dragging: WorkspaceTab?
    @State private var hovering = false

    var body: some View {
        let tabs = model.tabs
        let selected = tabs.selected == tab
        let preview = tabs.list.preview == tab
        HStack(spacing: 6) {
            icon.frame(width: 14, height: 14)
            Text(verbatim: tab.title)
                .font(.callout)
                .italic(preview)
                .lineLimit(1)
                .foregroundStyle(selected ? .primary : .secondary)
            trailing(selected: selected)
        }
        .padding(.leading, 10)
        .padding(.trailing, tab == .sessions ? 10 : 6)
        .frame(maxHeight: .infinity)
        .frame(minWidth: 70, maxWidth: 220)
        .background(selected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if selected { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { tabs.select(tab) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { tabs.pin(tab) })
        .overlay { MiddleClick { tabs.close(tab) } }
        .help(tab.helpText)
        .contextMenu { menu }
        .onDrag {
            dragging = tab
            return NSItemProvider(object: tab.key as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, dragging: $dragging, tabs: tabs))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        switch tab {
        case .sessions: Image(systemName: "terminal")
        case .file(let url): Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        case .diff: Image(systemName: "plus.forwardslash.minus").foregroundStyle(.orange)
        case .automations: Image(systemName: "clock.arrow.circlepath")
        }
    }

    /// Close button on hover / selection; a dot for unsaved changes otherwise.
    @ViewBuilder private func trailing(selected: Bool) -> some View {
        if tab != .sessions {
            let dirty = tab.fileURL.flatMap { model.tabs.document(for: $0) }?.isDirty ?? false
            ZStack {
                if hovering || (selected && !dirty) {
                    Button { model.tabs.close(tab) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .help("Close Tab (⌘W)")
                } else if dirty {
                    Circle().fill(Color.primary.opacity(0.6)).frame(width: 7, height: 7)
                        .help("Unsaved changes")
                }
            }
            .frame(width: 16, height: 16)
        }
    }

    @ViewBuilder private var menu: some View {
        let tabs = model.tabs
        if tab != .sessions {
            Button("Close Tab") { tabs.close(tab) }
        }
        Button("Close Other Tabs") { tabs.close(tabs.list.others(than: tab)) }
            .disabled(tabs.list.others(than: tab).isEmpty)
        Button("Close Tabs to the Right") { tabs.close(tabs.list.tabsToTheRight(of: tab)) }
            .disabled(tabs.list.tabsToTheRight(of: tab).isEmpty)
        if tabs.list.preview == tab {
            Divider()
            Button("Keep Open") { tabs.pin(tab) }
        }
        if let url = tab.url {
            Divider()
            Button("Copy Path") { FileActions.copy(url.path) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        if let url = tab.fileURL {
            Button("Open in Separate Window") { tabs.moveToWindow(url, openWindow: openWindow) }
        }
    }
}

/// Live reordering while a tab is dragged over its neighbours.
private struct TabDropDelegate: DropDelegate {
    let target: WorkspaceTab
    @Binding var dragging: WorkspaceTab?
    let tabs: WorkspaceTabs

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeOut(duration: 0.12)) { tabs.move(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Middle-click to close. Only claims other-button clicks, so taps and drags reach SwiftUI.
private struct MiddleClick: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ClickView { ClickView() }
    func updateNSView(_ view: ClickView, context: Context) { view.action = action }

    final class ClickView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let type = NSApp.currentEvent?.type, type == .otherMouseDown || type == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseDown(with event: NSEvent) {}

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action?() }
        }
    }
}

// MARK: - Tab presentation

extension WorkspaceTab {
    /// Stable identity for ForEach / drag and drop.
    var key: String {
        switch self {
        case .sessions: "sessions"
        case .file(let url): "file:" + url.path
        case .diff(let repo, let path, let staged): "diff:\(staged ? "staged" : "worktree"):\(repo):\(path)"
        case .automations: "automations"
        }
    }

    var title: String {
        switch self {
        case .sessions: String(localized: "Sessions")
        case .file(let url): url.lastPathComponent
        case .diff(_, let path, let staged):
            staged ? String(localized: "\((path as NSString).lastPathComponent) (Staged)")
                : String(localized: "\((path as NSString).lastPathComponent) (Working Tree)")
        case .automations: String(localized: "Automations")
        }
    }

    /// The file behind a file or diff tab.
    var url: URL? {
        switch self {
        case .file(let url): url
        case .diff(let repo, let path, _): URL(fileURLWithPath: repo).appending(path: path)
        default: nil
        }
    }

    var helpText: String {
        switch self {
        case .sessions: String(localized: "Terminal sessions (⌘1)")
        case .automations: String(localized: "Automations")
        default: url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
        }
    }
}

// MARK: - Main window glue

/// Hooks the main NSWindow: remembers it for the tabs, shows the edited dot while a file tab has
/// unsaved changes, and asks before the window (and with it the tabs' text views) closes.
private struct MainWindowGlue: NSViewRepresentable {
    let tabs: WorkspaceTabs
    let anyDirty: Bool

    func makeCoordinator() -> Guard { Guard(tabs: tabs) }

    func makeNSView(context: Context) -> NSView {
        let view = WindowView()
        view.onWindow = { [weak coordinator = context.coordinator] window in coordinator?.install(on: window) }
        tabs.installKeyMonitor()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        if window.isDocumentEdited != anyDirty { window.isDocumentEdited = anyDirty }
        if window.delegate !== context.coordinator { context.coordinator.install(on: window) }
    }

    final class WindowView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    /// Wraps SwiftUI's window delegate (forwarding everything) to ask about unsaved tabs on close.
    @MainActor
    final class Guard: NSObject, NSWindowDelegate {
        let tabs: WorkspaceTabs
        nonisolated(unsafe) weak var original: NSWindowDelegate?
        private weak var window: NSWindow?
        nonisolated(unsafe) private var closeObserver: NSObjectProtocol?

        init(tabs: WorkspaceTabs) { self.tabs = tabs }

        deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }

        func install(on window: NSWindow) {
            tabs.mainWindow = window
            if window.delegate !== self {
                original = window.delegate
                window.delegate = self
            }
            guard self.window !== window else { return }
            self.window = window
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tabs.windowDidClose() }
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard tabs.confirmCloseWindow() else { return false }
            return original?.windowShouldClose?(sender) ?? true
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

// MARK: - Commands

/// Window menu: tab navigation. ⌘2…⌘9 and ⌘W (close tab) are handled by `WorkspaceTabs`' key monitor.
struct TabCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Show Sessions") { model.tabs.selectSessions(); model.showMainWindow() }
                .keyboardShortcut("1")
            Button("Show Next Tab") { model.tabs.selectNeighbour(forward: true); model.showMainWindow() }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Show Previous Tab") { model.tabs.selectNeighbour(forward: false); model.showMainWindow() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
        }
    }
}
