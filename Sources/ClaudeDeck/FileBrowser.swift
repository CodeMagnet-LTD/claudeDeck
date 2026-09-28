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

    init(root: URL) { self.root = root }

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
                List(selection: $selection) {
                    ForEach(tree.children(of: tree.root)) { entry in
                        FileNode(entry: entry, tree: tree)
                    }
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: String.self) { paths in
                    FileMenu(urls: paths.map { URL(fileURLWithPath: $0) }, tree: tree, project: project)
                } primaryAction: { paths in
                    for path in paths { openDefault(URL(fileURLWithPath: path)) }
                }
            }
        } else {
            Text("Dosyaları görmek için bir oturum seç")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var focusedProject: Project? {
        model.selectedSessionID.flatMap { model.deck.session($0) }.flatMap { model.deck.project($0.projectID) }
            ?? model.deck.projects.first
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
            .help("Gizli dosyaları göster")
            if VSCode.isInstalled {
                Button { VSCode.open(tree.root) } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.borderless)
                .help("Projeyi VS Code'da aç")
            }
            Menu {
                Button("Yeni dosya…") { FileActions.newFile(in: tree.root, tree: tree) }
                Button("Yeni klasör…") { FileActions.newFolder(in: tree.root, tree: tree) }
                Divider()
                Button("Finder'da göster") { NSWorkspace.shared.activateFileViewerSelecting([tree.root]) }
                Button("Yenile") { tree.reloadAll() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func openDefault(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue { return }
        if VSCode.isInstalled { VSCode.open(url) } else { NSWorkspace.shared.open(url) }
    }
}

struct FileNode: View {
    let entry: FileEntry
    let tree: FileTree

    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: tree.isExpanded(entry)) {
                if tree.expanded.contains(entry.id) {
                    ForEach(tree.children(of: entry.url)) { child in
                        AnyView(FileNode(entry: child, tree: tree))
                    }
                }
            } label: {
                FileLabel(entry: entry)
            }
            .tag(entry.id)
        } else {
            FileLabel(entry: entry).tag(entry.id)
        }
    }
}

struct FileLabel: View {
    let entry: FileEntry

    var body: some View {
        Label {
            Text(entry.name).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .frame(width: 16, height: 16)
        }
        .onDrag { NSItemProvider(object: entry.url as NSURL) }
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
                Button("VS Code'da aç") { urls.forEach(VSCode.open) }
            }
            Button("Aç") { urls.forEach { NSWorkspace.shared.open($0) } }
            Button("Finder'da göster") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            if let session = model.selectedSessionID, model.terminals.isRunning(session) {
                Button("Claude'a ekle (@\(urls.count > 1 ? "\(urls.count) dosya" : url.lastPathComponent))") {
                    let mentions = urls.map { "@" + FileListing.relativePath(of: $0, in: tree.root) }.joined(separator: " ")
                    model.terminals.type(mentions + " ", into: session)
                }
            }
            Divider()
            Button("Yolu kopyala") { FileActions.copy(urls.map(\.path).joined(separator: "\n")) }
            Button("Göreli yolu kopyala") {
                FileActions.copy(urls.map { FileListing.relativePath(of: $0, in: tree.root) }.joined(separator: "\n"))
            }
            Divider()
            let parent = isDir ? url : url.deletingLastPathComponent()
            Button("Yeni dosya…") { FileActions.newFile(in: parent, tree: tree) }
            Button("Yeni klasör…") { FileActions.newFolder(in: parent, tree: tree) }
            if urls.count == 1 {
                Button("Yeniden adlandır…") { FileActions.rename(url, tree: tree) }
            }
            Divider()
            Button("Çöp sepetine taşı", role: .destructive) { FileActions.trash(urls, tree: tree) }
        }
    }
}

@MainActor
enum FileActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func newFile(in dir: URL, tree: FileTree) {
        guard let name = TextPrompt.ask(title: "Yeni dosya", placeholder: "dosya.txt") else { return }
        let url = dir.appending(path: name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return fail("\(name) zaten var.") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        } catch { return fail(error.localizedDescription) }
        tree.expanded.insert(dir.path)
        tree.reload(url.deletingLastPathComponent())
    }

    static func newFolder(in dir: URL, tree: FileTree) {
        guard let name = TextPrompt.ask(title: "Yeni klasör", placeholder: "klasör") else { return }
        do {
            try FileManager.default.createDirectory(at: dir.appending(path: name), withIntermediateDirectories: false)
        } catch { return fail(error.localizedDescription) }
        tree.expanded.insert(dir.path)
        tree.reload(dir)
    }

    static func rename(_ url: URL, tree: FileTree) {
        guard let name = TextPrompt.ask(title: "Yeniden adlandır", placeholder: "Ad", initial: url.lastPathComponent),
              name != url.lastPathComponent else { return }
        do {
            try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appending(path: name))
        } catch { return fail(error.localizedDescription) }
        tree.reload(url.deletingLastPathComponent())
    }

    static func trash(_ urls: [URL], tree: FileTree) {
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "\"\(urls[0].lastPathComponent)\" çöp sepetine taşınsın mı?" : "\(urls.count) öğe çöp sepetine taşınsın mı?"
        alert.informativeText = "Çöp sepetinden geri alınabilir."
        alert.addButton(withTitle: "Çöpe taşı")
        alert.addButton(withTitle: "Vazgeç")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle(urls) { _, error in
            Task { @MainActor in
                if let error { fail(error.localizedDescription) }
                for dir in Set(urls.map { $0.deletingLastPathComponent() }) { tree.reload(dir) }
            }
        }
    }

    static func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "İşlem yapılamadı"
        alert.informativeText = message
        alert.runModal()
    }
}
