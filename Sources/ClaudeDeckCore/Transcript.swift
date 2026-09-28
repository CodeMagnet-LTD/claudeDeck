import Foundation

/// Reads Claude Code transcripts (`~/.claude/projects/<encoded-cwd>/<session>.jsonl`).
public enum Transcript {
    /// Parses one JSONL line and returns a signal if it records an interruption / denial.
    public static func signal(fromLine line: Substring) -> TranscriptSignal? {
        guard line.contains("[Request interrupted by user"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "user",
              let message = object["message"] as? [String: Any]
        else { return nil }

        let texts: [String]
        if let content = message["content"] as? String {
            texts = [content]
        } else if let blocks = message["content"] as? [[String: Any]] {
            texts = blocks.compactMap { $0["text"] as? String }
        } else {
            texts = []
        }
        guard let text = texts.first(where: { $0.hasPrefix("[Request interrupted by user") }) else { return nil }
        let at = (object["timestamp"] as? String).flatMap(parseDate) ?? Date()
        return TranscriptSignal(kind: text.contains("for tool use") ? .toolDenied : .interrupted, at: at)
    }

    /// Returns the last signal found in a chunk of complete lines.
    public static func lastSignal(in chunk: String) -> TranscriptSignal? {
        chunk.split(separator: "\n").reversed().lazy.compactMap(signal(fromLine:)).first
    }

    static func parseDate(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    /// Claude Code's directory name for a project path: every non-alphanumeric character becomes "-".
    public static func projectDirectoryName(for path: String) -> String {
        String(path.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "-"
        })
    }
}

/// A previous Claude conversation that can be continued with `claude --resume <id>`.
public struct ResumableSession: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var modifiedAt: Date
    public var size: Int

    public init(id: String, title: String, modifiedAt: Date, size: Int) {
        self.id = id
        self.title = title
        self.modifiedAt = modifiedAt
        self.size = size
    }
}

public enum TranscriptIndex {
    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".claude/projects")
    }

    /// Lists resumable conversations for a project, newest first.
    public static func sessions(forProject path: String, root: URL = defaultRoot(), limit: Int = 50) -> [ResumableSession] {
        let dir = root.appending(path: Transcript.projectDirectoryName(for: path))
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return [] }
        let entries: [(URL, Date, Int)] = files.compactMap { url in
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        return entries
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .compactMap { url, date, size in
                guard size > 0 else { return nil }
                let title = title(of: url) ?? "Adsız oturum"
                return ResumableSession(id: url.deletingPathExtension().lastPathComponent, title: title, modifiedAt: date, size: size)
            }
    }

    /// Custom title if set, else the first real user prompt. Reads only the head of the file.
    static func title(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        var firstPrompt: String?
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "custom-title", let t = obj["customTitle"] as? String, !t.isEmpty { return t }
            if type == "summary", let s = obj["summary"] as? String, !s.isEmpty { return s }
            if firstPrompt == nil, type == "user", obj["isMeta"] as? Bool != true,
               let message = obj["message"] as? [String: Any] {
                let candidate: String? = (message["content"] as? String)
                    ?? (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.first
                if let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !c.isEmpty, !c.hasPrefix("<"), !c.hasPrefix("[Request interrupted") {
                    firstPrompt = String(c.prefix(120))
                }
            }
        }
        return firstPrompt
    }
}
