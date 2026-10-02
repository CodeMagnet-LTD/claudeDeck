import AppKit
import ClaudeDeckCore
import SwiftUI
import UniformTypeIdentifiers

/// The main window's detail column. With more than one tab, the tab strip sits in the toolbar in
/// place of the window title (no extra row); with Sessions alone the title is as before. Every editor tab and the Sessions tab stay alive underneath the selected one:
/// terminals must not be re-created, and an editor's text lives in its text view.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 800

    var body: some View {
        let tabs = model.tabs
        let showStrip = tabs.tabs.count > 1
        ZStack {
            layer(.sessions) { DetailView() }
            ForEach(tabs.tabs.filter { $0 != .sessions }, id: \.key) { tab in
                layer(tab) { TabContent(tab: tab, isSelected: tabs.selected == tab) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle(title)
        .navigationSubtitle(showStrip ? "" : subtitle)
        .toolbar(removing: showStrip ? .title : nil)
        .toolbar {
            if showStrip { TabStripToolbarItem(maxWidth: max(160, width - 190)) }
        }
        .focusedSceneValue(\.editorDocument, tabs.selected.fileURL.flatMap { tabs.document(for: $0) })
        .background(MainWindowGlue(tabs: tabs, anyDirty: !tabs.dirtyDocuments.isEmpty))
    }

    private func layer<Content: View>(_ tab: WorkspaceTab, @ViewBuilder _ content: () -> Content) -> some View {
        let selected = model.tabs.selected == tab
        return content()
            .opacity(selected ? 1 : 0)
            .allowsHitTesting(selected)
            .accessibilityHidden(!selected)
            // Keeps hidden layers' keyboard shortcuts (e.g. Resume's Return) from firing.
            .disabled(!selected)
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
        case .inbox: ""
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
        case .inbox:
            if isSelected { InboxView() }   // polls gh only while visible
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

/// The strip as a toolbar item, plain (no glass capsule). It spans the free toolbar width so the
/// toolbar buttons stay on the right, where the title used to push them.
private struct TabStripToolbarItem: ToolbarContent {
    let maxWidth: CGFloat

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) { TabStrip(maxWidth: maxWidth) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { TabStrip(maxWidth: maxWidth) }
        }
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var model
    let maxWidth: CGFloat
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        let tabs = model.tabs
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs.tabs, id: \.key) { tab in
                        TabItem(tab: tab)
                            .id(tab.key)
                    }
                }
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            }
            .onChange(of: tabs.selected) { _, tab in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(tab.key) }
            }
        }
        // A toolbar item needs a definite width: the tabs' own, up to what the toolbar can spare.
        .frame(width: min(contentWidth, maxWidth), height: 26)
        .frame(width: maxWidth, alignment: .leading)
    }
}

private struct TabItem: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let tab: WorkspaceTab
    @State private var hovering = false

    var body: some View {
        let tabs = model.tabs
        let selected = tabs.selected == tab
        let preview = tabs.list.preview == tab
        HStack(spacing: 5) {
            icon.frame(width: 12, height: 12)
                .foregroundStyle(selected ? .primary : .secondary)
            Text(verbatim: tab == .sessions ? sessionsTitle : tab.title)
                .font(.caption)
                .italic(preview)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(selected ? .primary : .secondary)
            trailing(selected: selected)
        }
        .padding(.leading, 8)
        .padding(.trailing, tab == .sessions ? 8 : 4)
        .frame(height: 22)
        .frame(maxWidth: 220)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.09))
            } else if hovering {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { tabs.select(tab) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { tabs.pin(tab) })
        // In the toolbar, SwiftUI's context menu and drag and drop never see the mouse (NSToolbar
        // shows its own menu and swallows drags): AppKit handles right-click, middle-click and reordering.
        .overlay {
            TabMouseHandler(tab: tab, hasCloseButton: tab != .sessions, menu: menuEntries,
                            onClose: { tabs.close(tab) }, onDragOver: dragOver)
        }
        .help(tab == .sessions ? sessionsHelp : tab.helpText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The Sessions tab carries what the window title showed: the focused session's name…
    private var sessionsTitle: String {
        guard !model.deck.visiblePanes.isEmpty, let session = model.selectedSessionID.flatMap({ model.deck.session($0) }) else {
            return WorkspaceTab.sessions.title
        }
        return session.name
    }

    /// …and its project path as the tooltip.
    private var sessionsHelp: String {
        let path = model.selectedSessionID.flatMap { model.deck.session($0) }.flatMap { model.deck.project($0.projectID)?.path }
        return [WorkspaceTab.sessions.helpText, path.map { ($0 as NSString).abbreviatingWithTildeInPath }].compactMap { $0 }.joined(separator: "\n")
    }

    @ViewBuilder private var icon: some View {
        switch tab {
        case .sessions: Image(systemName: "terminal")
        case .file(let url): Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        case .diff: Image(systemName: "plus.forwardslash.minus").foregroundStyle(.orange)
        case .automations: Image(systemName: "clock.arrow.circlepath")
        case .inbox: Image(systemName: "tray")
        }
    }

    /// Close button on hover / selection; a dot for unsaved changes otherwise.
    @ViewBuilder private func trailing(selected: Bool) -> some View {
        if tab != .sessions {
            let dirty = tab.fileURL.flatMap { model.tabs.document(for: $0) }?.isDirty ?? false
            ZStack {
                if hovering || (selected && !dirty) {
                    Button { model.tabs.close(tab) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Close Tab (⌘W)")
                } else if dirty {
                    Circle().fill(Color.primary.opacity(0.55)).frame(width: 6, height: 6)
                        .help("Unsaved changes")
                }
            }
            .frame(width: 14, height: 14)
        }
    }

    /// The tab's context menu (nil = separator).
    private func menuEntries() -> [TabMenuEntry?] {
        let tabs = model.tabs
        var entries: [TabMenuEntry?] = []
        if tab != .sessions {
            entries.append(TabMenuEntry(String(localized: "Close Tab")) { tabs.close(tab) })
        }
        entries.append(TabMenuEntry(String(localized: "Close Other Tabs"), enabled: !tabs.list.others(than: tab).isEmpty) {
            tabs.close(tabs.list.others(than: tab))
        })
        entries.append(TabMenuEntry(String(localized: "Close Tabs to the Right"), enabled: !tabs.list.tabsToTheRight(of: tab).isEmpty) {
            tabs.close(tabs.list.tabsToTheRight(of: tab))
        })
        if tabs.list.preview == tab {
            entries.append(nil)
            entries.append(TabMenuEntry(String(localized: "Keep Open")) { tabs.pin(tab) })
        }
        if let url = tab.url {
            entries.append(nil)
            entries.append(TabMenuEntry(String(localized: "Copy Path")) { FileActions.copy(url.path) })
            entries.append(TabMenuEntry(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        if let url = tab.fileURL {
            let openWindow = self.openWindow
            entries.append(TabMenuEntry(String(localized: "Open in Separate Window")) { tabs.moveToWindow(url, openWindow: openWindow) })
        }
        return entries
    }

    /// Another tab is being dragged over this one; `fraction` is the pointer's x within it (0…1).
    /// It takes this tab's place once the pointer crosses the middle, so unequal widths don't flip-flop.
    private func dragOver(_ dragged: WorkspaceTab, fraction: CGFloat) {
        let tabs = model.tabs
        guard dragged != tab, tab != .sessions, let from = tabs.tabs.firstIndex(of: dragged),
              let to = tabs.tabs.firstIndex(of: tab) else { return }
        if (to > from && fraction > 0.5) || (to < from && fraction < 0.5) {
            withAnimation(.easeOut(duration: 0.12)) { tabs.move(dragged, to: tab) }
        }
    }
}

// MARK: - Mouse handling (AppKit)

struct TabMenuEntry {
    let title: String
    var enabled = true
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }
}

/// Transparent AppKit layer over one tab. Left clicks stay with SwiftUI (select, double-click,
/// close button): this view claims only right / control / middle clicks. Dragging is watched with
/// an event monitor, which sees the drag even though SwiftUI got the mouse-down.
private struct TabMouseHandler: NSViewRepresentable {
    let tab: WorkspaceTab
    let hasCloseButton: Bool
    let menu: () -> [TabMenuEntry?]
    let onClose: () -> Void
    let onDragOver: (WorkspaceTab, CGFloat) -> Void

    func makeNSView(context: Context) -> TabMouseView {
        TabMouseView.installDragMonitor()
        return TabMouseView()
    }

    func updateNSView(_ view: TabMouseView, context: Context) {
        view.tab = tab
        view.hasCloseButton = hasCloseButton
        view.menuEntries = menu
        view.onClose = onClose
        view.onDragOver = onDragOver
    }
}

final class TabMouseView: NSView {
    var tab: WorkspaceTab = .sessions
    var hasCloseButton = false
    var menuEntries: (() -> [TabMenuEntry?])?
    var onClose: (() -> Void)?
    var onDragOver: ((WorkspaceTab, CGFloat) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.views.remove(self)
        if window != nil { Self.views.add(self) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let claimed: Bool = switch event.type {
        case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: true
        case .leftMouseDown, .leftMouseUp: event.modifierFlags.contains(.control)
        default: false
        }
        return claimed ? super.hitTest(point) : nil
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let entries = menuEntries?() else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            guard let entry else { menu.addItem(.separator()); continue }
            let item = ClosureMenuItem(title: entry.title, action: entry.action)
            item.isEnabled = entry.enabled
            menu.addItem(item)
        }
        return menu
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(event)
    }

    /// Control-click (hit-tested only with ⌃ held).
    override func mouseDown(with event: NSEvent) {
        showMenu(event)
    }

    private func showMenu(_ event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Middle-click

    override func otherMouseDown(with event: NSEvent) {}

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    // MARK: Drag to reorder

    @MainActor private static let views = NSHashTable<TabMouseView>.weakObjects()
    @MainActor private static var monitor: Any?
    @MainActor private static var pressed: (view: TabMouseView, start: NSPoint)?
    @MainActor private static var dragging = false

    @MainActor static func installDragMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    /// The tab view under a window location, if any.
    @MainActor private static func view(at location: NSPoint, in window: NSWindow?) -> TabMouseView? {
        views.allObjects.first { $0.window === window && $0.bounds.contains($0.convert(location, from: nil)) }
    }

    /// The toolbar swallows right-clicks before hit-testing reaches the tab, so the context menu is
    /// opened from here too. Returns true when the event was consumed.
    @MainActor private static func handle(_ event: NSEvent) -> Bool {
        let isMenuClick = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        if isMenuClick {
            guard let view = view(at: event.locationInWindow, in: event.window), let menu = view.menu(for: event) else { return false }
            let point = view.convert(event.locationInWindow, from: nil)
            // Outside the monitor callback: popping up runs its own tracking loop.
            DispatchQueue.main.async { menu.popUp(positioning: nil, at: point, in: view) }
            return true
        }
        switch event.type {
        case .leftMouseDown:
            dragging = false
            pressed = nil
            guard let view = view(at: event.locationInWindow, in: event.window) else { return false }
            // Not from the close button (the trailing 18 pt of a closable tab).
            let local = view.convert(event.locationInWindow, from: nil)
            if view.hasCloseButton && local.x > view.bounds.width - 18 { return false }
            if view.tab == .sessions { return false }
            pressed = (view, event.locationInWindow)
        case .leftMouseDragged:
            guard let pressed, pressed.view.window === event.window else { return false }
            if !dragging {
                guard hypot(event.locationInWindow.x - pressed.start.x, event.locationInWindow.y - pressed.start.y) > 4 else { return false }
                dragging = true
            }
            guard let target = view(at: event.locationInWindow, in: event.window), target !== pressed.view else { return false }
            let local = target.convert(event.locationInWindow, from: nil)
            target.onDragOver?(pressed.view.tab, target.bounds.width > 0 ? local.x / target.bounds.width : 0.5)
        default:
            pressed = nil
            dragging = false
        }
        return false
    }
}

/// An NSMenuItem that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
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
        case .inbox: "inbox"
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
        case .inbox: String(localized: "Inbox")
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
        case .inbox: String(localized: "GitHub issues and pull requests")
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
        Self.lockToolbar(of: window)
        if window.delegate !== context.coordinator { context.coordinator.install(on: window) }
    }

    /// The tab strip lives in the toolbar: no "Icon and Text / Icon Only" menu on right-click.
    @MainActor static func lockToolbar(of window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        if toolbar.allowsUserCustomization { toolbar.allowsUserCustomization = false }
        if toolbar.allowsDisplayModeCustomization { toolbar.allowsDisplayModeCustomization = false }
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
            MainWindowGlue.lockToolbar(of: window)
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
            Button("Next Session Waiting for You") { model.selectNextWaiting() }
                .keyboardShortcut("j")
            Divider()
        }
    }
}
