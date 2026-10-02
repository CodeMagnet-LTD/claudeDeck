import Foundation

/// One matching message excerpt. `matchRange` is in `Character` offsets into `text`.
public struct HistorySnippet: Sendable, Equatable {
    public var text: String
    public var matchStart: Int
    public var matchLength: Int
    public var role: String
    public var date: Date?

    public init(text: String, matchStart: Int, matchLength: Int, role: String, date: Date?) {
        self.text = text
        self.matchStart = matchStart
        self.matchLength = matchLength
        self.role = role
        self.date = date
    }
}

/// A conversation (one `~/.claude/projects/<dir>/<id>.jsonl`) with matches.
public struct HistorySearchResult: Identifiable, Sendable, Equatable {
    /// The Claude session id (`--resume <id>`).
    public var id: String
    public var file: URL
    /// The `~/.claude/projects` directory name.
    public var projectDirectory: String
    /// The working directory recorded in the conversation (worktree sessions: the worktree).
    public var cwd: String?
    public var title: String
    public var modifiedAt: Date
    public var snippets: [HistorySnippet]
    public var matchCount: Int
}

/// Full-text search over Claude Code transcripts (user and assistant text only; tool payloads,
/// thinking and attachments are skipped). Streams the files chunk by chunk with bounded memory:
/// a cheap byte-level prefilter picks the lines worth JSON-parsing.
public enum HistorySearch {
    public static let maxResults = 200
    public static let snippetsPerConversation = 3

    // MARK: Files

    /// The transcripts to search, newest first. `projectPath` limits it to that project and its
    /// `.claude/worktrees/*` worktrees; nil = all projects.
    public static func files(root: URL = TranscriptIndex.defaultRoot(), projectPath: String?) -> [URL] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let wanted = projectPath.map(Transcript.projectDirectoryName(for:))
        var entries: [(URL, Date)] = []
        for dir in dirs where isInScope(dir.lastPathComponent, projectDirectory: wanted) {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { continue }
                entries.append((file, values.contentModificationDate ?? .distantPast))
            }
        }
        return entries.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// `-a-b` covers `-a-b` and its worktrees (`-a-b--claude-worktrees-x`), not `-a-b-c`.
    static func isInScope(_ directory: String, projectDirectory: String?) -> Bool {
        guard let projectDirectory else { return true }
        return directory == projectDirectory || directory.hasPrefix(projectDirectory + "--claude-worktrees-")
    }

    // MARK: Search

    /// Searches `files` in order, calling `onResult` per matching conversation, until done,
    /// cancelled or `maxResults` conversations were found.
    public static func search(
        _ query: String, in files: [URL], maxResults: Int = maxResults,
        shouldCancel: () -> Bool = { false }, onResult: (HistorySearchResult) -> Void
    ) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let matcher = Matcher(query: query)
        var found = 0
        for file in files {
            if shouldCancel() || found >= maxResults { return }
            if let result = search(file: file, matcher: matcher, shouldCancel: shouldCancel) {
                onResult(result)
                found += 1
            }
        }
    }

    /// Async wrapper: results stream in; cancelling the consuming task stops the scan.
    public static func stream(_ query: String, in files: [URL], maxResults: Int = maxResults) -> AsyncStream<HistorySearchResult> {
        AsyncStream { continuation in
            let task = Task.detached {
                search(query, in: files, maxResults: maxResults, shouldCancel: { Task.isCancelled }) {
                    continuation.yield($0)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let chunkSize = 4 << 20
    /// A line longer than this is never user/assistant text worth showing (pasted images, huge
    /// tool results): skipped without buffering it.
    static let maxLineBytes = 8 << 20

    static func search(file: URL, matcher: Matcher, shouldCancel: () -> Bool) -> HistorySearchResult? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var carry = Data()
        var skippingLongLine = false
        var snippets: [HistorySnippet] = []
        var count = 0
        var cwd: String?

        func handle(line: Data) {
            guard let hit = matcher.match(line: line) else { return }
            count += hit.count
            if cwd == nil { cwd = hit.cwd }
            if snippets.count < snippetsPerConversation { snippets.append(hit.snippet) }
        }

        while true {
            if shouldCancel() { return nil }
            let chunk: Data
            do { chunk = try handle.read(upToCount: chunkSize) ?? Data() } catch { return nil }
            if chunk.isEmpty { break }
            var data = chunk
            if skippingLongLine {
                guard let nl = data.firstIndex(of: 0x0A) else { continue }
                data = data[(nl + 1)...]
                skippingLongLine = false
            }
            guard let lastNL = data.lastIndex(of: 0x0A) else {
                carry.append(data)
                if carry.count > maxLineBytes { carry = Data(); skippingLongLine = true }
                continue
            }
            var block = carry
            block.append(data[data.startIndex..<lastNL])
            carry = Data(data[(lastNL + 1)...])
            matcher.scan(block, onLine: handle(line:))
        }
        if !carry.isEmpty, !skippingLongLine { matcher.scan(carry, onLine: handle(line:)) }
        guard count > 0 else { return nil }
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        return HistorySearchResult(
            id: file.deletingPathExtension().lastPathComponent,
            file: file,
            projectDirectory: file.deletingLastPathComponent().lastPathComponent,
            cwd: cwd,
            title: TranscriptIndex.title(of: file) ?? String(localized: "Untitled session"),
            modifiedAt: values?.contentModificationDate ?? .distantPast,
            snippets: snippets,
            matchCount: count
        )
    }

    // MARK: Matching

    struct Hit {
        var count: Int
        var snippet: HistorySnippet
        var cwd: String?
    }

    struct Matcher {
        let query: String
        /// Lowercased ASCII bytes every matching line must contain (raw JSON, ASCII-lowercased).
        let needle: [UInt8]
        let hasNeedle: Bool

        init(query: String) {
            self.query = query
            let run = Self.prefilterRun(of: query)
            needle = Array(run.utf8)
            hasNeedle = !run.isEmpty
        }

        /// The longest piece of the query that appears byte-for-byte (modulo ASCII case) in the
        /// JSON-encoded text: ASCII letters, digits and punctuation that JSON never escapes.
        static func prefilterRun(of query: String) -> String {
            var best = "", current = ""
            for scalar in query.unicodeScalars {
                let v = scalar.value
                if v >= 0x20, v < 0x7F, scalar != "\"", scalar != "\\", scalar != "/" {
                    current.unicodeScalars.append(scalar)
                } else {
                    if current.count > best.count { best = current }
                    current = ""
                }
            }
            if current.count > best.count { best = current }
            return best.lowercased()
        }

        /// Calls `onLine` for each line of `block` that may match.
        func scan(_ block: Data, onLine: (Data) -> Void) {
            guard !block.isEmpty else { return }
            if !hasNeedle {
                // No usable byte needle (e.g. only non-ASCII letters): every message line is a candidate.
                var start = block.startIndex
                while start < block.endIndex {
                    let end = block[start...].firstIndex(of: 0x0A) ?? block.endIndex
                    if end > start { onLine(block[start..<end]) }
                    start = end + 1
                }
                return
            }
            var lowered = [UInt8](block)
            for i in lowered.indices where lowered[i] >= 0x41 && lowered[i] <= 0x5A { lowered[i] |= 0x20 }
            lowered.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    guard let found = memmem(base + offset, buffer.count - offset, needle, needle.count) else { return }
                    let hit = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                    var lineStart = hit
                    while lineStart > 0, buffer[lineStart - 1] != 0x0A { lineStart -= 1 }
                    var lineEnd = hit
                    while lineEnd < buffer.count, buffer[lineEnd] != 0x0A { lineEnd += 1 }
                    let s = block.startIndex + lineStart, e = block.startIndex + lineEnd
                    onLine(block[s..<e])
                    offset = lineEnd + 1
                }
            }
        }

        /// The line's user/assistant text, if it contains the query.
        func match(line: Data) -> Hit? {
            guard line.count <= HistorySearch.maxLineBytes,
                  let message = HistorySearch.message(fromLine: line) else { return nil }
            let text = message.text
            var count = 0
            var first: Range<String.Index>?
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: query, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
                if first == nil { first = range }
                count += 1
                searchStart = range.upperBound
            }
            guard let first else { return nil }
            return Hit(count: count, snippet: HistorySearch.snippet(text, match: first, role: message.role, date: message.date),
                       cwd: message.cwd)
        }
    }

    struct Message {
        var role: String
        var text: String
        var date: Date?
        var cwd: String?
    }

    /// The searchable text of a transcript line: user prompts and assistant replies only.
    static func message(fromLine line: Data) -> Message? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String, type == "user" || type == "assistant",
              obj["isMeta"] as? Bool != true, obj["isSidechain"] as? Bool != true,
              let message = obj["message"] as? [String: Any] else { return nil }
        var parts: [String] = []
        if let s = message["content"] as? String {
            parts = [s]
        } else if let blocks = message["content"] as? [[String: Any]] {
            parts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
        let text = parts.joined(separator: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if type == "user", noisePrefixes.contains(where: trimmed.hasPrefix) { return nil }
        let date = (obj["timestamp"] as? String).flatMap(Transcript.parseDate)
        return Message(role: type, text: text, date: date, cwd: obj["cwd"] as? String)
    }

    /// Slash-command echoes and injected context, not something the user typed.
    static let noisePrefixes = ["<command-", "<local-command-", "<system-reminder>", "[Request interrupted"]

    /// ~60 characters before and ~140 after the match, whitespace collapsed.
    static func snippet(_ text: String, match: Range<String.Index>, role: String, date: Date?,
                        before: Int = 60, after: Int = 140) -> HistorySnippet {
        let start = text.index(match.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        let head = collapse(text[start..<match.lowerBound])
        let hit = collapse(text[match])
        let tail = collapse(text[match.upperBound..<end])
        let prefix = (start > text.startIndex ? "…" : "") + head.drop(while: \.isWhitespace)
        let suffix = String(tail.reversed().drop(while: \.isWhitespace).reversed()) + (end < text.endIndex ? "…" : "")
        return HistorySnippet(text: prefix + hit + suffix, matchStart: prefix.count, matchLength: hit.count, role: role, date: date)
    }

    private static func collapse(_ s: Substring) -> String {
        var out = ""
        var lastWasSpace = false
        for c in s {
            if c.isWhitespace || c.isNewline {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(c)
                lastWasSpace = false
            }
        }
        return out
    }
}
