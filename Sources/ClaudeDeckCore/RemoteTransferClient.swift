import Foundation
import Observation

/// Files to and from the host's projects, a piece at a time (remote side): downloads land in a
/// temporary file and go to `onDownloaded` (the phone's share sheet, the Mac's
/// Downloads); uploads go into a project folder.
@MainActor
@Observable
public final class RemoteTransferClient {
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let upload: Bool
        public var done = 0
        public var total = 0
        public var error: String?
        public var finished = false
        public var progress: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    public private(set) var items: [Item] = []
    /// Sends to the host; false when not connected.
    @ObservationIgnored public var send: ((RemoteMessage) -> Bool)?
    /// A finished download (a temporary file).
    @ObservationIgnored public var onDownloaded: ((URL) -> Void)?
    /// A finished upload: project, folder, saved path (relative to the project).
    @ObservationIgnored public var onUploaded: ((UUID, String, String) -> Void)?

    public init() {}

    private struct Download { let projectID: UUID; let path: String; let file: URL; let handle: FileHandle }
    private struct Upload { let projectID: UUID; let folder: String; let name: String; let file: URL; let total: Int; var sent: Int; let onSaved: ((String) -> Void)? }
    @ObservationIgnored private var downloads: [String: Download] = [:]
    @ObservationIgnored private var uploads: [String: Upload] = [:]

    private static func downloadKey(_ projectID: UUID, _ path: String) -> String { "d|\(projectID)|\(path)" }
    private static func uploadKey(_ projectID: UUID, _ folder: String, _ name: String) -> String { "u|\(projectID)|\(folder)|\(RemoteUpload.safeName(name))" }

    // MARK: Download

    public func download(_ projectID: UUID, path: String) {
        let key = Self.downloadKey(projectID, path)
        guard downloads[key] == nil else { return }
        let name = (path as NSString).lastPathComponent
        let folder = FileManager.default.temporaryDirectory.appending(path: "Downloads/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        guard FileManager.default.createFile(atPath: file.path, contents: nil), let handle = try? FileHandle(forWritingTo: file) else { return }
        downloads[key] = Download(projectID: projectID, path: path, file: file, handle: handle)
        put(Item(id: key, name: name, upload: false))
        if send?(.downloadFile(projectID: projectID, path: path, offset: 0)) != true { fail(key, String(localized: "Not connected")) }
    }

    public func received(_ projectID: UUID, path: String, offset: Int, total: Int, data: Data, error: String?) {
        let key = Self.downloadKey(projectID, path)
        guard let download = downloads[key] else { return }
        if let error { return fail(key, error) }
        do { try download.handle.write(contentsOf: data) } catch { return fail(key, String(localized: "Couldn't save the file")) }
        let done = offset + data.count
        update(key) { $0.done = done; $0.total = total }
        if done >= total || data.isEmpty {
            try? download.handle.close()
            downloads[key] = nil
            update(key) { $0.finished = true }
            onDownloaded?(download.file)
            removeLater(key)
        } else if send?(.downloadFile(projectID: projectID, path: path, offset: done)) != true {
            fail(key, String(localized: "Not connected"))
        }
    }

    // MARK: Upload

    /// A file picked on this device (copied first: the picker's URL is only readable for a moment).
    public func upload(_ url: URL, to projectID: UUID, folder: String, onSaved: ((String) -> Void)? = nil) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appending(path: "Uploads/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let file = copy.appending(path: url.lastPathComponent)
        do { try FileManager.default.copyItem(at: url, to: file) } catch {
            put(Item(id: UUID().uuidString, name: url.lastPathComponent, upload: true, error: String(localized: "Couldn't read the file")))
            return
        }
        start(file, name: url.lastPathComponent, to: projectID, folder: folder, onSaved: onSaved)
    }

    /// Bytes (a photo) saved as `name`.
    public func upload(_ data: Data, name: String, to projectID: UUID, folder: String, onSaved: ((String) -> Void)? = nil) {
        let copy = FileManager.default.temporaryDirectory.appending(path: "Uploads/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let file = copy.appending(path: name)
        guard (try? data.write(to: file)) != nil else { return }
        start(file, name: name, to: projectID, folder: folder, onSaved: onSaved)
    }

    private func start(_ file: URL, name: String, to projectID: UUID, folder: String, onSaved: ((String) -> Void)?) {
        let key = Self.uploadKey(projectID, folder, name)
        guard uploads[key] == nil else { return }
        let total = ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
        guard total <= RemoteTransfer.maxFileSize else {
            put(Item(id: key, name: name, upload: true, error: String(localized: "Too large to send")))
            return
        }
        uploads[key] = Upload(projectID: projectID, folder: folder, name: name, file: file, total: total, sent: 0, onSaved: onSaved)
        put(Item(id: key, name: name, upload: true, total: total))
        sendNext(key)
    }

    private func sendNext(_ key: String) {
        guard let upload = uploads[key] else { return }
        guard let handle = try? FileHandle(forReadingFrom: upload.file) else { return fail(key, String(localized: "Couldn't read the file")) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(upload.sent))
        let data = (try? handle.read(upToCount: RemoteTransfer.chunkSize)) ?? Data()
        let message = RemoteMessage.uploadFile(projectID: upload.projectID, folder: upload.folder, name: upload.name, offset: upload.sent, total: upload.total, data: data)
        if send?(message) != true { fail(key, String(localized: "Not connected")) }
    }

    public func acknowledged(_ projectID: UUID, folder: String, name: String, received: Int, path: String?, error: String?) {
        let key = Self.uploadKey(projectID, folder, name)
        guard var upload = uploads[key] else { return }
        if let error { return fail(key, error) }
        update(key) { $0.done = received }
        if let path {
            uploads[key] = nil
            try? FileManager.default.removeItem(at: upload.file.deletingLastPathComponent())
            update(key) { $0.finished = true }
            onUploaded?(projectID, folder, path)
            upload.onSaved?(path)
            removeLater(key)
        } else {
            upload.sent = received
            uploads[key] = upload
            sendNext(key)
        }
    }

    // MARK: List

    public func dismiss(_ id: String) {
        if let download = downloads.removeValue(forKey: id) {
            try? download.handle.close()
            try? FileManager.default.removeItem(at: download.file.deletingLastPathComponent())
        }
        if let upload = uploads.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: upload.file.deletingLastPathComponent())
        }
        items.removeAll { $0.id == id }
    }

    /// Lost connection: everything in flight stops (start it again).
    public func connectionLost() {
        for key in downloads.keys { fail(key, String(localized: "Connection lost")) }
        for key in uploads.keys { fail(key, String(localized: "Connection lost")) }
    }

    private func put(_ item: Item) {
        items.removeAll { $0.id == item.id }
        items.append(item)
    }

    private func update(_ id: String, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func fail(_ key: String, _ error: String) {
        if let download = downloads.removeValue(forKey: key) { try? download.handle.close() }
        uploads[key] = nil
        update(key) { $0.error = error }
    }

    private func removeLater(_ id: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            items.removeAll { $0.id == id && $0.finished }
        }
    }
}
