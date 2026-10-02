import AppKit
import ClaudeDeckCore
import Observation
import SwiftUI

extension RepositoryPage {
    var title: String {
        switch self {
        case .history: String(localized: "History")
        case .worktrees: String(localized: "Worktrees")
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .worktrees: "square.stack.3d.up"
        }
    }
}

extension AppModel {
    /// The History or Worktrees tab of the repository containing `directory`.
    func showRepositoryPage(_ page: RepositoryPage, of directory: String) {
        tabs.open(.repository(repo: directory, page: page))
        showMainWindow()
    }
}

/// A repository tab: page header (switch to the other page, refresh) over the page.
struct RepositoryPageView: View {
    @Environment(AppModel.self) private var model
    let repo: String
    let page: RepositoryPage

    var body: some View {
        switch page {
        case .history: HistoryPage(directory: repo)
        case .worktrees: WorktreesPage(directory: repo)
        }
    }
}

// MARK: - History

@MainActor
@Observable
final class HistoryModel {
    let directory: URL
    private(set) var repo: URL?
    private(set) var loaded = false
    private(set) var commits: [GitGraphCommit] = []
    private(set) var rows: [GitGraphRow] = []
    private(set) var graphWidth = 1
    var selection: String? { didSet { if selection != oldValue { loadFiles() } } }
    private(set) var files: [GitCommitFile] = []
    private(set) var message = ""
    var selectedFile: String? { didSet { if selectedFile != oldValue { loadDiff() } } }
    private(set) var diff: [DiffFile] = []
    private(set) var diffLoaded = false

    nonisolated static let limit = 500

    init(directory: String) { self.directory = URL(fileURLWithPath: directory) }

    func load() async {
        let dir = directory
        let (repo, commits) = await Task.detached { () -> (URL?, [GitGraphCommit]) in
            guard let root = Git.root(of: dir) else { return (nil, []) }
            return (root, Git.graphLog(refs: Git.historyRefs(in: dir), limit: HistoryModel.limit, in: dir))
        }.value
        let rows = await Task.detached { GitGraphLayout.layout(commits) }.value
        self.repo = repo
        self.commits = commits
        self.rows = rows
        graphWidth = min(rows.map(\.width).max() ?? 1, 16)
        loaded = true
        if let selection, !commits.contains(where: { $0.hash == selection }) { self.selection = nil }
    }

    var selectedCommit: GitGraphCommit? { selection.flatMap { s in commits.first { $0.hash == s } } }

    private func loadFiles() {
        files = []
        message = ""
        selectedFile = nil
        guard let commit = selectedCommit, let repo else { return }
        Task {
            let (files, message) = await Task.detached {
                (Git.commitFiles(commit, in: repo), Git.commitMessage(commit.hash, in: repo))
            }.value
            guard selection == commit.hash else { return }
            self.files = files
            self.message = message
            selectedFile = files.first?.path
        }
    }

    private func loadDiff() {
        diff = []
        diffLoaded = false
        guard let commit = selectedCommit, let repo, let file = files.first(where: { $0.path == selectedFile }) else { return }
        Task {
            let text = await Task.detached { Git.commitFileDiff(commit, file: file, in: repo) }.value
            guard selection == commit.hash, selectedFile == file.path else { return }
            diff = UnifiedDiff.parse(text)
            diffLoaded = true
        }
    }
}

private struct HistoryPage: View {
    @State private var history: HistoryModel

    init(directory: String) { _history = State(initialValue: HistoryModel(directory: directory)) }

    var body: some View {
        VStack(spacing: 0) {
            PageBar(title: String(localized: "History"), subtitle: history.loaded && history.commits.count >= HistoryModel.limit
                    ? String(localized: "Latest \(HistoryModel.limit) commits of HEAD, its upstream and the default branch")
                    : String(localized: "HEAD, its upstream and the default branch")) {
                Task { await history.load() }
            }
            Divider()
            if !history.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history.repo == nil {
                Text("This folder isn’t a Git repository").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history.commits.isEmpty {
                Text("No commits yet").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    CommitGraphList(history: history)
                        .frame(minWidth: 360, maxWidth: .infinity)
                    Divider()
                    CommitDetail(history: history)
                        .frame(minWidth: 320, idealWidth: 460, maxWidth: 620)
                }
            }
        }
        .task { await history.load() }
    }
}

/// Title row of a repository page.
private struct PageBar: View {
    let title: String
    let subtitle: String
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

private enum GraphStyle {
    static let lane: CGFloat = 14
    static let row: CGFloat = 26
    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .red, .indigo, .mint, .brown, .cyan]
    static func color(_ i: Int) -> Color { palette[i % palette.count] }
}

private struct CommitGraphList: View {
    let history: HistoryModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(history.commits.enumerated()), id: \.element.hash) { index, commit in
                    CommitRow(commit: commit, row: history.rows[index], graphWidth: history.graphWidth,
                              selected: history.selection == commit.hash)
                        .onTapGesture { history.selection = commit.hash }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct CommitRow: View {
    let commit: GitGraphCommit
    let row: GitGraphRow
    let graphWidth: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            GraphCell(row: row, isMerge: commit.isMerge)
                .frame(width: CGFloat(graphWidth) * GraphStyle.lane + 4, height: GraphStyle.row, alignment: .leading)
                .clipped()
            ForEach(commit.refs, id: \.self) { RefChip(ref: $0) }
            Text(commit.subject).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(commit.isMerge ? .secondary : .primary)
            Spacer(minLength: 8)
            Text(commit.author).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 120, alignment: .trailing)
            Text(commit.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
                .lineLimit(1).frame(width: 90, alignment: .trailing)
            Text(commit.shortHash).font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: GraphStyle.row)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Commit Hash") { FileActions.copy(commit.hash) }
            Button("Copy Subject") { FileActions.copy(commit.subject) }
        }
    }
}

/// The lanes of one row, drawn with `Canvas`.
private struct GraphCell: View {
    let row: GitGraphRow
    let isMerge: Bool

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            func x(_ column: Int) -> CGFloat { CGFloat(column) * GraphStyle.lane + GraphStyle.lane / 2 + 2 }
            for segment in row.segments {
                var path = Path()
                let (y0, y1) = segment.half == .top ? (CGFloat(0), mid) : (mid, size.height)
                let start = CGPoint(x: x(segment.from), y: y0), end = CGPoint(x: x(segment.to), y: y1)
                path.move(to: start)
                if segment.from == segment.to {
                    path.addLine(to: end)
                } else {
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: (y0 + y1) / 2), control2: CGPoint(x: end.x, y: (y0 + y1) / 2))
                }
                context.stroke(path, with: .color(GraphStyle.color(segment.color)), lineWidth: 1.6)
            }
            let r: CGFloat = isMerge ? 3.5 : 4.5
            let dot = Path(ellipseIn: CGRect(x: x(row.column) - r, y: mid - r, width: 2 * r, height: 2 * r))
            context.fill(dot, with: .color(GraphStyle.color(row.color)))
            if isMerge { context.stroke(dot, with: .color(Color(nsColor: .textBackgroundColor)), lineWidth: 1) }
        }
    }
}

private struct RefChip: View {
    let ref: String

    var body: some View {
        let isHead = ref.hasPrefix("HEAD -> ") || ref == "HEAD"
        let isTag = ref.hasPrefix("tag: ")
        let name = isHead && ref != "HEAD" ? String(ref.dropFirst("HEAD -> ".count)) : isTag ? String(ref.dropFirst(5)) : ref
        HStack(spacing: 2) {
            Image(systemName: isTag ? "tag" : isHead ? "smallcircle.filled.circle" : "arrow.triangle.branch").font(.system(size: 8))
            Text(name).font(.caption2.weight(isHead ? .bold : .medium)).lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill((isTag ? Color.yellow : isHead ? Color.accentColor : Color.gray).opacity(0.22)))
        .help(ref)
    }
}

private struct CommitDetail: View {
    let history: HistoryModel
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        if let commit = history.selectedCommit {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(history.message.isEmpty ? commit.subject : history.message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(8)
                    HStack(spacing: 6) {
                        Text(commit.shortHash).font(.caption.monospaced())
                        Text(commit.author).font(.caption)
                        Text(commit.date, format: .dateTime).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(10)
                Divider()
                List(history.files, selection: Binding(get: { history.selectedFile }, set: { history.selectedFile = $0 })) { file in
                    HStack(spacing: 6) {
                        Text(file.state.rawValue).font(.caption.monospaced().weight(.bold)).foregroundStyle(GitStyle.color(file.state))
                        Text((file.path as NSString).lastPathComponent).lineLimit(1)
                        Text((file.path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
                    .tag(file.path)
                }
                .frame(height: min(CGFloat(max(history.files.count, 1)) * 24 + 12, 200))
                Divider()
                diffView
            }
        } else {
            Text("Select a commit to see its changes").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var diffView: some View {
        if history.selectedFile == nil {
            Spacer()
        } else if !history.diffLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(history.diff.enumerated()), id: \.offset) { _, file in
                        if file.isBinary { Text("Binary file").foregroundStyle(.secondary).padding(8) }
                        ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                            Text(hunk.header)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.purple)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .frame(minWidth: 280, alignment: .leading)
                                .background(Color.purple.opacity(0.07))
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                DiffLineRow(line: line, width: gutterWidth, onAsk: nil)
                            }
                        }
                    }
                    if history.diff.isEmpty {
                        Text("No textual changes").foregroundStyle(.secondary).font(.callout).padding(8)
                    }
                }
                .padding(.bottom, 6)
                .frame(minWidth: viewportWidth, alignment: .leading)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var gutterWidth: CGFloat {
        let maxLine = history.diff.flatMap(\.hunks).map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 1
        return CGFloat(max(2, String(maxLine).count)) * 7 + 6
    }
}

// MARK: - Worktrees

struct WorktreeInfo: Identifiable, Sendable {
    var id: String { worktree.path }
    var worktree: GitWorktree
    var isDirty: Bool
}

private struct WorktreesPage: View {
    @Environment(AppModel.self) private var model
    let directory: String
    @State private var repo: URL?
    @State private var items: [WorktreeInfo] = []
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            PageBar(title: String(localized: "Worktrees"),
                    subtitle: String(localized: "All working trees of this repository (git worktree list)")) {
                Task { await load() }
            }
            Divider()
            if let error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { self.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
            }
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if repo == nil {
                Text("This folder isn’t a Git repository").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    WorktreeRow(item: item, sessions: sessions(using: item.worktree), busy: busy,
                                openSession: { openSession(item.worktree) }, remove: { remove(item) })
                }
                HStack {
                    Text("\(items.count) worktrees").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Prune Stale Worktrees") { prune() }
                        .disabled(busy)
                        .help("Remove the records of worktrees whose folders no longer exist (git worktree prune)")
                }
                .controlSize(.small)
                .padding(8)
            }
        }
        .task { await load() }
    }

    private func load() async {
        let dir = URL(fileURLWithPath: directory)
        let (root, items) = await Task.detached { () -> (URL?, [WorktreeInfo]) in
            guard let root = Git.root(of: dir) else { return (nil, []) }
            let items = Git.worktrees(in: root).map {
                WorktreeInfo(worktree: $0, isDirty: !$0.isPrunable && !$0.isBare && Git.isDirty(worktree: $0.path))
            }
            return (root, items)
        }.value
        repo = root
        self.items = items
        loaded = true
    }

    /// Sessions running in this worktree: their working directory, or `.claude/worktrees/<name>`
    /// of their project.
    private func sessions(using worktree: GitWorktree) -> [DeckSession] {
        model.deck.sessions.filter { session in
            if let wd = session.workingDirectory { return Git.samePath(wd, worktree.path) }
            if let name = session.worktreeName, let project = model.deck.project(session.projectID) {
                return Git.samePath(URL(fileURLWithPath: project.path).appending(path: ".claude/worktrees/\(name)").path, worktree.path)
            }
            if worktree.isMain, session.worktreeName == nil, let project = model.deck.project(session.projectID) {
                return Git.samePath(project.path, worktree.path)
            }
            return false
        }
    }

    private func openSession(_ worktree: GitWorktree) {
        if let existing = sessions(using: worktree).first {
            if !model.terminals.isRunning(existing.id) { model.launch(existing.id, resume: true) }
            model.reveal(existing.id)
            model.tabs.selectSessions()
            return
        }
        guard let main = items.first(where: \.worktree.isMain)?.worktree else { return }
        let project = model.deck.projects.first { Git.samePath($0.path, main.path) } ?? model.addProject(path: main.path)
        if worktree.isMain {
            model.newSession(in: project.id)
        } else {
            // Its own folder: the session starts there (no `--worktree`, the folder exists).
            var name = URL(fileURLWithPath: worktree.path).lastPathComponent
            if !DeckData.isValidWorktreeName(name) { name = model.deck.nextWorktreeName(for: project) }
            var created: DeckSession?
            model.mutate { deck in
                created = deck.addWorktreeSession(to: project.id, worktreeName: name)
                if let id = created?.id { deck.updateSession(id) { $0.workingDirectory = worktree.path } }
            }
            guard let session = created else { return }
            model.launch(session.id, resume: false)
            model.selectedSessionID = session.id
        }
        model.tabs.selectSessions()
    }

    private func remove(_ item: WorktreeInfo) {
        guard let repo, !item.worktree.isMain else { return }
        let name = URL(fileURLWithPath: item.worktree.path).lastPathComponent
        let users = sessions(using: item.worktree)
        var detail = String(localized: "The folder \(item.worktree.path) is deleted. Its branch is kept.")
        if !users.isEmpty {
            detail += "\n\n" + String(localized: "Used by: \(users.map(\.name).joined(separator: ", ")). Those sessions can’t restart without it.")
        }
        var force = false
        if item.isDirty {
            detail += "\n\n" + String(localized: "It has uncommitted changes, which will be lost.")
            guard Confirm.ask(String(localized: "Remove worktree “\(name)” with uncommitted changes?"), detail: detail,
                              action: String(localized: "Remove Anyway")) else { return }
            force = true
        } else {
            guard Confirm.ask(String(localized: "Remove worktree “\(name)”?"), detail: detail,
                              action: String(localized: "Remove")) else { return }
        }
        let worktree = item.worktree
        run { Git.removeWorktree(worktree, force: force, in: repo) }
    }

    private func prune() {
        guard let repo else { return }
        run { Git.pruneWorktrees(in: repo) }
    }

    private func run(_ operation: @escaping @Sendable () -> Git.Result) {
        busy = true
        error = nil
        Task {
            let result = await Task.detached { operation() }.value
            busy = false
            if !result.succeeded { error = result.message.isEmpty ? String(localized: "Git reported an error.") : result.message }
            await load()
        }
    }
}

private struct WorktreeRow: View {
    let item: WorktreeInfo
    let sessions: [DeckSession]
    let busy: Bool
    let openSession: () -> Void
    let remove: () -> Void

    var body: some View {
        let wt = item.worktree
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: wt.isMain ? "folder.fill" : "folder").foregroundStyle(wt.isPrunable ? .red : .accentColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: wt.path).lastPathComponent).font(.body.weight(.semibold))
                    if wt.isMain { badge(String(localized: "Main"), .blue) }
                    if item.isDirty { badge(String(localized: "Uncommitted changes"), .orange) }
                    if wt.isLocked { badge(String(localized: "Locked"), .gray) }
                    if wt.isPrunable { badge(String(localized: "Stale"), .red) }
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.caption)
                    if let branch = wt.branch {
                        Text(branch).font(.caption)
                    } else if let head = wt.head {
                        Text("Detached at \(String(head.prefix(7)))").font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                Text((wt.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if !sessions.isEmpty {
                    Label(sessions.map(\.name).joined(separator: ", "), systemImage: "terminal").font(.caption)
                }
                if let reason = wt.prunableReason ?? wt.lockedReason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button(sessions.isEmpty ? LocalizedStringKey("New Session") : LocalizedStringKey("Show Session"), action: openSession)
                    .disabled(wt.isPrunable || wt.isBare)
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wt.path)]) } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .help("Reveal in Finder")
                .disabled(wt.isPrunable)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .help(wt.isMain ? String(localized: "The main working tree can’t be removed.") : String(localized: "Remove Worktree…"))
                    .disabled(wt.isMain || wt.isBare || busy)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
    }
}
