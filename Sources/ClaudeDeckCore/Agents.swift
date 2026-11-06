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
    /// Why "Send to Claude" / "Queue" didn't go through (the note stays).
    public var actionError: String?

    public init(id: UUID = UUID(), agentID: UUID, agentName: String, request: String, reply: String? = nil, error: String? = nil, createdAt: Date = Date()) {
        self.actionError = nil
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
    /// New files git doesn't track yet (Claude's new code), already filtered and cut.
    public var untracked: [UntrackedFile]
    public var request: String

    public init(project: String, session: String, lastPrompt: String?, lastReply: String?, diff: String?,
                untracked: [UntrackedFile] = [], request: String) {
        self.project = project
        self.session = session
        self.lastPrompt = lastPrompt
        self.lastReply = lastReply
        self.diff = diff
        self.untracked = untracked
        self.request = request
    }

    /// The user's last message and Claude's last text answer in a transcript (tool calls and
    /// their results don't count).
    public static func lastExchange(in entries: [ChatEntry]) -> (prompt: String?, reply: String?) {
        let prompt = entries.last { $0.kind == .user && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
        let reply = entries.last { $0.kind == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
        return (prompt, reply)
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
        if !untracked.isEmpty {
            parts.append("## New files (not in git yet)\n" + untracked.map { "### \($0.path)\n```\n\($0.content)\n```" }.joined(separator: "\n\n"))
        }
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

/// A file git doesn't track, for an agent: its path in the project and (part of) its text.
public struct UntrackedFile: Codable, Sendable, Equatable {
    public var path: String
    public var content: String

    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }

    public static let maxFiles = 25
    public static let maxFileCharacters = 16_000
    public static let maxTotalCharacters = 48_000
    public static let maxFileBytes = 256_000

    /// Never sent, whatever .gitignore says: keys, certificates, env files, credentials.
    public static func isSecret(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasPrefix(".env") || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa") { return true }
        let ext = (name as NSString).pathExtension
        if ["pem", "key", "p12", "pfx", "p8", "keystore", "jks", "mobileprovision", "cer", "crt", "der", "kdbx"].contains(ext) { return true }
        return ["credentials", "credentials.json", "secrets.json", "service-account.json", ".netrc", ".npmrc", ".pypirc"].contains(name)
            || name.contains("secret") || name.contains("token")
    }

    /// Text files only (no NUL in the first 8 KB), each cut, within the totals.
    public static func select(_ candidates: [(path: String, data: Data)]) -> [UntrackedFile] {
        var result: [UntrackedFile] = []
        var total = 0
        for candidate in candidates where !isSecret(candidate.path) && candidate.data.count <= maxFileBytes {
            guard result.count < maxFiles, total < maxTotalCharacters else { break }
            guard !candidate.data.prefix(8192).contains(0), var text = String(data: candidate.data, encoding: .utf8) else { continue }
            let room = min(maxFileCharacters, maxTotalCharacters - total)
            if text.count > room { text = String(text.prefix(room)) + "\n… (cut)" }
            total += text.count
            result.append(UntrackedFile(path: candidate.path, content: text))
        }
        return result
    }
}

/// Webhook rules: where an agent may be reached, and what counts as its answer.
public enum AgentWebhook {
    public enum Problem: Error, Equatable { case badURL, insecureURL, tooLarge, empty }
    public static let maxResponseBytes = 1 << 20

    /// https, or http to this Mac only (a bot running here).
    public static func url(_ raw: String?) throws -> URL {
        guard let url = URL(string: (raw ?? "").trimmingCharacters(in: .whitespaces)), let host = url.host?.lowercased(),
              let scheme = url.scheme?.lowercased() else { throw Problem.badURL }
        if scheme == "https" { return url }
        guard scheme == "http" else { throw Problem.badURL }
        guard ["127.0.0.1", "localhost", "::1"].contains(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) else { throw Problem.insecureURL }
        return url
    }

    /// `{"reply": "…"}` or plain text; empty either way, or too large, is refused.
    public static func reply(from data: Data) throws -> String {
        guard data.count <= maxResponseBytes else { throw Problem.tooLarge }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["reply"] != nil {
            guard let reply = json["reply"] as? String, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Problem.empty }
            return reply
        }
        guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Problem.empty }
        return text
    }
}
