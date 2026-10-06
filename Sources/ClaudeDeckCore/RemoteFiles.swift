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
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return ([], String(localized: "Can't read this folder"))
        }
        let entries = items.compactMap { item -> RemoteFileEntry? in
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
