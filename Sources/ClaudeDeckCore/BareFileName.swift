import Foundation

/// A file name ⌘-clicked in terminal output that SwiftTerm didn't detect as a link, like the
/// `promo.mp4` in Claude's `[file] promo.mp4 (10.7MB)`. It is found through the session's
/// transcript (where tools recorded the absolute path) or a search of the session folder.
public enum BareFileName {
    /// The file-name-like token around `column` in a row of terminal cells (one string per cell;
    /// the cell after a wide character is ""). Surrounding quotes, brackets and trailing
    /// punctuation are dropped. Nil unless the token has a slash or a dotted extension.
    public static func token(inCells cells: [String], column: Int) -> String? {
        guard cells.indices.contains(column) else { return nil }
        func isPart(_ cell: String) -> Bool {
            cell.isEmpty || !cell.allSatisfy { $0.isWhitespace || $0 == "\0" }
        }
        var col = column
        while col > 0, cells[col].isEmpty { col -= 1 }   // wide character's second cell
        guard isPart(cells[col]), !cells[col].isEmpty else { return nil }
        var start = col, end = col
        while start > 0, isPart(cells[start - 1]) { start -= 1 }
        while end + 1 < cells.count, isPart(cells[end + 1]) { end += 1 }
        return fileName(from: cells[start...end].joined())
    }

    /// `word` without wrapping punctuation, if it looks like a file name or path.
    public static func fileName(from word: String) -> String? {
        let leading: Set<Character> = ["\"", "'", "`", "(", "[", "{", "<", "‘", "“"]
        let trailing: Set<Character> = ["\"", "'", "`", ")", "]", "}", ">", ".", ",", ";", ":", "!", "?", "’", "”", "…"]
        var text = Substring(word)
        while let first = text.first, leading.contains(first) { text = text.dropFirst() }
        while let last = text.last, trailing.contains(last) { text = text.dropLast() }
        let name = String(text)
        guard !name.isEmpty, !name.contains("://") else { return nil }
        if name.contains("/") { return name.allSatisfy({ $0 == "/" || $0 == "." || $0 == "~" }) ? nil : name }
        // A dotted extension after at least one character, optionally followed by :line[:col].
        let hasExtension = name.range(of: #"^[^.].*\.[A-Za-z0-9]+(:[0-9]+){0,2}$"#, options: .regularExpression) != nil
        return hasExtension ? name : nil
    }

    /// Absolute paths ending in `/name` that appear in transcript JSONL `text`, most recent (last)
    /// occurrence first, without duplicates. Paths are taken from JSON strings (tool inputs like
    /// `file_path` or `files`, and paths quoted in output) or whitespace-delimited text.
    public static func transcriptPaths(named name: String, in text: String) -> [String] {
        guard !name.isEmpty else { return [] }
        let suffix = name.hasPrefix("/") ? name : "/" + name
        let terminators: Set<Character> = ["\"", "'", "`", "\\", ")", "]", ",", ";", ":", "<", ">"]
        var found: [String] = []
        var seen = Set<String>()
        var searchEnd = text.endIndex
        while let range = text.range(of: suffix, options: .backwards, range: text.startIndex..<searchEnd) {
            searchEnd = range.lowerBound
            if range.upperBound < text.endIndex {
                let next = text[range.upperBound]
                guard next.isWhitespace || terminators.contains(next) || next == "." else { continue }
                // "name.ext.bak" is another file; a sentence-ending "." is not.
                if next == ".", text.index(after: range.upperBound) < text.endIndex,
                   !text[text.index(after: range.upperBound)].isWhitespace { continue }
            }
            for path in pathCandidates(endingAt: range.upperBound, in: text) where seen.insert(path).inserted {
                found.append(path)
            }
        }
        return found
    }

    /// Possible absolute paths ending at `end`: the text back to the enclosing JSON quote,
    /// starting at each "/" that begins a word (so paths with spaces are included).
    private static func pathCandidates(endingAt end: String.Index, in text: String) -> [String] {
        var start = end
        let limit = text.index(end, offsetBy: -4096, limitedBy: text.startIndex) ?? text.startIndex
        while start > limit {
            let prev = text.index(before: start)
            let ch = text[prev]
            if ch == "\n" || ch == "\r" { break }
            if ch == "\"" {
                // Unescaped quote: the start of the JSON string.
                var slashes = 0
                var i = prev
                while i > text.startIndex, text[text.index(before: i)] == "\\" { slashes += 1; i = text.index(before: i) }
                if slashes % 2 == 0 { break }
            }
            start = prev
        }
        let raw = String(text[start..<end])
        var paths: [String] = []
        let chars = Array(raw)
        let boundaries: Set<Character> = [" ", "\t", "'", "`", "(", "[", "=", ">"]
        for i in chars.indices where chars[i] == "/" || (chars[i] == "~" && i + 1 < chars.count && chars[i + 1] == "/") {
            guard i == 0 || boundaries.contains(chars[i - 1]) || (chars[i - 1] == "n" && i >= 2 && chars[i - 2] == "\\") else { continue }
            guard let path = unescaped(String(chars[i...])) else { continue }
            paths.append((path as NSString).expandingTildeInPath)
        }
        return paths
    }

    private static func unescaped(_ json: String) -> String? {
        guard json.contains("\\") else { return json }
        return try? JSONDecoder().decode(String.self, from: Data("\"\(json)\"".utf8))
    }

    /// Relative paths from a folder listing that are `name` or end in `/name`.
    public static func matches(named name: String, in relativePaths: [String]) -> [String] {
        let suffix = "/" + name
        return relativePaths.filter { $0 == name || $0.hasSuffix(suffix) }
    }

    /// The most recently modified candidate; earlier candidates win ties.
    public static func newest(_ candidates: [String], modified: (String) -> Date?) -> String? {
        var best: (path: String, date: Date)?
        for path in candidates {
            guard let date = modified(path) else { continue }
            if best == nil || date > best!.date { best = (path, date) }
        }
        return best?.path
    }

    // MARK: Lookup (file system)

    /// Where a ⌘-clicked bare `name` lives: resolved against `directories` like a path, else the
    /// most recent absolute path in the transcript's tail, else the newest file with that name
    /// below the first directory that is a session folder. Blocking; call off the main actor.
    public static func locate(_ name: String, directories: [String], sessionFolder: String?,
                              transcriptPath: String?, tailBytes: Int = 4 << 20) -> URL? {
        if case .file(let url, _)? = TerminalLink.resolve(name, in: directories) { return url }
        let bare = name.replacingOccurrences(of: #":[0-9]+(:[0-9]+)?$"#, with: "", options: .regularExpression)
        let fm = FileManager.default
        func isFile(_ path: String) -> Bool {
            var dir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
        }
        if let transcriptPath, let text = tail(of: transcriptPath, bytes: tailBytes),
           let path = transcriptPaths(named: bare, in: text).first(where: isFile) {
            return URL(fileURLWithPath: path)
        }
        guard let sessionFolder, !bare.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: sessionFolder)
        let listing = Git.listFiles(in: root) ?? walk(root)
        let candidates = matches(named: bare, in: listing).map { root.appending(path: $0).path }
        let newestPath = newest(candidates) { path in
            guard isFile(path) else { return nil }
            return (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
        }
        return newestPath.map { URL(fileURLWithPath: $0) }
    }

    private static func tail(of path: String, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Relative file paths below `root` outside a git repository, skipping dependency and build
    /// folders, capped so a click on a huge folder stays quick.
    static func walk(_ root: URL, limit: Int = 50_000) -> [String] {
        let skipped: Set<String> = ["node_modules", ".build", ".git", "DerivedData", "Pods", ".next", ".venv", "venv", "__pycache__"]
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsPackageDescendants]) else { return [] }
        let base = root.standardizedFileURL.path
        var out: [String] = []
        for case let url as URL in items {
            if skipped.contains(url.lastPathComponent) { items.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            out.append(String(path.dropFirst(base.count + 1)))
            if out.count >= limit { break }
        }
        return out
    }
}

