import Foundation

/// One entry of the project file browser.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public var url: URL
    public var isDirectory: Bool
    /// Matched by `.gitignore` (or, outside a repository, one of `FileListing.ignoredNames`).
    public var isIgnored: Bool
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    /// Dot-file hidden by default (except a few useful ones).
    public var isHidden: Bool { name.hasPrefix(".") && !FileListing.alwaysShownDotNames.contains(name) }

    public init(url: URL, isDirectory: Bool, isIgnored: Bool = false) {
        self.url = url
        self.isDirectory = isDirectory
        self.isIgnored = isIgnored
    }
}

public enum FileListing {
    /// Noise that is never useful to browse (still reachable in Finder). Treated as ignored:
    /// hidden unless ignored files are shown. Outside a repository this is the only ignore list.
    public static let ignoredNames: Set<String> = [
        ".git", "node_modules", ".build", ".swiftpm", "DerivedData", ".DS_Store",
        ".next", ".turbo", "Pods", "__pycache__", ".venv", ".gradle",
    ]
    /// Never listed, even with ignored files shown.
    public static let neverShownNames: Set<String> = [".git", ".DS_Store"]
    static let alwaysShownDotNames: Set<String> = [".claude", ".github"]

    /// Directory contents: folders first, then files, case-insensitive by name.
    /// `gitIgnored` are names in `dir` that git ignores (see `Git.ignoredNames`).
    public static func children(of dir: URL, showHidden: Bool = false, showIgnored: Bool = false,
                                gitIgnored: Set<String> = []) -> [FileEntry] {
        visible(allChildren(of: dir, gitIgnored: gitIgnored), showHidden: showHidden, showIgnored: showIgnored)
    }

    /// Every child (minus `neverShownNames`), with ignored ones marked; filter with `visible`.
    public static func allChildren(of dir: URL, gitIgnored: Set<String> = []) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: []
        )) ?? []
        return urls.compactMap { url -> FileEntry? in
            let name = url.lastPathComponent
            if neverShownNames.contains(name) { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            // App bundles and other packages behave like files.
            let isDir = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            return FileEntry(url: url, isDirectory: isDir,
                             isIgnored: ignoredNames.contains(name) || gitIgnored.contains(name))
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func visible(_ entries: [FileEntry], showHidden: Bool, showIgnored: Bool) -> [FileEntry] {
        entries.filter { (showIgnored || !$0.isIgnored) && (showHidden || !$0.isHidden) }
    }

    /// Path of `url` relative to `root` ("src/app.ts"), or the full path when outside.
    public static func relativePath(of url: URL, in root: URL) -> String {
        let r = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(r + "/") else { return p }
        return String(p.dropFirst(r.count + 1))
    }

    // MARK: - File operations

    /// Finder-style copy name: "a.txt" → "a copy.txt", then "a copy 2.txt", … (first that doesn't exist).
    public static func availableCopyURL(for name: String, in dir: URL,
                                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let direct = dir.appending(path: name)
        if !exists(direct) { return direct }
        let ext = (name as NSString).pathExtension
        var base = ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".")
            ? name : (name as NSString).deletingPathExtension
        let suffix = base == name ? "" : "." + ext
        // "a copy" / "a copy 3" → continue numbering from the root name.
        if let range = base.range(of: #" copy( \d+)?$"#, options: .regularExpression) { base.removeSubrange(range) }
        for n in 1... {
            let candidate = dir.appending(path: base + (n == 1 ? " copy" : " copy \(n)") + suffix)
            if !exists(candidate) { return candidate }
        }
        return direct
    }

    /// Directories (below `dir`) that must exist for the relative path `name` ("a/b/c.swift" → a, a/b).
    public static func intermediateDirectories(of name: String, in dir: URL) -> [URL] {
        let parts = name.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return [] }
        var url = dir
        return parts.dropLast().map { url = url.appending(path: $0); return url }
    }

    /// True if `url` is `ancestor` or inside it (a folder can't be moved into itself).
    public static func isSameOrDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let a = ancestor.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p == a || p.hasPrefix(a + "/")
    }

    // MARK: - Walking

    /// Heavy directories skipped by the fallback walk (no git).
    public static let vendorNames: Set<String> = ignoredNames.union(["vendor", "target", "dist", "build", ".cache", ".idea"])

    /// Relative paths of files under `root` (bounded; skips hidden/vendor directories). Fallback
    /// for Quick Open when the folder isn't a git repository.
    public static func walk(_ root: URL, limit: Int = 20_000) -> [String] {
        var result: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return [] }
        let rootPath = root.standardizedFileURL.path
        while let url = e.nextObject() as? URL {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, values?.isPackage != true {
                if vendorNames.contains(name) || (name.hasPrefix(".") && !alwaysShownDotNames.contains(name)) { e.skipDescendants() }
                continue
            }
            if neverShownNames.contains(name) { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            result.append(String(path.dropFirst(rootPath.count + 1)))
            if result.count >= limit { break }
        }
        return result
    }
}
