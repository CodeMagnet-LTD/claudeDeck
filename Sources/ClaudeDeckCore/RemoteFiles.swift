import Foundation

/// The host's side of the phone's file browser: a project's folders and text files, never
/// anything outside the project (no `..`, no symlink escaping it).
public enum RemoteFiles {
    public static let maxFileSize = 400_000

    /// The file or folder at `relative` inside `root`, or nil when it would leave the project.
    public static func resolve(_ relative: String, in root: String) -> URL? {
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        let target = base.appending(path: relative).standardizedFileURL.resolvingSymlinksInPath()
        let basePath = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        guard target.path == basePath || target.path.hasPrefix(basePath + "/") else { return nil }
        return target
    }

    public static func list(_ relative: String, in root: String) -> RemoteMessage.DirectoryResult {
        guard let url = resolve(relative, in: root) else { return ([], String(localized: "Outside the project")) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else {
            return ([], String(localized: "Can't read this folder"))
        }
        // Dot-files are sent too (the phone hides them unless asked); .git and .DS_Store never.
        let entries = items.filter { $0.lastPathComponent != ".git" && $0.lastPathComponent != ".DS_Store" }.compactMap { item -> RemoteFileEntry? in
            let values = try? item.resourceValues(forKeys: Set(keys))
            return RemoteFileEntry(name: item.lastPathComponent, isDirectory: values?.isDirectory ?? false, size: values?.fileSize ?? 0)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
        return (entries, nil)
    }

    public static func read(_ relative: String, in root: String) -> (text: String?, size: Int, error: String?) {
        guard let url = resolve(relative, in: root) else { return (nil, 0, String(localized: "Outside the project")) }
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
        guard size <= maxFileSize else { return (nil, size, String(localized: "Too large to show here")) }
        guard let data = try? Data(contentsOf: url) else { return (nil, size, String(localized: "Can't read this file")) }
        guard !data.prefix(8_192).contains(0), let text = String(data: data, encoding: .utf8) else { return (nil, size, String(localized: "Not a text file")) }
        return (text, size, nil)
    }
}

extension RemoteMessage {
    public typealias DirectoryResult = (entries: [RemoteFileEntry], error: String?)
}

/// Files to and from a project, a piece at a time (frames stay well under `RemoteFrame.maxPayload`).
public enum RemoteTransfer {
    public static let chunkSize = 1 << 20
    public static let maxFileSize = 2 << 30

    /// The piece of `relative` at `offset`, and the file's size.
    public static func read(_ relative: String, in root: String, offset: Int) -> (data: Data, total: Int, error: String?) {
        guard let url = RemoteFiles.resolve(relative, in: root) else { return (Data(), 0, String(localized: "Outside the project")) }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values?.isDirectory != true else { return (Data(), 0, String(localized: "That's a folder")) }
        let total = values?.fileSize ?? 0
        guard total <= maxFileSize else { return (Data(), total, String(localized: "Too large to send")) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), total, String(localized: "Can't read this file")) }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return (try handle.read(upToCount: chunkSize) ?? Data(), total, nil)
        } catch {
            return (Data(), total, String(localized: "Can't read this file"))
        }
    }

    /// A free name in `folder`: "report.pdf", then "report 2.pdf", "report 3.pdf"…
    public static func freeName(_ name: String, in folder: URL) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appending(path: candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            n += 1
        }
        return candidate
    }

    /// Uploads in progress on the host: pieces go to a hidden file next to the destination.
    public final class Receiver: @unchecked Sendable {
        struct Pending { var temp: URL; var folder: URL; var received: Int }
        private var pending: [String: Pending] = [:]
        private let lock = NSLock()

        public init() {}

        /// Writes one piece; returns bytes in so far, and the saved file's path (relative to `root`)
        /// after the last one.
        public func receive(root: String, folder relative: String, name: String, offset: Int, total: Int, data: Data) -> (received: Int, path: String?, error: String?) {
            let safe = RemoteUpload.safeName(name)
            guard total <= RemoteTransfer.maxFileSize else { return (0, nil, String(localized: "Too large to send")) }
            guard let folder = RemoteFiles.resolve(relative, in: root) else { return (0, nil, String(localized: "Outside the project")) }
            let key = folder.path + "/" + safe
            lock.lock()
            defer { lock.unlock() }
            if offset == 0 {
                if let old = pending[key] { try? FileManager.default.removeItem(at: old.temp) }
                let temp = folder.appending(path: ".\(safe).\(UUID().uuidString.prefix(8)).part")
                guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
                    return (0, nil, String(localized: "Can't write in this folder"))
                }
                pending[key] = Pending(temp: temp, folder: folder, received: 0)
            }
            guard var item = pending[key], item.received == offset else {
                return (pending[key]?.received ?? 0, nil, String(localized: "The upload was interrupted; try again"))
            }
            do {
                let handle = try FileHandle(forWritingTo: item.temp)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                pending[key] = nil
                try? FileManager.default.removeItem(at: item.temp)
                return (0, nil, String(localized: "Can't write in this folder"))
            }
            item.received += data.count
            guard item.received >= total else {
                pending[key] = item
                return (item.received, nil, nil)
            }
            pending[key] = nil
            let final = RemoteTransfer.freeName(safe, in: item.folder)
            do {
                try FileManager.default.moveItem(at: item.temp, to: item.folder.appending(path: final))
            } catch {
                try? FileManager.default.removeItem(at: item.temp)
                return (item.received, nil, String(localized: "Can't write in this folder"))
            }
            let path = relative.isEmpty ? final : relative + "/" + final
            return (item.received, path, nil)
        }
    }
}
