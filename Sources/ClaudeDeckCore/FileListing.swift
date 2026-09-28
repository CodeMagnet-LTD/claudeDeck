import Foundation

/// One entry of the project file browser.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public var url: URL
    public var isDirectory: Bool
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

public enum FileListing {
    /// Noise that is never useful to browse (still reachable in Finder).
    public static let ignoredNames: Set<String> = [
        ".git", "node_modules", ".build", ".swiftpm", "DerivedData", ".DS_Store",
        ".next", ".turbo", "Pods", "__pycache__", ".venv", ".gradle",
    ]

    /// Directory contents: folders first, then files, case-insensitive by name.
    public static func children(of dir: URL, showHidden: Bool = false) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: []
        )) ?? []
        return urls.compactMap { url -> FileEntry? in
            let name = url.lastPathComponent
            if ignoredNames.contains(name) { return nil }
            if !showHidden, name.hasPrefix("."), name != ".claude", name != ".github" { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            // App bundles and other packages behave like files.
            let isDir = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            return FileEntry(url: url, isDirectory: isDir)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Path of `url` relative to `root` ("src/app.ts"), or the full path when outside.
    public static func relativePath(of url: URL, in root: URL) -> String {
        let r = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(r + "/") else { return p }
        return String(p.dropFirst(r.count + 1))
    }
}
