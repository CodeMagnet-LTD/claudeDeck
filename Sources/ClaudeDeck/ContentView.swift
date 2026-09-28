import ClaudeDeckCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
        } detail: {
            DetailView()
        }
        .toolbar {
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
            .onDrop(of: [.utf8PlainText, .plainText], delegate: PaneDropDelegate(
                width: width, side: $dropSide
            ) { droppedID, side in
                guard droppedID != sessionID else { return }
                model.openBeside(droppedID, anchor: sessionID, before: side == .before)
            })
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

struct PaneDropDelegate: DropDelegate {
    let width: CGFloat
    @Binding var side: PaneView.DropSide?
    let onDrop: (UUID, PaneView.DropSide) -> Void

    private func side(for info: DropInfo) -> PaneView.DropSide {
        info.location.x < width / 2 ? .before : .after
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.utf8PlainText, .plainText]) }
    func dropEntered(info: DropInfo) { side = side(for: info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        side = side(for: info)
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { side = nil }

    func performDrop(info: DropInfo) -> Bool {
        let where_ = side(for: info)
        side = nil
        guard let provider = info.itemProviders(for: [.utf8PlainText, .plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = UUID(uuidString: text) else { return }
            Task { @MainActor in onDrop(id, where_) }
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
