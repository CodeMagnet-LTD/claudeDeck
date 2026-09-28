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
        if let id = model.selectedSessionID, let session = model.deck.session(id) {
            let running = model.terminals.isRunning(id)
            VStack(spacing: 0) {
                if model.terminals.view(for: id) != nil {
                    TerminalHost(sessionID: id, registry: model.terminals, generation: running)
                        .id(id)
                        .background(Color(nsColor: DeckTerminalView.background))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !running {
                    ExitedBar(session: session)
                }
            }
            .navigationTitle(session.name)
            .navigationSubtitle(model.deck.project(session.projectID)?.path ?? "")
        } else {
            EmptyStateView()
        }
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
