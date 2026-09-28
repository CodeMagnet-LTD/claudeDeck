import AppKit
import ClaudeDeckCore
import Observation
import SwiftUI

/// Opens files and folders in Visual Studio Code if it is installed.
enum VSCode {
    static let bundleIDs = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"]

    @MainActor static var appURL: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    @MainActor static var isInstalled: Bool { appURL != nil }

    @MainActor static func open(_ url: URL) {
        guard let app = appURL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Lazily loaded, live-updating file tree of one project.
@MainActor
@Observable
final class FileTree {
    let root: URL
    var showHidden = false { didSet { entries.removeAll(); watchers.removeAll() } }
    var expanded: Set<String> = []
    private var entries: [String: [FileEntry]] = [:]
    @ObservationIgnored private var watchers: [String: DirectoryWatcher] = [:]
    private(set) var gitRoot: URL?
    private(set) var gitStatus: [String: GitFileState] = [:]
    @ObservationIgnored private var gitTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root
        refreshGit()
    }

    func gitState(of url: URL) -> GitFileState? { gitStatus[url.resolvingSymlinksInPath().path] ?? gitStatus[url.path] }

    /// Re-reads `git status` off the main thread (coalesced).
    func refreshGit() {
        gitTask?.cancel()
        let root = self.root
        gitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let (repo, status) = await Task.detached { () -> (URL?, [String: GitFileState]) in
                guard let repo = Git.root(of: root) else { return (nil, [:]) }
                return (repo, Git.status(in: repo))
            }.value
            self?.gitRoot = repo
            self?.gitStatus = status
        }
    }

    func children(of dir: URL) -> [FileEntry] {
        if let cached = entries[dir.path] { return cached }
        let list = FileListing.children(of: dir, showHidden: showHidden)
        // Mutating observed state during body evaluation is not allowed; publish next tick.
        Task { @MainActor in self.entries[dir.path] = list }
        watch(dir)
        return list
    }

    func reload(_ dir: URL) {
        entries[dir.path] = FileListing.children(of: dir, showHidden: showHidden)
        refreshGit()
    }

    func reloadAll() {
        for path in entries.keys { reload(URL(fileURLWithPath: path)) }
    }

    private func watch(_ dir: URL) {
        guard watchers[dir.path] == nil else { return }
        let watcher = DirectoryWatcher(url: dir, debounce: 0.2) { [weak self] in
            Task { @MainActor in self?.reload(dir) }
        }
        watcher.start()
        watchers[dir.path] = watcher
    }

    func isExpanded(_ entry: FileEntry) -> Binding<Bool> {
        Binding(
            get: { self.expanded.contains(entry.id) },
            set: { open in
                if open { self.expanded.insert(entry.id) } else { self.expanded.remove(entry.id) }
            }
        )
    }
}

/// Right-hand panel: the focused session's project files.
struct FileBrowserPanel: View {
    @Environment(AppModel.self) private var model
    @State private var trees: [String: FileTree] = [:]
    @State private var selection: Set<String> = []

    var body: some View {
        if let project = focusedProject {
            let tree = tree(for: project)
            VStack(spacing: 0) {
                header(project: project, tree: tree)
                Divider()
                // Plain stack, not VSplitView: a split view inside the inspector could enter an
                // endless constraint-update loop (crash) when the history pane appeared.
                List(selection: $selection) {
                    ForEach(tree.children(of: tree.root)) { entry in
                        FileNode(entry: entry, tree: tree, selection: $selection, project: project)
                    }
                }
                .listStyle(.sidebar)
                .frame(maxHeight: .infinity)
                if let file = selectedFile, tree.gitRoot != nil {
                    Divider()
                    FileHistoryView(file: file, tree: tree)
                        .frame(height: 240)
                }
            }
            .onChange(of: project.path) { _, _ in selection = [] }
        } else {
            Text("Select a session to see its files")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The single selected regular file (history is per file).
    private var selectedFile: URL? {
        guard selection.count == 1, let path = selection.first else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The focused session's project; for worktree sessions rooted at the session's worktree.
    private var focusedProject: Project? {
        let selected = model.selectedSessionID.flatMap { model.deck.session($0) }
        // A project clicked in the sidebar wins over the selected session's project.
        if let browsed = model.browsedProjectID, let p = model.deck.project(browsed), selected?.projectID != browsed {
            return p
        }
        let session = selected
        guard var project = session.flatMap({ model.deck.project($0.projectID) }) else { return model.deck.projects.first }
        if let wd = session?.workingDirectory, FileManager.default.fileExists(atPath: wd) { project.path = wd }
        return project
    }

    private func tree(for project: Project) -> FileTree {
        if let tree = trees[project.path] { return tree }
        let tree = FileTree(root: URL(fileURLWithPath: project.path))
        Task { @MainActor in trees[project.path] = tree }
        return tree
    }

    private func header(project: Project, tree: FileTree) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").foregroundStyle(.secondary)
            Text(project.name).font(.headline).lineLimit(1)
            Spacer()
            Toggle(isOn: Binding(get: { tree.showHidden }, set: { tree.showHidden = $0 })) {
                Image(systemName: "eye")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Show Hidden Files")
            if VSCode.isInstalled {
                Button { VSCode.open(tree.root) } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.borderless)
                .help("Open Project in VS Code")
            }
            Menu {
                Button("New File…") { FileActions.newFile(in: tree.root, tree: tree) }
                Button("New Folder…") { FileActions.newFolder(in: tree.root, tree: tree) }
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([tree.root]) }
                Button("Refresh") { tree.reloadAll() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// One row of the tree. Click handling is explicit: a drag source on a List row swallows the
/// list's own click-to-select on macOS.
struct FileNode: View {
    let entry: FileEntry
    let tree: FileTree
    @Binding var selection: Set<String>
    let project: Project

    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: tree.isExpanded(entry)) {
                if tree.expanded.contains(entry.id) {
                    ForEach(tree.children(of: entry.url)) { child in
                        AnyView(FileNode(entry: child, tree: tree, selection: $selection, project: project))
                    }
                }
            } label: {
                row
            }
            .tag(entry.id)
        } else {
            row.tag(entry.id)
        }
    }

    private var row: some View {
        FileLabel(entry: entry, state: tree.gitState(of: entry.url))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if entry.isDirectory { tree.isExpanded(entry).wrappedValue.toggle() } else { FileActions.openDefault(entry.url) }
            }
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) {
                    if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
                } else {
                    selection = [entry.id]
                }
            }
            .contextMenu {
                let urls = selection.contains(entry.id) ? selection.map { URL(fileURLWithPath: $0) } : [entry.url]
                FileMenu(urls: urls, tree: tree, project: project)
            }
            .onDrag { NSItemProvider(object: entry.url as NSURL) }
    }
}

struct FileLabel: View {
    let entry: FileEntry
    var state: GitFileState?

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(state.map(GitStyle.color) ?? .primary)
            Spacer(minLength: 4)
            if let state, !entry.isDirectory {
                Text(state.rawValue)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(GitStyle.color(state))
            } else if state != nil {
                Circle().fill(GitStyle.color(.modified).opacity(0.7)).frame(width: 5, height: 5)
            }
        }
    }
}

enum GitStyle {
    static func color(_ state: GitFileState) -> Color {
        switch state {
        case .modified, .renamed: .orange
        case .added, .untracked: .green
        case .deleted, .conflicted: .red
        }
    }
}

/// Commit history of one file; click a commit to see its diff.
struct FileHistoryView: View {
    let file: URL
    let tree: FileTree
    @State private var commits: [GitCommit] = []
    @State private var loading = true
    @State private var shownDiff: DiffSheet.Content?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                Text("History").font(.subheadline.weight(.semibold))
                Text(file.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            List {
                if let state = tree.gitState(of: file), state != .untracked {
                    Button {
                        show(title: String(localized: "Uncommitted Changes")) { repo in Git.workingDiff(of: file, in: repo) }
                    } label: {
                        HStack {
                            Circle().fill(GitStyle.color(state)).frame(width: 7, height: 7)
                            Text("Uncommitted Changes").font(.callout)
                        }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(commits) { commit in
                    Button {
                        show(title: "\(commit.shortHash) — \(commit.subject)") { repo in Git.diff(of: file, at: commit.hash, in: repo) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(commit.subject).font(.callout).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(commit.shortHash).monospaced()
                                Text(commit.author)
                                Text(commit.date.formatted(.relative(presentation: .named)))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
                if !loading && commits.isEmpty && tree.gitState(of: file) == nil {
                    Text("No commits for this file").foregroundStyle(.secondary).font(.callout)
                }
                if tree.gitState(of: file) == .untracked {
                    Text("New file, not yet added to Git").foregroundStyle(.secondary).font(.callout)
                }
            }
            .listStyle(.plain)
            .overlay { if loading { ProgressView().controlSize(.small) } }
        }
        .task(id: file) {
            loading = true
            let root = tree.gitRoot
            commits = await Task.detached { root.map { Git.log(of: file, in: $0) } ?? [] }.value
            loading = false
        }
        .sheet(item: $shownDiff) { DiffSheet(content: $0) }
    }

    private func show(title: String, _ load: @escaping @Sendable (URL) -> String) {
        guard let repo = tree.gitRoot else { return }
        Task {
            let text = await Task.detached { load(repo) }.value
            shownDiff = DiffSheet.Content(title: title, file: file.lastPathComponent, text: text)
        }
    }
}

struct DiffSheet: View {
    struct Content: Identifiable {
        let id = UUID()
        var title: String
        var file: String
        var text: String
    }

    let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(content.title).font(.headline).lineLimit(1)
                    Text(content.file).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(content.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : String(line))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(for: line))
                    }
                }
                .textSelection(.enabled)
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private func color(for line: Substring) -> Color {
        if line.hasPrefix("@@") { return .purple }
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .primary
    }

    private func background(for line: Substring) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green.opacity(0.08) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red.opacity(0.08) }
        return .clear
    }
}

struct FileMenu: View {
    @Environment(AppModel.self) private var model
    let urls: [URL]
    let tree: FileTree
    let project: Project

    var body: some View {
        if let url = urls.first {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if VSCode.isInstalled {
                Button("Open in VS Code") { urls.forEach(VSCode.open) }
            }
            Button("Open") { urls.forEach { NSWorkspace.shared.open($0) } }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            if let session = model.selectedSessionID, model.terminals.isRunning(session) {
                Button(urls.count > 1 ? String(localized: "Add \(urls.count) Files to Claude") : String(localized: "Add @\(url.lastPathComponent) to Claude")) {
                    let mentions = urls.map { "@" + FileListing.relativePath(of: $0, in: tree.root) }.joined(separator: " ")
                    model.terminals.type(mentions + " ", into: session)
                }
            }
            Divider()
            Button("Copy Path") { FileActions.copy(urls.map(\.path).joined(separator: "\n")) }
            Button("Copy Relative Path") {
                FileActions.copy(urls.map { FileListing.relativePath(of: $0, in: tree.root) }.joined(separator: "\n"))
            }
            Divider()
            let parent = isDir ? url : url.deletingLastPathComponent()
            Button("New File…") { FileActions.newFile(in: parent, tree: tree) }
            Button("New Folder…") { FileActions.newFolder(in: parent, tree: tree) }
            if urls.count == 1 {
                Button("Rename…") { FileActions.rename(url, tree: tree) }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { FileActions.trash(urls, tree: tree) }
        }
    }
}

@MainActor
enum FileActions {
    /// Double-click: VS Code if installed, else the default app.
    static func openDefault(_ url: URL) {
        if VSCode.isInstalled { VSCode.open(url) } else { NSWorkspace.shared.open(url) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func newFile(in dir: URL, tree: FileTree) {
        guard let name = TextPrompt.ask(title: String(localized: "New File"), placeholder: String(localized: "file.txt")) else { return }
        let url = dir.appending(path: name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return fail(String(localized: "\(name) already exists.")) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        } catch { return fail(error.localizedDescription) }
        tree.expanded.insert(dir.path)
        tree.reload(url.deletingLastPathComponent())
    }

    static func newFolder(in dir: URL, tree: FileTree) {
        guard let name = TextPrompt.ask(title: String(localized: "New Folder"), placeholder: String(localized: "folder")) else { return }
        do {
            try FileManager.default.createDirectory(at: dir.appending(path: name), withIntermediateDirectories: false)
        } catch { return fail(error.localizedDescription) }
        tree.expanded.insert(dir.path)
        tree.reload(dir)
    }

    static func rename(_ url: URL, tree: FileTree) {
        guard let name = TextPrompt.ask(title: String(localized: "Rename"), placeholder: String(localized: "Name"), initial: url.lastPathComponent),
              name != url.lastPathComponent else { return }
        do {
            try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appending(path: name))
        } catch { return fail(error.localizedDescription) }
        tree.reload(url.deletingLastPathComponent())
    }

    static func trash(_ urls: [URL], tree: FileTree) {
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? String(localized: "Move “\(urls[0].lastPathComponent)” to the Trash?") : String(localized: "Move \(urls.count) items to the Trash?")
        alert.informativeText = String(localized: "You can restore items from the Trash.")
        alert.addButton(withTitle: String(localized: "Move to Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runAsSheet() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle(urls) { _, error in
            Task { @MainActor in
                if let error { fail(error.localizedDescription) }
                for dir in Set(urls.map { $0.deletingLastPathComponent() }) { tree.reload(dir) }
            }
        }
    }

    static func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "The operation couldn’t be completed")
        alert.informativeText = message
        alert.runAsSheet()
    }
}
