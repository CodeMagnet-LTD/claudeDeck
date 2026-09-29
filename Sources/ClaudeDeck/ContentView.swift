import ClaudeDeckCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showFiles") private var showFiles = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
        } detail: {
            DetailView()
                .inspector(isPresented: $showFiles) {
                    FileBrowserPanel()
                        .inspectorColumnWidth(min: 220, ideal: 290, max: 520)
                }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if VSCode.isInstalled, let path = focusedProjectPath {
                    Button {
                        VSCode.open(URL(fileURLWithPath: path))
                    } label: {
                        Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .help("Open Project in VS Code")
                }
                Button {
                    showFiles.toggle()
                } label: {
                    Label("Files", systemImage: "sidebar.right")
                }
                .help("Project Files (⌘⇧E)")
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    model.presentAddProject()
                } label: {
                    Label("Add Project", systemImage: "folder.badge.plus")
                }
                .help("Add Project (⌘O)")
            }
        }
        .alert("Couldn’t Install the Hook", isPresented: .constant(model.hookError != nil)) {
            Button("OK") { model.hookError = nil }
        } message: {
            Text(model.hookError ?? "")
        }
    }
}

extension ContentView {
    var focusedProjectPath: String? {
        model.selectedSessionID.flatMap { model.deck.session($0) }.flatMap { model.deck.project($0.projectID)?.path }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let panes = model.deck.visiblePanes
        if panes.isEmpty {
            EmptyStateView()
        } else {
            let focused = model.selectedSessionID.flatMap { model.deck.session($0) }
            // Own split layout instead of HSplitView: NSSplitView's min-size updates entered an
            // endless constraint-update loop with the terminal views (crash on click).
            PaneSplit(panes: panes)
            .navigationTitle(focused?.name ?? "ClaudeDeck")
            .navigationSubtitle(focused.flatMap { model.deck.project($0.projectID)?.path } ?? "")
        }
    }
}

/// Panes side by side with draggable dividers. Widths are fractions kept in view state;
/// nothing here feeds sizes back into AppKit constraints.
struct PaneSplit: View {
    let panes: [UUID]
    @State private var fractions: [UUID: CGFloat] = [:]
    private let minWidth: CGFloat = 240
    private let divider: CGFloat = 6

    var body: some View {
        if panes.count == 1, let id = panes.first {
            PaneView(sessionID: id, split: false)
        } else {
            GeometryReader { geo in
                let widths = widths(total: geo.size.width - divider * CGFloat(panes.count - 1))
                HStack(spacing: 0) {
                    ForEach(Array(panes.enumerated()), id: \.element) { index, id in
                        PaneView(sessionID: id, split: true)
                            .frame(width: widths[index])
                        if index < panes.count - 1 {
                            PaneDivider(width: divider) { delta in
                                resize(index, by: delta, widths: widths)
                            }
                        }
                    }
                }
            }
        }
    }

    private func widths(total: CGFloat) -> [CGFloat] {
        let raw = panes.map { fractions[$0] ?? 1 }
        let sum = raw.reduce(0, +)
        return raw.map { max(minWidth, total * $0 / sum) }
    }

    private func resize(_ index: Int, by delta: CGFloat, widths: [CGFloat]) {
        var w = widths
        let pair = w[index] + w[index + 1]
        w[index] = min(max(minWidth, w[index] + delta), pair - minWidth)
        w[index + 1] = pair - w[index]
        let total = w.reduce(0, +)
        for (i, id) in panes.enumerated() { fractions[id] = w[i] / total * CGFloat(panes.count) }
    }
}

struct PaneDivider: View {
    let width: CGFloat
    let onDrag: (CGFloat) -> Void
    @State private var last: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: width)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        onDrag(value.translation.width - last)
                        last = value.translation.width
                    }
                    .onEnded { _ in last = 0 }
            )
    }
}

/// One terminal pane. Accepts sessions dragged from the sidebar: dropping on the left or right
/// half opens it on that side.
struct PaneView: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID
    let split: Bool
    @State private var dropSide: DropSide?
    @State private var width: CGFloat = 1

    enum DropSide { case before, after }

    var body: some View {
        if let session = model.deck.session(sessionID) {
            let running = model.terminals.isRunning(sessionID)
            let focused = model.selectedSessionID == sessionID
            VStack(spacing: 0) {
                if split { PaneHeader(session: session, focused: focused) }
                if model.terminals.view(for: sessionID) != nil {
                    TerminalHost(sessionID: sessionID, registry: model.terminals, generation: running, isFocused: focused)
                        .id(sessionID)
                        .background(Color(nsColor: DeckTerminalView.background))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !running { ExitedBar(session: session) }
            }
            .overlay {
                if split && focused {
                    Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5).allowsHitTesting(false)
                }
            }
            .overlay(alignment: dropSide == .before ? .leading : .trailing) {
                if dropSide != nil {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .frame(width: width / 2)
                        .allowsHitTesting(false)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onDrop(of: PaneDropDelegate.types, delegate: PaneDropDelegate(
                width: width, side: $dropSide,
                draggedSession: { model.draggedSessionID },
                onSession: { droppedID, side in
                    model.draggedSessionID = nil
                    guard droppedID != sessionID else { return }
                    model.openBeside(droppedID, anchor: sessionID, before: side == .before)
                },
                onFiles: { urls in model.insertPaths(urls, into: sessionID) }
            ))
        }
    }
}

struct PaneHeader: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession
    let focused: Bool

    var body: some View {
        let status = model.status(of: session.id)
        HStack(spacing: 8) {
            StatusDot(display: status.display, unseen: model.isUnseenIdle(session.id))
            Text(session.name).font(.callout.weight(focused ? .semibold : .regular)).lineLimit(1)
            StatusPill(display: status.display, unseen: model.isUnseenIdle(session.id))
                    ShellStartBadge(session: session)
            if model.pencilSessions.contains(session.id) { PencilBadge() }
            if let detail = status.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            PermissionButtons(sessionID: session.id).fixedSize()
            Button {
                model.closePane(session.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close Pane (the session keeps running)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(focused ? Color.accentColor.opacity(0.12) : Color.clear)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedSessionID = session.id }
        .contextMenu { SessionMenu(session: session) }
    }
}

/// Sessions from the sidebar open a pane on the drop side; files from the file browser or
/// Finder are typed into the terminal as paths.
struct PaneDropDelegate: DropDelegate {
    static let types: [UTType] = [.fileURL, .utf8PlainText, .plainText]
    let width: CGFloat
    @Binding var side: PaneView.DropSide?
    /// The sidebar drag in progress, if any (reliable path; the item provider is the fallback).
    let draggedSession: () -> UUID?
    let onSession: (UUID, PaneView.DropSide) -> Void
    let onFiles: ([URL]) -> Void

    private func side(for info: DropInfo) -> PaneView.DropSide {
        info.location.x < width / 2 ? .before : .after
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: Self.types) }
    func dropEntered(info: DropInfo) { side = info.hasItemsConforming(to: [.fileURL]) ? nil : side(for: info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        side = info.hasItemsConforming(to: [.fileURL]) ? nil : side(for: info)
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { side = nil }

    func performDrop(info: DropInfo) -> Bool {
        let where_ = side(for: info)
        side = nil
        let fileProviders = info.itemProviders(for: [.fileURL])
        if !fileProviders.isEmpty {
            let collector = URLCollector(count: fileProviders.count, done: onFiles)
            for provider in fileProviders {
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    collector.add(object as? URL)
                }
            }
            return true
        }
        if let id = draggedSession() {
            onSession(id, where_)
            return true
        }
        guard let provider = info.itemProviders(for: [.utf8PlainText, .plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = (object as? NSString).map({ $0 as String }),
                  let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            Task { @MainActor in onSession(id, where_) }
        }
        return true
    }
}

/// Shown under a terminal whose claude process has exited (e.g. the user typed /exit).
struct ExitedBar: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
            if session.kind == .shell {
                Text("Terminal closed").foregroundStyle(.secondary)
                Spacer()
                Button("Reopen") { model.launch(session.id, resume: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                if model.claudePath == nil {
                    Text("`claude` wasn’t found in your login shell. Is Claude Code installed?").foregroundStyle(.red)
                } else {
                    Text("Claude session ended").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start Fresh") { model.launch(session.id, resume: false) }
                Button("Resume") { model.launch(session.id, resume: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.play")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.deck.projects.isEmpty ? LocalizedStringKey("Add a project to get started") : LocalizedStringKey("Select a session or start a new one"))
                .font(.title3)
            if model.deck.projects.isEmpty {
                Button("Add Project…") { model.presentAddProject() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Gathers asynchronously loaded file URLs and delivers them once, in drop order, on the main actor.
final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private let done: ([URL]) -> Void

    init(count: Int, done: @escaping ([URL]) -> Void) {
        remaining = count
        self.done = done
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        remaining -= 1
        let finished = remaining == 0
        let result = urls
        lock.unlock()
        if finished { Task { @MainActor in self.done(result) } }
    }
}
