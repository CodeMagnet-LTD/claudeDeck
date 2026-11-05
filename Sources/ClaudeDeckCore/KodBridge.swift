import Foundation

// Kod checker bridge: the JSON ClaudeDeck posts when a session finishes a turn or is waiting,
// the loopback API kod checker calls back on, and the side record that labels those messages.
// The listener, Keychain and UI live in the app. Nothing here talks to the network except
// `KodWebhook.deliver`, which the app fires off the UI path.

public enum KodBridge {
    public static let defaultPort = 47647
    public static let maxReplyCharacters = 8_000
    public static let maxPromptCharacters = 4_000
    public static let maxDetailCharacters = 2_000
    public static let testEvent = "bridge.test"
    public static let assistantName = ChatEntry.kodCheckerSource

    public static func eventName(for activity: SessionActivity) -> String? {
        switch activity {
        case .idle: "session.idle"
        case .needsPermission: "session.needs_permission"
        case .needsAnswer: "session.needs_answer"
        case .running, .ended: nil
        }
    }

    /// Claude's turn is over (your turn), as opposed to a permission or question still on screen.
    public static func finished(_ activity: SessionActivity) -> Bool { activity == .idle }

    /// A permission prompt or a question is waiting. Idle is a finished turn, not a blocked prompt.
    public static func waitingForInput(_ activity: SessionActivity) -> Bool { activity.isBlocked }

    public enum PortProblem: Equatable, Sendable {
        case outOfRange
        case remoteMode
    }

    public static func portProblem(_ value: Int) -> PortProblem? {
        if value == Int(RemotePairing.defaultPort) { return .remoteMode }
        if !(1024...65535).contains(value) { return .outOfRange }
        return nil
    }

    public static func sanitizedPort(_ value: Int) -> UInt16? {
        guard portProblem(value) == nil else { return nil }
        return UInt16(value)
    }

    /// http or https with a host. Anything else is not a webhook.
    public static func webhookURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              let url = components.url else { return nil }
        return url
    }

    public static func clip(_ text: String?, limit: Int) -> String? {
        guard var text else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// Last user line and last assistant line in a parsed transcript.
    public static func excerpt(from entries: [ChatEntry]) -> (prompt: String?, reply: String?) {
        let prompt = entries.last { $0.kind == .user }?.text
        let reply = entries.last { $0.kind == .assistant }?.text
        return (clip(prompt, maxPromptCharacters), clip(reply, maxReplyCharacters))
    }

    public static func limit(in query: [String: String], default defaultLimit: Int = 40) -> Int {
        let raw = query["limit"].flatMap(Int.init) ?? defaultLimit
        return min(200, max(1, raw))
    }

    public static func match(method: String, path: String) -> KodRouteMatch {
        var path = path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let parts = path.split(separator: "/").map { KodHTTP.percentDecode(String($0)) }
        guard parts.first == "v1" else { return .notFound }
        let rest = Array(parts.dropFirst())
        let method = method.uppercased()
        switch rest.count {
        case 1 where rest[0] == "health":
            return method == "GET" ? .match(.health) : .methodNotAllowed
        case 1 where rest[0] == "projects":
            return method == "GET" ? .match(.projects) : .methodNotAllowed
        case 3 where rest[0] == "sessions" && rest[2] == "messages":
            guard let id = UUID(uuidString: rest[1]) else { return .notFound }
            switch method {
            case "GET": return .match(.messages(id))
            case "POST": return .match(.sendMessage(id))
            default: return .methodNotAllowed
            }
        case 3 where rest[0] == "projects" && rest[2] == "sessions":
            guard let id = UUID(uuidString: rest[1]) else { return .notFound }
            return method == "POST" ? .match(.startSession(id)) : .methodNotAllowed
        default:
            return .notFound
        }
    }
}

public enum KodRoute: Equatable, Sendable {
    case health
    case projects
    case messages(UUID)
    case sendMessage(UUID)
    case startSession(UUID)
}

public enum KodRouteMatch: Equatable, Sendable {
    case match(KodRoute)
    case methodNotAllowed
    case notFound
}

/// `Authorization: Bearer <token>`. The scheme is case-insensitive; the token is not.
public enum KodBearer {
    public static func credential(from header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, String(parts[0]).caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : String(token)
    }

    /// Equal length and equal bytes. A different length, or an empty expected token, never matches.
    public static func matches(_ presented: String, expected: String) -> Bool {
        let left = Array(presented.utf8)
        let right = Array(expected.utf8)
        guard !right.isEmpty, left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

public enum KodJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

/// Posted to the webhook. Field names are the wire format.
public struct KodBridgeEvent: Codable, Equatable, Sendable {
    public var event: String
    public var projectName: String
    public var projectPath: String
    public var sessionID: String
    public var timestamp: Date
    public var lastUserPrompt: String?
    public var lastAssistantReply: String?
    /// True when the turn looks finished (idle). False when a permission or question is up.
    public var finished: Bool
    /// True when a permission or question is waiting. False for a finished turn.
    public var waitingForInput: Bool
    public var transcriptPath: String?
    /// Hook detail when there is one (the command, or the question).
    public var detail: String?

    public init(
        event: String, projectName: String, projectPath: String, sessionID: String, timestamp: Date,
        lastUserPrompt: String?, lastAssistantReply: String?, finished: Bool, waitingForInput: Bool,
        transcriptPath: String?, detail: String?
    ) {
        self.event = event
        self.projectName = projectName
        self.projectPath = projectPath
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.lastUserPrompt = lastUserPrompt
        self.lastAssistantReply = lastAssistantReply
        self.finished = finished
        self.waitingForInput = waitingForInput
        self.transcriptPath = transcriptPath
        self.detail = detail
    }

    /// Nil fields are JSON null, so every event has the same keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event, forKey: .event)
        try container.encode(projectName, forKey: .projectName)
        try container.encode(projectPath, forKey: .projectPath)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(finished, forKey: .finished)
        try container.encode(waitingForInput, forKey: .waitingForInput)
        try encodeOptional(lastUserPrompt, forKey: .lastUserPrompt, in: &container)
        try encodeOptional(lastAssistantReply, forKey: .lastAssistantReply, in: &container)
        try encodeOptional(transcriptPath, forKey: .transcriptPath, in: &container)
        try encodeOptional(detail, forKey: .detail, in: &container)
    }

    private func encodeOptional(_ value: String?, forKey key: CodingKeys, in container: inout KeyedEncodingContainer<CodingKeys>) throws {
        if let value { try container.encode(value, forKey: key) } else { try container.encodeNil(forKey: key) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(String.self, forKey: .event)
        projectName = try container.decode(String.self, forKey: .projectName)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        finished = try container.decode(Bool.self, forKey: .finished)
        waitingForInput = try container.decode(Bool.self, forKey: .waitingForInput)
        lastUserPrompt = try container.decodeIfPresent(String.self, forKey: .lastUserPrompt)
        lastAssistantReply = try container.decodeIfPresent(String.self, forKey: .lastAssistantReply)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }

    enum CodingKeys: String, CodingKey {
        case event
        case projectName = "project_name"
        case projectPath = "project_path"
        case sessionID = "session_id"
        case timestamp
        case lastUserPrompt = "last_user_prompt"
        case lastAssistantReply = "last_assistant_reply"
        case finished
        case waitingForInput = "waiting_for_input"
        case transcriptPath = "transcript_path"
        case detail
    }
}

public struct KodWebhookResult: Equatable, Sendable {
    public var delivered: Bool
    public var statusCode: Int?
    public var attempts: Int
    public var message: String

    public init(delivered: Bool, statusCode: Int?, attempts: Int, message: String) {
        self.delivered = delivered
        self.statusCode = statusCode
        self.attempts = attempts
        self.message = message
    }
}

public enum KodWebhook {
    public static let timeout: TimeInterval = 5
    /// First try plus two retries.
    public static let maxAttempts = 3

    public static func shouldRetry(statusCode: Int?, transportFailed: Bool) -> Bool {
        if transportFailed || statusCode == nil { return true }
        guard let statusCode else { return true }
        if (200...299).contains(statusCode) { return false }
        if statusCode == 408 || statusCode == 429 { return true }
        return statusCode >= 500
    }

    public static func makeRequest(event: KodBridgeEvent, url: URL, authorization: String?) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClaudeDeck-KodBridge", forHTTPHeaderField: "User-Agent")
        let authorization = authorization?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !authorization.isEmpty { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.httpBody = try KodJSON.encode(event)
        return request
    }

    /// Short timeout, then up to two more tries. Does not throw.
    public static func deliver(_ event: KodBridgeEvent, to url: URL, authorization: String?, session: URLSession) async -> KodWebhookResult {
        let request: URLRequest
        do {
            request = try makeRequest(event: event, url: url, authorization: authorization)
        } catch {
            return KodWebhookResult(delivered: false, statusCode: nil, attempts: 0, message: error.localizedDescription)
        }
        var lastStatus: Int?
        var lastMessage = ""
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                try? await Task.sleep(for: .milliseconds(400 * (attempt - 1)))
            }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode
                lastStatus = status
                if let status, (200...299).contains(status) {
                    return KodWebhookResult(delivered: true, statusCode: status, attempts: attempt, message: "HTTP \(status)")
                }
                let snippet = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                lastMessage = status.map { "HTTP \($0)" } ?? "No HTTP status"
                if !snippet.isEmpty { lastMessage += " \(snippet)" }
                if !shouldRetry(statusCode: status, transportFailed: false) || attempt == maxAttempts {
                    return KodWebhookResult(delivered: false, statusCode: status, attempts: attempt, message: lastMessage)
                }
            } catch {
                lastStatus = nil
                lastMessage = error.localizedDescription
                if attempt == maxAttempts {
                    return KodWebhookResult(delivered: false, statusCode: nil, attempts: attempt, message: lastMessage)
                }
            }
        }
        return KodWebhookResult(delivered: false, statusCode: lastStatus, attempts: maxAttempts, message: lastMessage)
    }
}

/// A message ClaudeDeck typed for kod checker. Matched back onto transcript user lines by text,
/// because the JSONL has no source field.
public struct KodAttribution: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var text: String
    public var at: Date

    public init(id: UUID = UUID(), sessionID: UUID, text: String, at: Date) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.at = at
    }
}

public enum KodAttributions {
    public static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func matches(entryText: String, recordedText: String) -> Bool {
        let entry = normalize(entryText)
        let recorded = normalize(recordedText)
        guard !entry.isEmpty, !recorded.isEmpty else { return false }
        if entry == recorded { return true }
        // The conversation view keeps at most `maxText` characters of a user message.
        return entry == normalize(String(recordedText.prefix(ConversationLog.maxText)))
    }

    public static func stamp(_ entries: [ChatEntry], sessionID: UUID, records: [KodAttribution]) -> [ChatEntry] {
        let texts = records.filter { $0.sessionID == sessionID }.map(\.text)
        guard !texts.isEmpty else { return entries }
        return entries.map { entry in
            guard entry.kind == .user, entry.source == nil, texts.contains(where: { matches(entryText: entry.text, recordedText: $0) }) else { return entry }
            var copy = entry
            copy.source = ChatEntry.kodCheckerSource
            return copy
        }
    }
}

public struct KodActivityEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Direction: String, Codable, Sendable { case inbound, outbound }

    public var id: UUID
    public var at: Date
    public var direction: Direction
    public var title: String
    public var detail: String
    public var ok: Bool
    public var sessionID: UUID?

    public init(id: UUID = UUID(), at: Date = Date(), direction: Direction, title: String, detail: String, ok: Bool, sessionID: UUID? = nil) {
        self.id = id
        self.at = at
        self.direction = direction
        self.title = title
        self.detail = detail
        self.ok = ok
        self.sessionID = sessionID
    }
}

/// Activity log and attributions, next to deck.json. No tokens.
public struct KodBridgeDisk: Codable, Equatable, Sendable {
    public var attributions: [KodAttribution]
    public var log: [KodActivityEntry]

    public static let maxAttributions = 300
    public static let maxLog = 200

    public init(attributions: [KodAttribution] = [], log: [KodActivityEntry] = []) {
        self.attributions = attributions
        self.log = log
    }

    public func trimmed() -> KodBridgeDisk {
        KodBridgeDisk(attributions: Array(attributions.suffix(Self.maxAttributions)), log: Array(log.suffix(Self.maxLog)))
    }
}

public struct KodProjectList: Encodable, Equatable, Sendable {
    public var projects: [KodProject]
    public init(projects: [KodProject]) { self.projects = projects }
}

public struct KodProject: Encodable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var sessions: [KodSessionInfo]

    public init(id: UUID, name: String, path: String, sessions: [KodSessionInfo]) {
        self.id = id
        self.name = name
        self.path = path
        self.sessions = sessions
    }
}

public struct KodSessionInfo: Encodable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: String
    public var status: String
    public var detail: String?
    public var updatedAt: Date?
    public var transcriptPath: String?
    public var claudeSessionID: String?

    public init(id: UUID, name: String, kind: String, status: String, detail: String? = nil, updatedAt: Date? = nil, transcriptPath: String? = nil, claudeSessionID: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.detail = detail
        self.updatedAt = updatedAt
        self.transcriptPath = transcriptPath
        self.claudeSessionID = claudeSessionID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, status, detail
        case updatedAt = "updated_at"
        case transcriptPath = "transcript_path"
        case claudeSessionID = "claude_session_id"
    }
}

public struct KodMessage: Encodable, Equatable, Sendable {
    public var id: String
    public var role: String
    public var text: String
    public var at: Date?
    public var source: String?

    public init(id: String, role: String, text: String, at: Date? = nil, source: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
        self.source = source
    }

    public init(entry: ChatEntry) {
        self.init(id: entry.id, role: entry.kind.rawValue, text: entry.text, at: entry.date, source: entry.source)
    }

    enum CodingKeys: String, CodingKey {
        case id, role, text, at, source
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(at, forKey: .at)
        try container.encodeIfPresent(source, forKey: .source)
    }
}

public struct KodMessagePage: Encodable, Equatable, Sendable {
    public var sessionID: UUID
    public var messages: [KodMessage]

    public init(sessionID: UUID, messages: [KodMessage]) {
        self.sessionID = sessionID
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case messages
    }
}

public struct KodHealth: Encodable, Equatable, Sendable {
    public var ok: Bool
    public init(ok: Bool) { self.ok = ok }
}

public struct KodAccepted: Encodable, Equatable, Sendable {
    public var ok: Bool
    public var sessionID: UUID

    public init(ok: Bool, sessionID: UUID) {
        self.ok = ok
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case sessionID = "session_id"
    }
}

public struct KodTextBody: Decodable, Equatable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct KodPromptBody: Decodable, Equatable, Sendable {
    public var prompt: String?
    public init(prompt: String?) { self.prompt = prompt }
}
