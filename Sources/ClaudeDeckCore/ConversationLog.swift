import Foundation

// A Claude transcript (JSONL) as a readable conversation: what the phone shows instead of a
// terminal too wide for its screen. Only the main thread of the session (no subagents), no
// thinking, tool calls as one-line summaries with a short excerpt of their result.

public struct ChatEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case user, assistant, tool, system }

    public var id: String
    public var kind: Kind
    /// User / assistant text, the tool call's summary, or the system note.
    public var text: String
    public var toolName: String?
    /// Start of the tool's result.
    public var result: String?
    public var isError: Bool
    public var date: Date?

    public init(id: String, kind: Kind, text: String, toolName: String? = nil, result: String? = nil, isError: Bool = false, date: Date? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.result = result
        self.isError = isError
        self.date = date
    }
}

/// A slice of a conversation. `before` / `after` echo the request so the phone knows where it goes.
public struct ChatPage: Codable, Sendable, Equatable {
    public var entries: [ChatEntry]
    /// Older entries exist before the first one.
    public var hasMoreBefore: Bool
    /// The page replaces what the phone has (a new transcript after /clear, or the anchor is gone).
    public var reset: Bool
    public var before: String?
    public var after: String?

    public init(entries: [ChatEntry], hasMoreBefore: Bool, reset: Bool, before: String? = nil, after: String? = nil) {
        self.entries = entries
        self.hasMoreBefore = hasMoreBefore
        self.reset = reset
        self.before = before
        self.after = after
    }
}

public enum ConversationLog {
    static let maxResult = 1_200
    static let maxText = 20_000

    /// Parses a whole transcript (the last `tailBytes` of a big one).
    public static func entries(of url: URL, tailBytes: Int = 16 << 20) -> [ChatEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return [] }
        // Started mid-line: drop the partial first line.
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        return entries(fromJSONL: String(decoding: data, as: UTF8.self))
    }

    public static func entries(fromJSONL text: String) -> [ChatEntry] {
        var entries: [ChatEntry] = []
        var toolIndex: [String: Int] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = object["type"] as? String
            guard type == "user" || type == "assistant" else { continue }
            if object["isSidechain"] as? Bool == true { continue }
            let uuid = object["uuid"] as? String ?? UUID().uuidString
            let date = (object["timestamp"] as? String).flatMap { iso.date(from: $0) }
            let message = object["message"] as? [String: Any] ?? [:]

            if object["isCompactSummary"] as? Bool == true {
                entries.append(ChatEntry(id: uuid, kind: .system, text: String(localized: "Conversation compacted"), date: date))
                continue
            }
            if type == "user" {
                if object["isMeta"] as? Bool == true { continue }
                if let content = message["content"] as? String {
                    if let entry = userEntry(content, id: uuid, date: date) { entries.append(entry) }
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for (index, block) in blocks.enumerated() {
                        switch block["type"] as? String {
                        case "text":
                            if let text = block["text"] as? String, let entry = userEntry(text, id: "\(uuid)#\(index)", date: date) { entries.append(entry) }
                        case "tool_result":
                            guard let toolID = block["tool_use_id"] as? String, let at = toolIndex[toolID] else { continue }
                            entries[at].result = resultText(block["content"])
                            entries[at].isError = block["is_error"] as? Bool ?? false
                        default:
                            break
                        }
                    }
                }
            } else if let blocks = message["content"] as? [[String: Any]] {
                for (index, block) in blocks.enumerated() {
                    switch block["type"] as? String {
                    case "text":
                        let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        entries.append(ChatEntry(id: "\(uuid)#\(index)", kind: .assistant, text: String(text.prefix(maxText)), date: date))
                    case "tool_use":
                        let name = block["name"] as? String ?? "Tool"
                        let id = block["id"] as? String ?? "\(uuid)#\(index)"
                        toolIndex[id] = entries.count
                        entries.append(ChatEntry(id: id, kind: .tool, text: summary(tool: name, input: block["input"] as? [String: Any] ?? [:]), toolName: name, date: date))
                    default:
                        break // thinking, server tools
                    }
                }
            }
        }
        return entries
    }

    /// A user line, or nil for the CLI's own bookkeeping (command echoes, caveats, reminders).
    static func userEntry(_ raw: String, id: String, date: Date?) -> ChatEntry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("[Request interrupted by user") {
            return ChatEntry(id: id, kind: .system, text: String(localized: "Interrupted"), date: date)
        }
        if let command = tag("command-name", in: text) {
            let args = tag("command-args", in: text).map { $0.isEmpty ? "" : " " + $0 } ?? ""
            return ChatEntry(id: id, kind: .system, text: command + args, date: date)
        }
        if text.hasPrefix("<task-notification>") {
            let summary = tag("summary", in: text) ?? tag("status", in: text)
            return ChatEntry(id: id, kind: .system, text: String(localized: "Background task finished") + (summary.map { ": \($0)" } ?? ""), date: date)
        }
        // The CLI's own tagged messages (command output, reminders, hook notes…), not the user's words.
        if text.hasPrefix("Caveat:") || isTagBlock(text) { return nil }
        return ChatEntry(id: id, kind: .user, text: String(text.prefix(maxText)), date: date)
    }

    /// `<name …>…</name>` from start to end.
    static func isTagBlock(_ text: String) -> Bool {
        guard text.hasPrefix("<"), let close = text.firstIndex(where: { $0 == ">" || $0 == " " }) else { return false }
        let name = text[text.index(after: text.startIndex)..<close]
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return false }
        return text.hasSuffix("</\(name)>")
    }

    static func tag(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"), let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resultText(_ content: Any?) -> String? {
        var text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > maxResult ? String(text.prefix(maxResult)) + "…" : text
    }

    /// "git status", "Views.swift", the pattern… — what the tool call was about, in one line.
    public static func summary(tool: String, input: [String: Any]) -> String {
        func string(_ key: String) -> String? {
            (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        func file(_ path: String) -> String {
            let parts = path.split(separator: "/")
            return parts.suffix(2).joined(separator: "/")
        }
        let value: String? = switch tool {
        case "Bash": string("description").map { d in string("command").map { "\(d) — \($0)" } ?? d } ?? string("command")
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit": string("file_path").map(file) ?? string("notebook_path").map(file)
        case "Grep", "Glob": string("pattern")
        case "WebFetch": string("url")
        case "WebSearch": string("query")
        case "Agent", "Task": string("description")
        case "TodoWrite": (input["todos"] as? [Any]).map { "\($0.count)" }
        default: input.values.lazy.compactMap { ($0 as? String)?.nilIfEmpty }.first
        }
        let line = (value ?? "").split(separator: "\n").first.map(String.init) ?? ""
        return String(line.prefix(200))
    }

    /// The page for a request (see `ChatPage`).
    public static func page(_ entries: [ChatEntry], before: String?, after: String?, limit: Int) -> ChatPage {
        let limit = max(1, min(limit, 200))
        if let after {
            if let index = entries.firstIndex(where: { $0.id == after }) {
                let newer = Array(entries[(index + 1)...])
                // Far behind: start over with the latest page rather than a huge append.
                if newer.count <= limit { return ChatPage(entries: newer, hasMoreBefore: true, reset: false, after: after) }
            }
            let tail = Array(entries.suffix(limit))
            return ChatPage(entries: tail, hasMoreBefore: entries.count > tail.count, reset: true)
        }
        if let before, let index = entries.firstIndex(where: { $0.id == before }) {
            let start = max(0, index - limit)
            return ChatPage(entries: Array(entries[start..<index]), hasMoreBefore: start > 0, reset: false, before: before)
        }
        let tail = Array(entries.suffix(limit))
        return ChatPage(entries: tail, hasMoreBefore: entries.count > tail.count, reset: true)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
