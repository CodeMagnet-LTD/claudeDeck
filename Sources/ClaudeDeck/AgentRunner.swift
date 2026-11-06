import ClaudeDeckCore
import Foundation
import Security

/// Calls an agent: the xAI chat completions API (OpenAI-compatible) or the profile's webhook.
enum AgentRunner {
    static let xaiBase = URL(string: "https://api.x.ai/v1")!

    /// No cookies, cache or shared credentials; answers bigger than this are refused.
    static let session = URLSession(configuration: .ephemeral)
    static let maxResponseBytes = AgentWebhook.maxResponseBytes

    enum Failure: LocalizedError {
        case noKey, noModel, badURL, insecureURL, tooLarge, http(Int, String), empty
        var errorDescription: String? {
            switch self {
            case .noKey: String(localized: "Add your xAI API key in Settings → Agents.")
            case .noModel: String(localized: "Pick a model for this agent in Settings → Agents.")
            case .badURL: String(localized: "The agent's webhook address isn't a valid URL.")
            case .insecureURL: String(localized: "Webhooks need https (http only to this Mac: 127.0.0.1 or localhost).")
            case .tooLarge: String(localized: "The agent's answer is too large.")
            case .http(let code, let body): String(localized: "The agent answered \(code): \(body)")
            case .empty: String(localized: "The agent sent an empty answer.")
            }
        }

        init(_ problem: AgentWebhook.Problem) {
            switch problem {
            case .badURL: self = .badURL
            case .insecureURL: self = .insecureURL
            case .tooLarge: self = .tooLarge
            case .empty: self = .empty
            }
        }
    }

    /// The agent's answer; nil when an asynchronous webhook took the request (the answer comes
    /// later through the local API).
    static func ask(_ profile: AgentProfile, payload: AgentPayload) async throws -> String? {
        profile.usesWebhook ? try await webhook(profile, payload: payload) : try await xai(profile, message: payload.message)
    }

    /// Settings' Test button.
    static func test(_ profile: AgentProfile) async throws -> String {
        let context = AgentContext(project: "ClaudeDeck", session: "Test", lastPrompt: nil, lastReply: nil, diff: nil,
                                   request: "Reply with one short sentence: who are you and what do you review?")
        let payload = AgentPayload(requestId: UUID().uuidString, event: .test, agent: profile, async: false,
                                   project: .init(id: nil, name: "ClaudeDeck", path: ""), sessionId: UUID(), sessionName: "Test",
                                   sessionState: "idle", context: context, transcriptPath: nil, callback: nil)
        var copy = profile
        copy.async = false
        return try await ask(copy, payload: payload) ?? String(localized: "Accepted (the answer comes later).")
    }

    private static func xai(_ profile: AgentProfile, message: String) async throws -> String {
        guard let key = AgentKeychain.xaiKey, !key.isEmpty else { throw Failure.noKey }
        let model = profile.model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw Failure.noModel }
        var messages: [[String: String]] = []
        let system = profile.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": message])
        var request = URLRequest(url: xaiBase.appending(path: "chat/completions"), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": messages])
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let content = (choices?.first?["message"] as? [String: Any])?["content"] as? String
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.empty }
        return content
    }

    /// Core's rules, as this runner's errors.
    static func webhookURL(_ raw: String?) throws -> URL {
        do { return try AgentWebhook.url(raw) } catch let problem as AgentWebhook.Problem { throw Failure(problem) }
    }

    static func reply(from data: Data) throws -> String {
        do { return try AgentWebhook.reply(from: data) } catch let problem as AgentWebhook.Problem { throw Failure(problem) }
    }

    private static func webhook(_ profile: AgentProfile, payload: AgentPayload) async throws -> String? {
        let url = try webhookURL(profile.webhookURL)
        var request = URLRequest(url: url, timeoutInterval: payload.async ? 30 : 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = AgentKeychain.webhookAuthorization(profile.id), !auth.isEmpty {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try AgentJSON.encode(payload)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        // Asynchronous: an acknowledgement is enough (an answer in it is still taken).
        if payload.async {
            return (try? reply(from: data)).flatMap { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // `{"status":"accepted"}`-style acknowledgements aren't answers.
                return trimmed.hasPrefix("{") ? nil : text
            }
        }
        return try reply(from: data)
    }

    /// The models the key can use (Settings' picker), sorted.
    static func xaiModels() async throws -> [String] {
        guard let key = AgentKeychain.xaiKey, !key.isEmpty else { throw Failure.noKey }
        var request = URLRequest(url: xaiBase.appending(path: "models"), timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ids = (json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        return ids.sorted()
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard data.count <= maxResponseBytes else { throw Failure.tooLarge }
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
        throw Failure.http(http.statusCode, body)
    }
}

/// The xAI API key, in the login keychain (never in deck.json, which iCloud may sync).
enum AgentKeychain {
    /// Demo copies keep their own items, never touching the real ones.
    private static let service = ProcessInfo.processInfo.environment["CLAUDEDECK_DEMO"] == nil
        ? "co.codemagnet.ClaudeDeck.agents" : "co.codemagnet.ClaudeDeck.agents.demo"
    private static let account = "xai"

    static var xaiKey: String? { read(account) }
    static func setXAIKey(_ key: String?) { write(key, account) }

    /// A webhook agent's Authorization header value ("Bearer …"), sent as typed.
    static func webhookAuthorization(_ agent: UUID) -> String? { read("webhook-" + agent.uuidString) }
    static func setWebhookAuthorization(_ value: String?, for agent: UUID) { write(value, "webhook-" + agent.uuidString) }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, _ account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
