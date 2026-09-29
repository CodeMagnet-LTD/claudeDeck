import ClaudeDeckCore
import Observation
import SwiftUI

/// A Changes diff as a main-window tab. Status comes from the shared `ChangesModel` of the
/// directory; the diff text is loaded per tab so several diff tabs can be open.
struct DiffTabView: View {
    @Environment(AppModel.self) private var model
    let repo: String
    let path: String
    let staged: Bool
    @State private var loader = DiffLoader()

    var body: some View {
        let changes = ChangesModel.model(for: repo)
        let change = find(in: changes)
        Group {
            if let change, changes.repo != nil, loader.loaded {
                DiffPanel(changes: changes, change: change, diffFiles: loader.files)
            } else if !changes.loaded || (change != nil && !loader.loaded) {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                noChanges(changes)
            }
        }
        .onAppear { changes.activate() }
        .onDisappear { changes.deactivate() }
        // Reload when the change (or its counts) differs, and poll: working tree edits don't touch .git.
        .task(id: change) { if let change, let root = changes.repo { await loader.load(change, in: root) } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                changes.refresh(after: .zero)
                if let change = find(in: changes), let root = changes.repo { await loader.load(change, in: root) }
            }
        }
    }

    private func find(in changes: ChangesModel) -> GitChange? {
        (staged ? changes.status.staged : changes.status.unstaged).first { $0.path == path }
    }

    /// The file isn't changed (in this area) any more.
    private func noChanges(_ changes: ChangesModel) -> some View {
        let other = (staged ? changes.status.unstaged : changes.status.staged).first { $0.path == path }
        let tab = WorkspaceTab.diff(repo: repo, path: path, staged: staged)
        return VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text("No changes").font(.title3)
            Text(verbatim: path).font(.callout).foregroundStyle(.secondary)
            HStack {
                if let other {
                    Button(other.isStaged ? LocalizedStringKey("Show Staged Changes") : LocalizedStringKey("Show Working Tree Changes")) {
                        model.tabs.close(tab)
                        model.tabs.open(.diff(repo: repo, path: path, staged: other.isStaged), preview: true)
                    }
                }
                Button("Close Tab") { model.tabs.close(tab) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Loads one change's unified diff off the main actor.
@MainActor
@Observable
final class DiffLoader {
    private(set) var files: [DiffFile] = []
    private(set) var loaded = false
    @ObservationIgnored private var text: String?

    func load(_ change: GitChange, in repo: URL) async {
        let text = await Task.detached { Git.changeDiff(change, in: repo) }.value
        guard !Task.isCancelled else { return }
        loaded = true
        guard text != self.text else { return }
        self.text = text
        files = UnifiedDiff.parse(text)
    }
}
