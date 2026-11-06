import Foundation

/// Another model ClaudeDeck can ask about a Claude session (a Grok bot: a system prompt and a
/// model, called through the xAI API; or any service behind a webhook). It never talks to Claude
/// Code itself: its answer comes back as a note, and the user sends it on or not.
public struct AgentProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// xAI model id (picked from the API's list in Settings).
    public var model: String
    public var systemPrompt: String
    /// Set: POST the request here instead of calling xAI; the answer is `{"reply": "…"}` or text.
    public var webhookURL: String?

    public init(id: UUID = UUID(), name: String, model: String = "", systemPrompt: String = "", webhookURL: String? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.systemPrompt = systemPrompt
        self.webhookURL = webhookURL
    }

    public var usesWebhook: Bool { !(webhookURL ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
}

/// One answer (or the wait for it) from an agent about a session.
public struct AgentNote: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var agentID: UUID
    public var agentName: String
    /// What the user asked for, if anything ("check the error handling").
    public var request: String
    public var reply: String?
    public var error: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), agentID: UUID, agentName: String, request: String, reply: String? = nil, error: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.request = request
        self.reply = reply
        self.error = error
        self.createdAt = createdAt
    }

    public var pending: Bool { reply == nil && error == nil }
}

/// What a note's answer can do.
public enum AgentNoteAction: Codable, Sendable, Equatable {
    case dismiss
    /// Typed into the session now (Claude Code queues it while working).
    case sendToClaude
    /// Into the session's prompt queue.
    case queueForClaude
}

/// An agent as remotes see it.
public struct RemoteAgent: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// What an agent is told about the session.
public struct AgentContext: Sendable, Equatable {
    public var project: String
    public var session: String
    public var lastPrompt: String?
    public var lastReply: String?
    public var diff: String?
    public var request: String

    public init(project: String, session: String, lastPrompt: String?, lastReply: String?, diff: String?, request: String) {
        self.project = project
        self.session = session
        self.lastPrompt = lastPrompt
        self.lastReply = lastReply
        self.diff = diff
        self.request = request
    }

    public static let maxDiff = 60_000
    public static let maxText = 12_000

    /// The user message for the agent: the request first, then what Claude was asked, what it
    /// answered, and the uncommitted changes (each cut to a size an API takes).
    public var message: String {
        var parts: [String] = []
        let ask = request.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(ask.isEmpty ? "Review the latest work in this Claude Code session." : ask)
        parts.append("Project: \(project) · Session: \(session)")
        if let lastPrompt, !lastPrompt.isEmpty { parts.append("## The user's last message to Claude\n" + Self.cut(lastPrompt, Self.maxText)) }
        if let lastReply, !lastReply.isEmpty { parts.append("## Claude's last answer\n" + Self.cut(lastReply, Self.maxText)) }
        if let diff, !diff.isEmpty { parts.append("## Uncommitted changes (git diff)\n```diff\n" + Self.cut(diff, Self.maxDiff) + "\n```") }
        return parts.joined(separator: "\n\n")
    }

    static func cut(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n… (cut)" : text
    }
}

/// What goes into the session when the user sends a note on to Claude.
public enum AgentHandoff {
    public static func prompt(from note: AgentNote) -> String {
        "\(note.agentName) reviewed your work:\n\n\(note.reply ?? "")"
    }
}
