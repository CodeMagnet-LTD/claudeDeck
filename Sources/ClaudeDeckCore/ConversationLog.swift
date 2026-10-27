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
    /// AskUserQuestion: what Claude asked, and once answered, the answers by question text.
    public var questions: [ChatQuestion]?
    public var answers: [String: String]?

    public init(id: String, kind: Kind, text: String, toolName: String? = nil, result: String? = nil, isError: Bool = false, date: Date? = nil,
                questions: [ChatQuestion]? = nil, answers: [String: String]? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.result = result
        self.isError = isError
        self.date = date
        self.questions = questions
        self.answers = answers
    }
}

/// One question of an AskUserQuestion call (the terminal shows each as a tab).
public struct ChatQuestion: Codable, Sendable, Equatable {
    public struct Option: Codable, Sendable, Equatable {
        public var label: String
        public var description: String?
        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public var header: String?
    public var question: String
    public var multiSelect: Bool
    public var options: [Option]

    public init(header: String? = nil, question: String, multiSelect: Bool = false, options: [Option]) {
        self.header = header
        self.question = question
        self.multiSelect = multiSelect
        self.options = options
    }

    static func parse(_ input: [String: Any]) -> [ChatQuestion]? {
        guard let raw = input["questions"] as? [[String: Any]] else { return nil }
        let questions = raw.compactMap { q -> ChatQuestion? in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o in
                (o["label"] as? String).map { Option(label: $0, description: o["description"] as? String) }
            }
            return ChatQuestion(header: q["header"] as? String, question: text, multiSelect: q["multiSelect"] as? Bool ?? false, options: options)
        }
        return questions.isEmpty ? nil : questions
    }
}

/// The phone's answer to one question: chosen option indexes, or (single choice) its own text.
public struct QuestionAnswer: Codable, Sendable, Equatable {
    public var options: [Int]
    public var text: String?
    public init(options: [Int] = [], text: String? = nil) {
        self.options = options
        self.text = text
    }
}

/// The keys that answer an AskUserQuestion prompt in the terminal, typed one chunk at a time with
/// a short pause (sent at once, the prompt drops some). Verified against Claude Code 2.1:
/// - one single-choice question: its number answers it;
/// - otherwise each question is a tab, then a Submit tab: a single choice's number answers and
///   moves on; a multiple choice's numbers toggle and Tab moves on; "1" on Submit sends.
/// - own text: the number of "Type something", the text, Return (it moves on too).
public enum QuestionKeys {
    public static func keys(for questions: [ChatQuestion], answers: [QuestionAnswer]) -> [String]? {
        guard !questions.isEmpty, answers.count == questions.count else { return nil }
        let tabbed = questions.count > 1 || questions.contains(where: \.multiSelect)
        var keys: [String] = []
        for (question, answer) in zip(questions, answers) {
            let count = question.options.count
            // The prompt numbers options 1-9; "Type something" comes right after them.
            guard count > 0, count < 9, answer.options.allSatisfy({ (0..<count).contains($0) }) else { return nil }
            if question.multiSelect {
                guard !answer.options.isEmpty, answer.text == nil else { return nil }
                keys += Set(answer.options).sorted().map { String($0 + 1) }
                keys.append("\t")
            } else if let text = answer.text {
                let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                guard answer.options.isEmpty, !line.isEmpty else { return nil }
                keys += [String(count + 1), line, "\r"]
            } else {
                guard answer.options.count == 1 else { return nil }
                keys.append(String(answer.options[0] + 1))
            }
        }
        if tabbed { keys.append("1") }
        return keys
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
                            if entries[at].questions != nil {
                                entries[at].answers = (object["toolUseResult"] as? [String: Any])?["answers"] as? [String: String]
                            }
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
                        let input = block["input"] as? [String: Any] ?? [:]
                        entries.append(ChatEntry(id: id, kind: .tool, text: summary(tool: name, input: input), toolName: name, date: date,
                                                 questions: name == "AskUserQuestion" ? ChatQuestion.parse(input) : nil))
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
        // A file sent from the phone (RemoteController saves them under ClaudeDeckUploads/): just its name.
        let shown = text.replacingOccurrences(of: #"@\S*/ClaudeDeckUploads/[0-9]+-[0-9A-F]{4}/(\S+)"#, with: "📎 $1", options: .regularExpression)
        return ChatEntry(id: id, kind: .user, text: String(shown.prefix(maxText)), date: date)
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
        case "AskUserQuestion": ChatQuestion.parse(input)?.first?.question
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
