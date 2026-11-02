import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The Mac's projects, then their folders and files (inside the project only). A file opens on
/// its own screen: a preview, Save / Share, Add to Session, Copy Path. Files and photos go up into
/// the folder shown (the buttons under the list, or dropped on it on iPad).
struct ProjectFilesView: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        List(store.projects) { project in
            NavigationLink { DirectoryView(projectID: project.id, path: "", title: project.name) } label: {
                Label(project.name, systemImage: project.pinned ? "pin.fill" : "folder")
            }
        }
        .navigationTitle("Files")
    }
}

/// What a file is, from its name: icon, color, and how it can be shown here.
enum FileKind {
    case folder, image, pdf, video, audio, archive, code, text, document, other

    init(_ name: String, isDirectory: Bool = false) {
        guard !isDirectory else { self = .folder; return }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "svg", "ico": self = .image
        case "pdf": self = .pdf
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": self = .video
        case "mp3", "m4a", "wav", "aac", "flac", "caf": self = .audio
        case "zip", "gz", "tgz", "tar", "rar", "7z", "xz", "dmg", "ipa", "apk": self = .archive
        case "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "kt", "java", "c", "h", "m", "mm", "cpp", "cs",
             "php", "sh", "zsh", "json", "yml", "yaml", "toml", "xml", "html", "css", "scss", "sql", "gradle", "plist", "xcconfig":
            self = .code
        case "md", "txt", "log", "csv", "env", "ini", "cfg", "conf", "rtf": self = .text
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt": self = .document
        default: self = ext.isEmpty || name.hasPrefix(".") ? .text : .other
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .video: "film"
        case .audio: "waveform"
        case .archive: "doc.zipper"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .text: "doc.text"
        case .document: "doc"
        case .other: "doc"
        }
    }

    var color: Color {
        switch self {
        case .folder: .accentColor
        case .image: .purple
        case .pdf: .red
        case .video: .pink
        case .audio: .orange
        case .archive: .brown
        case .code: .teal
        case .text: .gray
        case .document: .blue
        case .other: .secondary
        }
    }

    /// Shown as text on the file's screen (read from the Mac, no download).
    var readsAsText: Bool { self == .code || self == .text }
    /// Shown inline once downloaded.
    var showsInline: Bool { self == .image }
}

struct FileIcon: View {
    let kind: FileKind
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24)
            .fill(kind.color.opacity(kind == .folder ? 0.18 : 0.14))
            .frame(width: size, height: size)
            .overlay(Image(systemName: kind.symbol).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(kind.color))
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
    @State private var dropTargeted = false

    var body: some View {
        let state = store.directories[RemoteStore.fileKey(projectID, path)]
        let entries = (state?.entries ?? []).filter { showHidden || !$0.isHidden }
        List(entries) { entry in
            let child = path.isEmpty ? entry.name : path + "/" + entry.name
            let kind = FileKind(entry.name, isDirectory: entry.isDirectory)
            if entry.isDirectory {
                NavigationLink { DirectoryView(projectID: projectID, path: child, title: entry.name) } label: {
                    HStack(spacing: 12) {
                        FileIcon(kind: kind)
                        Text(entry.name).lineLimit(1)
                    }
                }
            } else {
                NavigationLink { FileDetailView(projectID: projectID, path: child, size: entry.size) } label: {
                    HStack(spacing: 12) {
                        FileIcon(kind: kind)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu { FileActions(projectID: projectID, path: child) }
                .swipeActions(edge: .trailing) {
                    if transfer {
                        Button { store.transfers.download(projectID, path: child) } label: { Label("Save", systemImage: "square.and.arrow.down") }
                            .tint(.blue)
                    }
                }
            }
        }
        .overlay {
            if state == nil { ProgressView() }
            else if let error = state?.error { ContentUnavailableView(error, systemImage: "exclamationmark.triangle") }
            else if entries.isEmpty {
                ContentUnavailableView("Empty folder", systemImage: "folder",
                                       description: transfer ? Text("Upload files or photos here with the buttons below.") : nil)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(Label("Drop to upload into \(title)", systemImage: "square.and.arrow.down.on.square").font(.headline))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        // iPad: files dragged in from the Files app (or anywhere) go up into this folder.
        .onDrop(of: [.item], isTargeted: transfer ? $dropTargeted : .constant(false)) { providers in
            guard transfer else { return false }
            for provider in providers { receiveDrop(provider) }
            return true
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                TransfersBar()
                if transfer {
                    HStack(spacing: 10) {
                        Button { choosingFiles = true } label: {
                            Label("Upload Files", systemImage: "doc.badge.plus").frame(maxWidth: .infinity)
                        }
                        Button { choosingPhotos = true } label: {
                            Label("Upload Photos", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(store.connection != .connected)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showHidden.toggle() } label: { Image(systemName: showHidden ? "eye" : "eye.slash") }
                    .accessibilityLabel(showHidden ? "Hide Hidden Files" : "Show Hidden Files")
            }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { store.transfers.upload(url, to: projectID, folder: path) }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: 20, matching: .any(of: [.images, .videos]))
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

    /// A dropped item: its file (readable only inside the callback) copied, then uploaded.
    private func receiveDrop(_ provider: NSItemProvider) {
        let type = provider.registeredTypeIdentifiers.first ?? UTType.item.identifier
        _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
            guard let url else { return }
            let folder = FileManager.default.temporaryDirectory.appending(path: "Dropped/\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: provider.suggestedName.map { $0 + (url.pathExtension.isEmpty || $0.hasSuffix("." + url.pathExtension) ? "" : "." + url.pathExtension) } ?? url.lastPathComponent)
            guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
            Task { @MainActor in store.transfers.upload(copy, to: projectID, folder: path) }
        }
    }
}

/// One file of the Mac: what it is, a preview, and what can be done with it.
struct FileDetailView: View {
    @Environment(RemoteStore.self) private var store
    let projectID: UUID
    let path: String
    let size: Int
    @State private var wrap = true
    @State private var image: UIImage?
    @State private var quickLook: URL?

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let kind = FileKind(name)
        let text = store.files[RemoteStore.fileKey(projectID, path)]
        let preview = store.transfers.preview(projectID, path: path)
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    FileIcon(kind: kind, size: 64)
                    Text(name).font(.headline).multilineTextAlignment(.center).textSelection(.enabled)
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) · \(folderLabel)")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.top, 8)
                FileActionButtons(projectID: projectID, path: path, onPreview: kind.readsAsText || kind.showsInline ? nil : { openQuickLook() })
                if let preview, !preview.finished, preview.error == nil {
                    ProgressView(value: preview.progress) { Text("Loading the preview…").font(.caption) }
                        .padding(.horizontal)
                }
                if let error = preview?.error { Text(error).font(.callout).foregroundStyle(.orange) }
                // The preview.
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { openQuickLook() }
                } else if kind.readsAsText || (!kind.showsInline && size <= RemoteFiles.maxFileSize && kind == .other) {
                    if let body = text?.text {
                        Text(body)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    } else if let error = text?.error {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { TransfersBar().padding(.horizontal, 12).padding(.bottom, 6) }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($quickLook)
        .onAppear {
            if kind.readsAsText || (kind == .other && size <= RemoteFiles.maxFileSize) { store.readFile(projectID, path: path) }
            // Pictures show right away (small enough to fetch).
            if kind.showsInline, size <= 30_000_000, transfer {
                store.transfers.download(projectID, path: path) { url in image = UIImage(contentsOfFile: url.path) }
            }
        }
    }

    private var transfer: Bool { store.snapshot?.supports(RemoteSnapshot.Feature.transfer) == true }

    private var folderLabel: String {
        let project = store.projects.first { $0.id == projectID }?.name ?? ""
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? project : project + "/" + folder
    }

    /// PDFs, videos, documents: fetched, then the system viewer.
    private func openQuickLook() {
        guard transfer else { return }
        store.transfers.download(projectID, path: path) { url in quickLook = url }
    }
}

/// The file screen's big buttons.
struct FileActionButtons: View {
    @Environment(RemoteStore.self) private var store
    let projectID: UUID
    let path: String
    var onPreview: (() -> Void)?

    var body: some View {
        let project = store.projects.first { $0.id == projectID }
        let absolute = project?.path.map { ($0 as NSString).appendingPathComponent(path) }
        let sessions = FileActions.sessions(of: project, in: store)
        let transfer = store.snapshot?.supports(RemoteSnapshot.Feature.transfer) == true
        VStack(spacing: 10) {
            if transfer {
                Button { store.transfers.download(projectID, path: path) } label: {
                    Label("Save / Share…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            HStack(spacing: 10) {
                if let onPreview, transfer {
                    Button(action: onPreview) { Label("Preview", systemImage: "eye").frame(maxWidth: .infinity) }
                }
                if transfer, let absolute, !sessions.isEmpty {
                    Menu {
                        ForEach(sessions) { session in
                            Button(session.name) { FileActions.add(absolute, to: session.id, store: store) }
                        }
                    } label: { Label("Add to Session", systemImage: "text.badge.plus").frame(maxWidth: .infinity) }
                }
                if let absolute {
                    Button { UIPasteboard.general.string = absolute } label: {
                        Label("Copy Path", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .disabled(store.connection != .connected)
        .frame(maxWidth: 520)
    }
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
            let sessions = Self.sessions(of: project, in: store)
            if let absolute, !sessions.isEmpty {
                Menu {
                    ForEach(sessions) { session in
                        Button(session.name) { Self.add(absolute, to: session.id, store: store) }
                    }
                } label: { Label("Add to Session", systemImage: "text.badge.plus") }
            }
        }
        if let absolute {
            Button { UIPasteboard.general.string = absolute } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        }
    }

    /// The project's running Claude sessions.
    static func sessions(of project: RemoteProject?, in store: RemoteStore) -> [RemoteSession] {
        guard let project else { return [] }
        return (store.snapshot?.sessions ?? []).filter { $0.project == project.name && $0.state != .notStarted && $0.state != .shell }
    }

    /// The file's @mention into the session's prompt (no Enter), with a tap of feedback.
    @MainActor
    static func add(_ absolute: String, to sessionID: UUID, store: RemoteStore) {
        store.sessionAction(sessionID, .insert("@" + escaped(absolute) + " "))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Like a path dropped into a terminal: spaces and the like backslashed.
    static func escaped(_ path: String) -> String {
        path.reduce(into: "") { result, c in
            if " ()'\"&;$`!*?[]{}|<>#".contains(c) { result.append("\\") }
            result.append(c)
        }
    }
}

/// Downloads and uploads in progress; a finished upload offers to go into a session.
struct TransfersBar: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        let items = store.transfers.items
        if !items.isEmpty {
            VStack(spacing: 10) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        ZStack {
                            if !item.finished, item.error == nil {
                                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                                Circle().trim(from: 0, to: item.progress).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                Image(systemName: item.upload ? "arrow.up" : "arrow.down").font(.system(size: 10, weight: .bold))
                            } else {
                                Image(systemName: item.error != nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(item.error != nil ? Color.orange : Color.green)
                            }
                        }
                        .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(detail(item)).font(.caption).foregroundStyle(item.error != nil ? Color.orange : .secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if item.finished, item.upload, let path = item.savedPath, let projectID = item.projectID {
                            addToSession(path: path, projectID: projectID)
                        }
                        Button { store.transfers.dismiss(item.id) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 18)) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .animation(.snappy, value: items)
        }
    }

    private func detail(_ item: RemoteTransferClient.Item) -> String {
        if let error = item.error { return error }
        let done = ByteCountFormatter.string(fromByteCount: Int64(item.done), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(item.total), countStyle: .file)
        if item.finished { return item.upload ? String(localized: "Uploaded · \(total)") : String(localized: "Ready · \(total)") }
        return "\(Int(item.progress * 100))% · \(done) / \(total)"
    }

    @ViewBuilder
    private func addToSession(path: String, projectID: UUID) -> some View {
        let project = store.projects.first { $0.id == projectID }
        let sessions = FileActions.sessions(of: project, in: store)
        if let root = project?.path, !sessions.isEmpty {
            let absolute = (root as NSString).appendingPathComponent(path)
            Menu {
                ForEach(sessions) { session in
                    Button(session.name) { FileActions.add(absolute, to: session.id, store: store) }
                }
            } label: { Label("Add to Session", systemImage: "text.badge.plus").font(.caption.weight(.semibold)) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
