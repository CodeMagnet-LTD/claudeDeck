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
                        Label("VS Code'da aç", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .help("Projeyi VS Code'da aç")
                }
                Button {
                    showFiles.toggle()
                } label: {
                    Label("Dosyalar", systemImage: "sidebar.right")
                }
                .help("Proje dosyaları (⌘⇧E)")
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    model.presentAddProject()
                } label: {
                    Label("Proje Ekle", systemImage: "folder.badge.plus")
                }
                .help("Proje ekle (⌘O)")
            }
        }
        .alert("Hook kurulamadı", isPresented: .constant(model.hookError != nil)) {
            Button("Tamam") { model.hookError = nil }
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
            HSplitView {
                ForEach(panes, id: \.self) { id in
                    PaneView(sessionID: id, split: panes.count > 1)
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(focused?.name ?? "ClaudeDeck")
            .navigationSubtitle(focused.flatMap { model.deck.project($0.projectID)?.path } ?? "")
        }
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
            .background(GeometryReader { geo in
                Color.clear.onAppear { width = geo.size.width }.onChange(of: geo.size.width) { _, w in width = w }
            })
            .onDrop(of: PaneDropDelegate.types, delegate: PaneDropDelegate(
                width: width, side: $dropSide,
                onSession: { droppedID, side in
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
            .help("Bölmeyi kapat (oturum çalışmaya devam eder)")
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
        guard let provider = info.itemProviders(for: [.utf8PlainText, .plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = UUID(uuidString: text) else { return }
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
                Text("Terminal kapandı").foregroundStyle(.secondary)
                Spacer()
                Button("Yeniden aç") { model.launch(session.id, resume: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                if model.claudePath == nil {
                    Text("`claude` login shell'de bulunamadı. Claude Code kurulu mu?").foregroundStyle(.red)
                } else {
                    Text("Claude oturumu kapandı").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Yeni başlat") { model.launch(session.id, resume: false) }
                Button("Devam et") { model.launch(session.id, resume: true) }
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
            Text(model.deck.projects.isEmpty ? "Başlamak için bir proje ekle" : "Bir oturum seç ya da yeni oturum aç")
                .font(.title3)
            if model.deck.projects.isEmpty {
                Button("Proje Ekle…") { model.presentAddProject() }
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
