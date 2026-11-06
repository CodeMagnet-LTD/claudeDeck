import ClaudeDeckCore
import Foundation
import Security

/// Calls an agent: the xAI chat completions API (OpenAI-compatible) or the profile's webhook.
enum AgentRunner {
    static let xaiBase = URL(string: "https://api.x.ai/v1")!

    enum Failure: LocalizedError {
        case noKey, noModel, badURL, http(Int, String), empty
        var errorDescription: String? {
            switch self {
            case .noKey: String(localized: "Add your xAI API key in Settings → Agents.")
            case .noModel: String(localized: "Pick a model for this agent in Settings → Agents.")
            case .badURL: String(localized: "The agent's webhook address isn't a valid URL.")
            case .http(let code, let body): String(localized: "The agent answered \(code): \(body)")
            case .empty: String(localized: "The agent sent an empty answer.")
            }
        }
    }

    static func ask(_ profile: AgentProfile, message: String) async throws -> String {
        profile.usesWebhook ? try await webhook(profile, message: message) : try await xai(profile, message: message)
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
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let content = (choices?.first?["message"] as? [String: Any])?["content"] as? String
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.empty }
        return content
    }

    private static func webhook(_ profile: AgentProfile, message: String) async throws -> String {
        guard let url = URL(string: (profile.webhookURL ?? "").trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https" else { throw Failure.badURL }
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "agent": profile.name, "system": profile.systemPrompt, "model": profile.model, "message": message,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let reply = json["reply"] as? String {
            return reply
        }
        guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.empty }
        return text
    }

    /// The models the key can use (Settings' picker), sorted.
    static func xaiModels() async throws -> [String] {
        guard let key = AgentKeychain.xaiKey, !key.isEmpty else { throw Failure.noKey }
        var request = URLRequest(url: xaiBase.appending(path: "models"), timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ids = (json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        return ids.sorted()
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
        throw Failure.http(http.statusCode, body)
    }
}

/// The xAI API key, in the login keychain (never in deck.json, which iCloud may sync).
enum AgentKeychain {
    private static let service = "co.codemagnet.ClaudeDeck.agents"
    private static let account = "xai"

    static var xaiKey: String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setXAIKey(_ key: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
