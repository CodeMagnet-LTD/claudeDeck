import Foundation

/// The agents' local API (127.0.0.1 only) and the payload ClaudeDeck posts to webhook agents.
/// The contract is in docs/agents.md.
public enum AgentJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
}

/// `Authorization: Bearer <token>`: the scheme in any case, the token exactly.
public enum AgentBearer {
    public static func credential(from header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, String(parts[0]).caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : String(token)
    }

    /// Constant time for tokens of the same length; a different length or an empty expected
    /// token never matches.
    public static func matches(_ presented: String, expected: String) -> Bool {
        let left = Array(presented.utf8), right = Array(expected.utf8)
        guard !right.isEmpty, left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    public static func authorized(_ header: String?, token: String?) -> Bool {
        guard let token, let presented = credential(from: header) else { return false }
        return matches(presented, expected: token)
    }

    /// 32 random bytes, URL-safe base64.
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public enum AgentRoute: Equatable, Sendable {
    case projects
    case messages(session: UUID)
    case notes
    case prompt(session: UUID)
    case newSession(project: UUID)
    /// Agents signing themselves up (AgentRegistry).
    case listAgents
    case registerAgent
    case agentInfo(UUID)
    case deleteAgent(UUID)

    public enum Match: Equatable, Sendable {
        case route(AgentRoute)
        case notFound
        case methodNotAllowed
    }

    public static func match(method: String, path: String) -> Match {
        var path = path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == "v1" else { return .notFound }
        let rest = Array(parts.dropFirst())
        func expect(_ wanted: String, _ route: AgentRoute) -> Match { method == wanted ? .route(route) : .methodNotAllowed }
        switch rest.count {
        case 1 where rest[0] == "projects": return expect("GET", .projects)
        case 1 where rest[0] == "notes": return expect("POST", .notes)
        case 1 where rest[0] == "agents":
            switch method {
            case "GET": return .route(.listAgents)
            case "POST": return .route(.registerAgent)
            default: return .methodNotAllowed
            }
        case 2 where rest[0] == "agents":
            guard let id = UUID(uuidString: rest[1]) else { return .notFound }
            switch method {
            case "GET": return .route(.agentInfo(id))
            case "DELETE": return .route(.deleteAgent(id))
            default: return .methodNotAllowed
            }
        case 3 where rest[0] == "sessions" && rest[2] == "messages":
            guard let id = UUID(uuidString: rest[1]) else { return .notFound }
            return expect("GET", .messages(session: id))
        case 3 where rest[0] == "sessions" && rest[2] == "prompt":
            guard let id = UUID(uuidString: rest[1]) else { return .notFound }
            return expect("POST", .prompt(session: id))
        case 3 where rest[0] == "projects" && rest[2] == "sessions":
            guard let id = UUID(uuidString: rest[1]) else { return .notFound }
            return expect("POST", .newSession(project: id))
        default: return .notFound
        }
    }

    /// The token first (401 before anything else), then the route; a response when it ends there.
    public static func resolve(_ request: AgentHTTPRequest, token: String?) -> Result<AgentRoute, AgentHTTPRequestRefusal> {
        guard AgentBearer.authorized(request.header("authorization"), token: token) else { return .failure(.init(.error(401, "unauthorized"))) }
        switch match(method: request.method, path: request.path) {
        case .notFound: return .failure(.init(.error(404, "not_found")))
        case .methodNotAllowed: return .failure(.init(.error(405, "method_not_allowed")))
        case .route(let route): return .success(route)
        }
    }

    public static func limit(_ query: [String: String], default value: Int = 20) -> Int {
        min(200, max(1, query["limit"].flatMap(Int.init) ?? value))
    }
}

/// Why a request stopped before its route (`AgentRoute.resolve`).
public struct AgentHTTPRequestRefusal: Error, Equatable, Sendable {
    public var response: AgentHTTPResponse
    public init(_ response: AgentHTTPResponse) { self.response = response }
}

/// Request bodies.
public struct AgentNoteBody: Decodable, Sendable {
    public var requestId: String?
    public var sessionId: UUID
    public var agent: String
    public var text: String
}

public struct AgentPromptBody: Decodable, Sendable {
    public var agent: String
    public var text: String
}

public struct AgentNewSessionBody: Decodable, Sendable {
    public var agent: String
    public var name: String?
    public var prompt: String?
}

/// Responses.
public struct AgentProjectInfo: Encodable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var path: String
    public var sessions: [AgentSessionInfo]
    public init(id: UUID, name: String, path: String, sessions: [AgentSessionInfo]) {
        self.id = id
        self.name = name
        self.path = path
        self.sessions = sessions
    }
}

public struct AgentSessionInfo: Encodable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: String
    public var state: String
    public var detail: String?
    public var updatedAt: Date?
    public init(id: UUID, name: String, kind: String, state: String, detail: String?, updatedAt: Date?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.state = state
        self.detail = detail
        self.updatedAt = updatedAt
    }
}

public struct AgentMessageInfo: Encodable, Sendable, Equatable {
    public var id: String
    public var role: String
    public var text: String
    public var tool: String?
    public var timestamp: Date?
    public init(_ entry: ChatEntry) {
        id = entry.id
        role = entry.kind.rawValue
        text = entry.text
        tool = entry.toolName
        timestamp = entry.date
    }
}

/// What ClaudeDeck posts to a webhook agent: a request from the user, or an automatic event.
public struct AgentPayload: Encodable, Sendable, Equatable {
    public enum Event: String, Encodable, Sendable {
        case manual
        case idle = "session.idle"
        case permission = "session.permission"
        case question = "session.question"
        case test = "agent.test"
        /// The Claude session asked by itself (`claudedeck-ask`).
        case claudeAsk = "session.claude_ask"
    }

    public struct Project: Encodable, Sendable, Equatable {
        public var id: UUID?
        public var name: String
        public var path: String
        public init(id: UUID?, name: String, path: String) {
            self.id = id
            self.name = name
            self.path = path
        }
    }

    public struct Callback: Encodable, Sendable, Equatable {
        /// POST the answer here (`/v1/notes`, with `request_id`), when the agent answers later.
        public var notesUrl: String
        public var requestId: String
        public init(notesUrl: String, requestId: String) {
            self.notesUrl = notesUrl
            self.requestId = requestId
        }
    }

    public var requestId: String
    public var event: Event
    public var agent: String
    public var system: String
    public var model: String
    public var async: Bool
    public var project: Project
    public var sessionId: UUID
    public var sessionName: String
    public var sessionState: String
    public var userRequest: String
    public var lastUserMessage: String?
    public var lastAssistantMessage: String?
    public var gitDiff: String?
    public var untrackedFiles: [UntrackedFile]
    public var transcriptPath: String?
    public var timestamp: Date
    /// The same as one readable text (what an xAI agent gets as its message).
    public var message: String
    public var callback: Callback?

    public init(requestId: String, event: Event, agent: AgentProfile, async: Bool, project: Project, sessionId: UUID, sessionName: String,
                sessionState: String, context: AgentContext, transcriptPath: String?, timestamp: Date = Date(), callback: Callback?) {
        self.requestId = requestId
        self.event = event
        self.agent = agent.name
        self.system = agent.systemPrompt
        self.model = agent.model
        self.async = async
        self.project = project
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.sessionState = sessionState
        self.userRequest = context.request
        self.lastUserMessage = context.lastPrompt
        self.lastAssistantMessage = context.lastReply
        self.gitDiff = context.diff.map { AgentContext.cut($0, AgentContext.maxDiff) }
        self.untrackedFiles = context.untracked
        self.transcriptPath = transcriptPath
        self.timestamp = timestamp
        self.message = context.message
        self.callback = callback
    }

    private enum CodingKeys: String, CodingKey {
        case requestId, event, agent, system, model, async, project, sessionId, sessionName, sessionState, userRequest
        case lastUserMessage, lastAssistantMessage, gitDiff, untrackedFiles, transcriptPath, timestamp, message, callback
    }

    /// Every field is always there; what's unknown is null (a bot can rely on the keys).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(event, forKey: .event)
        try c.encode(agent, forKey: .agent)
        try c.encode(system, forKey: .system)
        try c.encode(model, forKey: .model)
        try c.encode(async, forKey: .async)
        try c.encode(project, forKey: .project)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(sessionName, forKey: .sessionName)
        try c.encode(sessionState, forKey: .sessionState)
        try c.encode(userRequest, forKey: .userRequest)
        try c.encode(lastUserMessage, forKey: .lastUserMessage)
        try c.encode(lastAssistantMessage, forKey: .lastAssistantMessage)
        try c.encode(gitDiff, forKey: .gitDiff)
        try c.encode(untrackedFiles, forKey: .untrackedFiles)
        try c.encode(transcriptPath, forKey: .transcriptPath)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(message, forKey: .message)
        try c.encode(callback, forKey: .callback)
    }
}

/// Automatic requests: once per turn and state (a status update repeating it doesn't count),
/// never for the idle a session starts in, and at most `maxRounds` in a row without the user.
public struct AgentTriggerGate: Sendable, Equatable {
    public static let maxRounds = 3
    private var lastKey: [UUID: String] = [:]
    private var rounds: [UUID: Int] = [:]

    public init() {}

    public enum Decision: Equatable, Sendable { case send(AgentPayload.Event), skip, paused }

    /// `event` is the hook's last event ("Stop", "SessionStart"…); `turn` identifies the turn
    /// (the status's time); `byUser` is true when the last message to Claude was the user's.
    public mutating func decide(session: UUID, state: String, event: String?, turn: String, byUser: Bool) -> Decision {
        let kind: AgentPayload.Event
        switch state {
        case "idle": kind = .idle
        case "needsPermission": kind = .permission
        case "needsAnswer": kind = .question
        default: return .skip
        }
        if kind == .idle, event == "SessionStart" { return .skip }
        let key = "\(state)|\(turn)"
        guard lastKey[session] != key else { return .skip }
        lastKey[session] = key
        if byUser { rounds[session] = 0 }
        guard rounds[session, default: 0] < Self.maxRounds else { return .paused }
        rounds[session, default: 0] += 1
        return .send(kind)
    }

    /// The user wrote to Claude (or asked to go on): automatic requests start counting again.
    public mutating func reset(_ session: UUID) { rounds[session] = 0 }
}
