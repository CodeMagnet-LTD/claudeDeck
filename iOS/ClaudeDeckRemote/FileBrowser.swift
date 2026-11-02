import PhotosUI
import SwiftUI

/// The Mac's projects, then their folders and files (inside the project only): text files show
/// here, any file can be saved to this device or added to a session, and files go up into a folder.
struct ProjectFilesView: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        List(store.projects) { project in
            NavigationLink(project.name) { DirectoryView(projectID: project.id, path: "", title: project.name) }
        }
        .navigationTitle("Files")
    }
}

struct DirectoryView: View {
    @Environment(RemoteStore.self) private var store
    let projectID: UUID
    let path: String
    let title: String
    @AppStorage("files.showHidden") private var showHidden = false
    @State private var choosingFiles = false
    @State private var choosingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        let state = store.directories[RemoteStore.fileKey(projectID, path)]
        let entries = (state?.entries ?? []).filter { showHidden || !$0.isHidden }
        List(entries) { entry in
            let child = path.isEmpty ? entry.name : path + "/" + entry.name
            if entry.isDirectory {
                NavigationLink { DirectoryView(projectID: projectID, path: child, title: entry.name) } label: {
                    Label(entry.name, systemImage: "folder")
                }
            } else {
                NavigationLink { FileTextView(projectID: projectID, path: child) } label: {
                    HStack {
                        Label(entry.name, systemImage: "doc.text")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contextMenu { FileActions(projectID: projectID, path: child) }
                .swipeActions(edge: .leading) {
                    if transfer {
                        Button { store.transfers.download(projectID, path: child) } label: { Label("Save", systemImage: "square.and.arrow.down") }
                            .tint(.blue)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { TransfersBar() }
        .overlay {
            if state == nil { ProgressView() }
            else if let error = state?.error { Text(error).foregroundStyle(.secondary) }
            else if entries.isEmpty { Text("Empty folder").foregroundStyle(.secondary) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showHidden.toggle() } label: { Image(systemName: showHidden ? "eye" : "eye.slash") }
                    .accessibilityLabel(showHidden ? "Hide Hidden Files" : "Show Hidden Files")
            }
            if transfer {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { choosingFiles = true } label: { Label("Files…", systemImage: "folder") }
                        Button { choosingPhotos = true } label: { Label("Photos…", systemImage: "photo") }
                    } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel(Text("Upload Here"))
                }
            }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { store.transfers.upload(url, to: projectID, folder: path) }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: 20)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                for (index, item) in items.enumerated() {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")
                    store.transfers.upload(data, name: "Photo \(stamp)\(items.count > 1 ? "-\(index + 1)" : "").\(ext)", to: projectID, folder: path)
                }
            }
        }
        .refreshable { store.listDirectory(projectID, path: path) }
        .onAppear { store.listDirectory(projectID, path: path) }
    }

    private var transfer: Bool { store.snapshot?.supports(RemoteSnapshot.Feature.transfer) == true }
}

/// A file's menu: save it here, add it to one of the project's Claude sessions, copy its path.
struct FileActions: View {
    @Environment(RemoteStore.self) private var store
    let projectID: UUID
    let path: String

    var body: some View {
        let project = store.projects.first { $0.id == projectID }
        let absolute = project?.path.map { ($0 as NSString).appendingPathComponent(path) }
        if store.snapshot?.supports(RemoteSnapshot.Feature.transfer) == true {
            Button { store.transfers.download(projectID, path: path) } label: {
                Label("Save / Share…", systemImage: "square.and.arrow.down")
            }
            let sessions = (store.snapshot?.sessions ?? []).filter { $0.project == project?.name && $0.state != .notStarted && $0.state != .shell }
            if let absolute, !sessions.isEmpty {
                Menu {
                    ForEach(sessions) { session in
                        Button(session.name) { store.sessionAction(session.id, .insert("@" + Self.escaped(absolute) + " ")) }
                    }
                } label: { Label("Add to Session", systemImage: "text.badge.plus") }
            }
        }
        if let absolute {
            Button { UIPasteboard.general.string = absolute } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        }
    }

    /// Like a path dropped into a terminal: spaces and the like backslashed.
    static func escaped(_ path: String) -> String {
        path.reduce(into: "") { result, c in
            if " ()'\"&;$`!*?[]{}|<>#".contains(c) { result.append("\\") }
            result.append(c)
        }
    }
}

/// Downloads and uploads in progress, under the list.
struct TransfersBar: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        let items = store.transfers.items
        if !items.isEmpty {
            VStack(spacing: 6) {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.error != nil ? "exclamationmark.triangle" : item.finished ? "checkmark.circle" : item.upload ? "arrow.up.circle" : "arrow.down.circle")
                            .foregroundStyle(item.error != nil ? Color.orange : item.finished ? Color.green : Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.caption).lineLimit(1)
                            if let error = item.error {
                                Text(error).font(.caption2).foregroundStyle(.orange)
                            } else if !item.finished {
                                ProgressView(value: item.progress).progressViewStyle(.linear)
                            }
                        }
                        if !item.finished || item.error != nil {
                            Button { store.transfers.dismiss(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }
}

struct FileTextView: View {
    @Environment(RemoteStore.self) private var store
    let projectID: UUID
    let path: String
    @State private var wrap = false

    var body: some View {
        let state = store.files[RemoteStore.fileKey(projectID, path)]
        Group {
            if let text = state?.text {
                ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                        .padding(10)
                }
            } else if let error = state?.error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { wrap.toggle() } label: { Image(systemName: wrap ? "text.alignleft" : "arrow.left.and.right.text.vertical") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu { FileActions(projectID: projectID, path: path) } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom) { TransfersBar() }
        .onAppear { store.readFile(projectID, path: path) }
    }
}
