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

/// Lazily loaded, live-updating file tree of one project. One recursive FSEvents stream per
/// tree; only directories already loaded are re-read. Children of each directory are loaded off
/// the main actor together with their `.gitignore` status.
@MainActor
@Observable
final class FileTree {
    let root: URL
    var showHidden = false
    var showIgnored = false
    var expanded: Set<String> = []
    /// All children per directory path (hidden and ignored ones included; filtered on read).
    private var entries: [String: [FileEntry]] = [:]
    @ObservationIgnored private var loading: [String: Int] = [:]
    @ObservationIgnored private var generation = 0
    /// Ignored entries of loaded directories (changes below them don't affect git status).
    @ObservationIgnored private var ignoredPaths: Set<String> = []
    @ObservationIgnored private var watcher: FSEventsWatcher?
    /// Symlink-resolved root (FSEvents reports real paths) and the git directories watched.
    @ObservationIgnored private let resolvedRoot: String
    @ObservationIgnored private var gitDirs: [String]
    @ObservationIgnored private var gitDirsResolved = false
    private(set) var gitRoot: URL?
    private(set) var gitStatus: [String: GitFileState] = [:]
    @ObservationIgnored private var gitTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root
        resolvedRoot = root.resolvingSymlinksInPath().path
        gitDirs = [resolvedRoot + "/.git"]
        refreshGit()
        startWatching()
    }

    func gitState(of url: URL) -> GitFileState? { gitStatus[url.resolvingSymlinksInPath().path] ?? gitStatus[url.path] }

    /// Re-reads `git status` off the main thread (coalesced).
    func refreshGit() {
        gitTask?.cancel()
        let root = self.root
        let needDirs = !gitDirsResolved
        gitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let (repo, status, dirs) = await Task.detached { () -> (URL?, [String: GitFileState], [URL]?) in
                guard let repo = Git.root(of: root) else { return (nil, [:], nil) }
                return (repo, Git.status(in: repo), needDirs ? Git.gitDirectories(of: root) : nil)
            }.value
            guard let self else { return }
            if self.gitRoot != repo { self.gitRoot = repo }
            if self.gitStatus != status { self.gitStatus = status }
            if let dirs { self.watchGitDirectories(dirs) }
        }
    }

    func children(of dir: URL) -> [FileEntry] {
        guard let cached = entries[dir.path] else {
            // Mutating observed state during body evaluation is not allowed; the load publishes later.
            if loading[dir.path] == nil { load(dir) }
            return []
        }
        return FileListing.visible(cached, showHidden: showHidden, showIgnored: showIgnored)
    }

    func reload(_ dir: URL) {
        load(dir)
        refreshGit()
    }

    func reloadAll() {
        for path in entries.keys { load(URL(fileURLWithPath: path)) }
        refreshGit()
    }

    func collapseAll() { expanded.removeAll() }

    private func load(_ dir: URL) {
        generation += 1
        let gen = generation
        loading[dir.path] = gen
        Task { [weak self] in
            let list = await Task.detached(priority: .userInitiated) { FileTree.list(dir) }.value
            guard let self, self.loading[dir.path] == gen else { return }
            self.loading[dir.path] = nil
            for entry in self.entries[dir.path] ?? [] { self.ignoredPaths.remove(entry.id) }
            for entry in list where entry.isIgnored { self.ignoredPaths.insert(entry.id) }
            if self.entries[dir.path] != list { self.entries[dir.path] = list }
        }
    }

    /// Children of `dir`, marked with git's verdict on which are ignored.
    nonisolated private static func list(_ dir: URL) -> [FileEntry] {
        let all = FileListing.allChildren(of: dir)
        let ignored = Git.ignoredNames(in: dir, names: all.filter { !$0.isIgnored }.map(\.name))
        guard !ignored.isEmpty else { return all }
        return all.map { entry in
            var entry = entry
            if ignored.contains(entry.name) { entry.isIgnored = true }
            return entry
        }
    }

    // MARK: Watching

    private func startWatching() {
        let paths = [URL(fileURLWithPath: resolvedRoot)] + gitDirs
            .filter { !$0.hasPrefix(resolvedRoot + "/") }
            .map { URL(fileURLWithPath: $0) }
        let watcher = FSEventsWatcher(paths: paths, latency: 0.2, queue: .main) { [weak self] events in
            MainActor.assumeIsolated { self?.handle(events) }
        }
        watcher.start()
        self.watcher = watcher   // releasing a previous watcher stops its stream
    }

    /// Worktrees and subfolder roots keep HEAD/index/refs outside the root: watch those too.
    private func watchGitDirectories(_ dirs: [URL]) {
        gitDirsResolved = true
        let resolved = dirs.map { $0.resolvingSymlinksInPath().path }
        guard !resolved.isEmpty, Set(resolved) != Set(gitDirs) else { return }
        gitDirs = resolved
        if resolved.contains(where: { !$0.hasPrefix(resolvedRoot + "/") }) { startWatching() }
    }

    private func handle(_ events: [FSEventsWatcher.Event]) {
        var dirs = Set<String>()
        var git = false
        for event in events {
            if event.mustRescan { reloadAll(); return }
            if let rel = gitRelative(event.path) {
                if rel == "info/exclude" { reloadAll(); return }
                if Git.isMetadataName(rel) { git = true }
                continue
            }
            let path = localPath(event.path)
            // Ignore rules apply to whole subtrees: re-read every loaded directory.
            if (path as NSString).lastPathComponent == ".gitignore" { reloadAll(); return }
            let parent = (path as NSString).deletingLastPathComponent
            if entries[parent] != nil { dirs.insert(parent) }
            if entries[path] != nil { dirs.insert(path) }
            if !git, !isIgnored(path) { git = true }
        }
        for dir in dirs { load(URL(fileURLWithPath: dir)) }
        if git { refreshGit() }
    }

    /// Path relative to a watched git directory, or nil.
    private func gitRelative(_ path: String) -> String? {
        for dir in gitDirs where path == dir || path.hasPrefix(dir + "/") {
            return path == dir ? "" : String(path.dropFirst(dir.count + 1))
        }
        return nil
    }

    /// Event paths are symlink-resolved; the tree is keyed by `root`'s spelling.
    private func localPath(_ path: String) -> String {
        guard resolvedRoot != root.path, path == resolvedRoot || path.hasPrefix(resolvedRoot + "/") else { return path }
        return root.path + path.dropFirst(resolvedRoot.count)
    }

    /// Ignored itself or inside an ignored folder, as far as the loaded directories tell.
    private func isIgnored(_ path: String) -> Bool {
        var p = path
        while p.count > root.path.count {
            if ignoredPaths.contains(p) || FileListing.ignoredNames.contains((p as NSString).lastPathComponent) { return true }
            p = (p as NSString).deletingLastPathComponent
        }
        return false
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
    /// Most recently shown first; older trees are dropped (their FSEvents streams stop).
    @State private var recentRoots: [String] = []
    @State private var selection: Set<String> = []
    @FocusState private var listFocused: Bool

    private static let keptTrees = 3

    var body: some View {
        if let project = model.explorerProject {
            let tree = tree(for: project)
            VStack(spacing: 0) {
                header(project: project, tree: tree)
                Divider()
                // Plain stack, not VSplitView: a split view inside the inspector could enter an
                // endless constraint-update loop (crash) when the history pane appeared.
                List(selection: $selection) {
                    ForEach(tree.children(of: tree.root)) { entry in
                        FileNode(entry: entry, tree: tree, selection: $selection, project: project, focus: $listFocused)
                    }
                }
                .listStyle(.sidebar)
                .frame(maxHeight: .infinity)
                .focused($listFocused)
                // ⌘X / ⌘C / ⌘V while the tree has focus (the terminal keeps its own when focused).
                .onCopyCommand { FileClipboard.providers(for: selectedURLs, cut: false) }
                .onCutCommand { FileClipboard.providers(for: selectedURLs, cut: true) }
                .onPasteCommand(of: [.fileURL]) { providers in
                    let target = pasteTarget(tree: tree)
                    FileClipboard.urls(from: providers) { urls in FileActions.paste(urls, into: target, tree: tree) }
                }
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

    private var selectedURLs: [URL] { selection.sorted().map { URL(fileURLWithPath: $0) } }

    /// Paste into the selected folder, the selected file's folder, or the root.
    private func pasteTarget(tree: FileTree) -> URL {
        guard selection.count == 1, let path = selection.first else { return tree.root }
        let url = URL(fileURLWithPath: path)
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isDir ? url : url.deletingLastPathComponent()
    }

    /// The single selected regular file (history is per file).
    private var selectedFile: URL? {
        guard selection.count == 1, let path = selection.first else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func tree(for project: Project) -> FileTree {
        let path = project.path
        if let tree = trees[path] {
            if recentRoots.first != path {
                Task { @MainActor in recentRoots = [path] + recentRoots.filter { $0 != path } }
            }
            return tree
        }
        let tree = FileTree(root: URL(fileURLWithPath: path))
        Task { @MainActor in
            trees[path] = tree
            recentRoots = [path] + recentRoots.filter { $0 != path }
            for old in recentRoots.dropFirst(Self.keptTrees) { trees[old] = nil }
            recentRoots = Array(recentRoots.prefix(Self.keptTrees))
        }
        return tree
    }

    private func header(project: Project, tree: FileTree) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").foregroundStyle(.secondary)
            Text(project.name).font(.headline).lineLimit(1)
            Spacer()
            Button { tree.collapseAll() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.borderless)
            .help("Collapse All")
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
                Button("Paste") { FileActions.pasteFromClipboard(into: tree.root, tree: tree) }
                    .disabled(!FileClipboard.hasFiles)
                Divider()
                Toggle("Show Ignored Files", isOn: Binding(get: { tree.showIgnored }, set: { tree.showIgnored = $0 }))
                Button("Collapse All") { tree.collapseAll() }
                Divider()
                Button("Quick Open…") { ExplorerSheets.quickOpen(model: model) }
                Button("Find in Files…") { ExplorerSheets.findInFiles(model: model) }
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
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let entry: FileEntry
    let tree: FileTree
    @Binding var selection: Set<String>
    let project: Project
    var focus: FocusState<Bool>.Binding
    @State private var dropTargeted = false

    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: tree.isExpanded(entry)) {
                if tree.expanded.contains(entry.id) {
                    ForEach(tree.children(of: entry.url)) { child in
                        AnyView(FileNode(entry: child, tree: tree, selection: $selection, project: project, focus: focus))
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

    /// Drops onto a folder land in it; onto a file, next to it.
    private var dropFolder: URL { entry.isDirectory ? entry.url : entry.url.deletingLastPathComponent() }

    private var row: some View {
        FileLabel(entry: entry, state: tree.gitState(of: entry.url))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(dropTargeted && entry.isDirectory ? Color.accentColor.opacity(0.25) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .onTapGesture(count: 2) {
                if entry.isDirectory { tree.isExpanded(entry).wrappedValue.toggle() } else { EditorOpener.openDefault(entry.url, model: model, openWindow: openWindow) }
            }
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) {
                    if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
                } else {
                    selection = [entry.id]
                }
                focus.wrappedValue = true
            }
            .contextMenu {
                let urls = selection.contains(entry.id) ? selection.map { URL(fileURLWithPath: $0) } : [entry.url]
                FileMenu(urls: urls, tree: tree, project: project)
            }
            .onDrag {
                // Remembered so a drop onto a folder of this tree moves instead of copying.
                let urls = selection.contains(entry.id) ? selection.map { URL(fileURLWithPath: $0) } : [entry.url]
                FileClipboard.dragging = FileClipboard.paths(urls)
                return NSItemProvider(object: entry.url as NSURL)
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                let folder = dropFolder
                FileClipboard.urls(from: providers) { urls in FileActions.drop(urls, into: folder, tree: tree) }
                return true
            }
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
        .opacity(entry.isIgnored ? 0.45 : 1)
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
    @Environment(\.openWindow) private var openWindow
    let urls: [URL]
    let tree: FileTree
    let project: Project

    var body: some View {
        if let url = urls.first {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir {
                Button("Open in Editor") { urls.forEach { EditorOpener.open($0, openWindow: openWindow, model: model) } }
            }
            if VSCode.isInstalled {
                Button("Open in VS Code") { urls.forEach(VSCode.open) }
            }
            if PencilApp.isPenFile(url), PencilApp.isInstalled {
                Button("Open in Pencil") { urls.filter(PencilApp.isPenFile).forEach(PencilApp.open) }
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
            Button("Cut") { FileClipboard.write(urls, cut: true) }
            Button("Copy") { FileClipboard.write(urls, cut: false) }
            Button("Paste") { FileActions.pasteFromClipboard(into: isDir ? url : url.deletingLastPathComponent(), tree: tree) }
                .disabled(!FileClipboard.hasFiles)
            Button("Duplicate") { FileActions.duplicate(urls, tree: tree) }
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
    /// Double-click: `.pen` files in Pencil, otherwise VS Code if installed, else the default app.
    static func openDefault(_ url: URL) {
        if PencilApp.isPenFile(url), PencilApp.isInstalled { PencilApp.open(url); return }
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
        revealNested(name, in: dir, tree: tree)
    }

    /// Accepts nested paths ("a/b/c").
    static func newFolder(in dir: URL, tree: FileTree) {
        guard let name = TextPrompt.ask(title: String(localized: "New Folder"), placeholder: String(localized: "folder")) else { return }
        let url = dir.appending(path: name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return fail(String(localized: "\(name) already exists.")) }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch { return fail(error.localizedDescription) }
        revealNested(name, in: dir, tree: tree)
    }

    /// Expands `dir` and every folder created on the way to `name` ("a/b/c.swift").
    private static func revealNested(_ name: String, in dir: URL, tree: FileTree) {
        let dirs = [dir] + FileListing.intermediateDirectories(of: name, in: dir)
        for d in dirs { tree.expanded.insert(d.path) }
        for d in dirs { tree.reload(d) }
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

    /// Copies next to the originals ("a copy.txt").
    static func duplicate(_ urls: [URL], tree: FileTree) {
        transfer(urls.map { ($0, $0.deletingLastPathComponent()) }, move: false, tree: tree)
    }

    /// ⌘V / Paste: files cut in this tree are moved, anything else (also copied in Finder) is copied.
    static func paste(_ urls: [URL], into dir: URL, tree: FileTree) {
        guard !urls.isEmpty else { return }
        let move = FileClipboard.isPendingCut(urls)
        if move { FileClipboard.cut = [] }
        transfer(urls.map { ($0, dir) }, move: move, tree: tree)
    }

    static func pasteFromClipboard(into dir: URL, tree: FileTree) {
        paste(FileClipboard.fileURLs(), into: dir, tree: tree)
    }

    /// Drop onto a folder: rows dragged from this tree move (⌥ copies), Finder files are copied in.
    static func drop(_ urls: [URL], into dir: URL, tree: FileTree) {
        let fromTree = !urls.isEmpty && FileClipboard.paths(urls).isSubset(of: FileClipboard.dragging)
        FileClipboard.dragging = []
        let move = fromTree && !NSEvent.modifierFlags.contains(.option)
        transfer(urls.map { ($0, dir) }, move: move, tree: tree)
    }

    /// Moves or copies each source into its folder, off the main actor. Copies never overwrite
    /// ("name copy"); moving onto an existing name or into itself fails.
    private static func transfer(_ items: [(source: URL, dir: URL)], move: Bool, tree: FileTree) {
        let items = items.filter { item in
            // Moving to where it already is is a no-op.
            !(move && item.source.deletingLastPathComponent().standardizedFileURL.path == item.dir.standardizedFileURL.path)
        }
        guard !items.isEmpty else { return }
        if move, items.contains(where: { FileListing.isSameOrDescendant($0.dir, of: $0.source) }) {
            return fail(String(localized: "A folder can’t be moved into itself."))
        }
        let pairs = items.map { ($0.source, $0.dir) }
        Task {
            let errors = await Task.detached { () -> [String] in
                let fm = FileManager.default
                var errors: [String] = []
                for (source, dir) in pairs {
                    do {
                        if move {
                            let target = dir.appending(path: source.lastPathComponent)
                            guard !fm.fileExists(atPath: target.path) else {
                                errors.append(String(localized: "\(source.lastPathComponent) already exists.")); continue
                            }
                            try fm.moveItem(at: source, to: target)
                        } else {
                            try fm.copyItem(at: source, to: FileListing.availableCopyURL(for: source.lastPathComponent, in: dir))
                        }
                    } catch { errors.append(error.localizedDescription) }
                }
                return errors
            }.value
            var dirs = Set(pairs.map(\.1))
            if move { dirs.formUnion(pairs.map { $0.0.deletingLastPathComponent() }) }
            for dir in dirs { tree.reload(dir) }
            if let dir = pairs.first?.1, dir.standardizedFileURL.path != tree.root.standardizedFileURL.path { tree.expanded.insert(dir.path) }
            if !errors.isEmpty { fail(errors.joined(separator: "\n")) }
        }
    }

    static func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "The operation couldn’t be completed")
        alert.informativeText = message
        alert.runAsSheet()
    }
}

/// File cut/copy/paste through the general pasteboard (interoperates with Finder) and the
/// in-app drag state that tells a move from a copy.
@MainActor
enum FileClipboard {
    /// Files cut in the tree; pasting exactly these moves them.
    static var cut: Set<String> = []
    /// Rows being dragged from the tree.
    static var dragging: Set<String> = []

    static func write(_ urls: [URL], cut isCut: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        cut = isCut ? paths(urls) : []
    }

    /// For `onCopyCommand` / `onCutCommand` (SwiftUI writes them to the pasteboard).
    static func providers(for urls: [URL], cut isCut: Bool) -> [NSItemProvider] {
        cut = isCut ? paths(urls) : []
        return urls.map { NSItemProvider(object: $0 as NSURL) }
    }

    /// Compared as paths: a folder URL may or may not carry a trailing slash after a round-trip.
    static func paths(_ urls: [URL]) -> Set<String> { Set(urls.map(\.standardizedFileURL.path)) }

    static func isPendingCut(_ urls: [URL]) -> Bool {
        !cut.isEmpty && paths(urls) == cut
    }

    static var hasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    static func fileURLs() -> [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Loads the file URLs of dropped / pasted item providers, then calls `done` on the main actor.
    static func urls(from providers: [NSItemProvider], done: @escaping @MainActor ([URL]) -> Void) {
        let providers = providers.filter { $0.canLoadObject(ofClass: NSURL.self) }
        guard !providers.isEmpty else { return }
        let collector = URLCollector(count: providers.count) { urls in
            Task { @MainActor in done(urls.filter(\.isFileURL)) }
        }
        for provider in providers {
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in collector.add(object as? URL) }
        }
    }
}
