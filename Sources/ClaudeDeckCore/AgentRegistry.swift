import Foundation

/// An agent that signed itself up through the local API (`POST /v1/agents`). It waits for the
/// user: until approved it gets no webhook and isn't in Ask Agent. Approved, it becomes an
/// ordinary webhook `AgentProfile` with the same id (not allowed to type into Claude, no projects
/// followed); the record stays so the agent can see it was approved, and so `DELETE` knows it
/// came from the API. Its Authorization header is in the keychain, never here.
///
/// A bot that can't see its own address (a Grok Bot routine) registers without `url`: the user
/// fills in the URL and the header when approving (`needs`).
public struct AgentRegistration: Codable, Identifiable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, approved, rejected }

    public var id: UUID
    public var name: String
    public var url: String
    public var async: Bool
    /// What the agent says it does, shown when the user decides (never sent anywhere).
    public var description: String
    public var status: Status
    public var createdAt: Date
    public var decidedAt: Date?
    /// An Authorization header is in the keychain for it (whether, never what).
    public var hasAuthHeader: Bool

    public init(id: UUID = UUID(), name: String, url: String, async: Bool, description: String, status: Status = .pending,
                createdAt: Date = Date(), decidedAt: Date? = nil, hasAuthHeader: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.async = async
        self.description = description
        self.status = status
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.hasAuthHeader = hasAuthHeader
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        async = try c.decodeIfPresent(Bool.self, forKey: .async) ?? false
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        status = try c.decode(Status.self, forKey: .status)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        hasAuthHeader = try c.decodeIfPresent(Bool.self, forKey: .hasAuthHeader) ?? false
    }

    /// The URL's host; empty while it has no URL.
    public var host: String { url.isEmpty ? "" : (URL(string: url)?.host ?? url) }

    /// What the user has to fill in before approving: registered without a URL, it needs the
    /// URL, and the header too unless it sent one.
    public var needs: [String] {
        guard url.isEmpty else { return [] }
        return hasAuthHeader ? ["url"] : ["url", "auth_header"]
    }

    /// The profile it becomes once approved: a webhook, every permission off.
    public var profile: AgentProfile {
        AgentProfile(id: id, name: name, webhookURL: url, async: async)
    }
}

/// The body of `POST /v1/agents`.
public struct AgentRegisterBody: Decodable, Sendable {
    public var name: String
    public var kind: String
    /// Optional: a bot that can't see its own address leaves it out (the user fills it in).
    public var url: String?
    public var authHeader: String?
    public var async: Bool?
    public var description: String?
}

/// One agent in `GET /v1/agents`: never its Authorization header, only its URL's host.
public struct AgentRegistrationInfo: Encodable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: String
    public var urlHost: String?
    public var status: AgentRegistration.Status
    public var async: Bool
    /// Signed up through the API (only those can be deleted through it).
    public var registered: Bool
    /// What the user still has to fill in ("url", "auth_header"); empty once approved.
    public var needs: [String]
}

/// What `POST /v1/agents` answers.
public struct AgentReceipt: Encodable, Sendable, Equatable {
    public var agentId: UUID
    public var status: AgentRegistration.Status
    public var needs: [String]
}

/// The rules for agents signing themselves up: who may, how many may wait, and what each
/// endpoint answers. Pure (the controller persists, writes the keychain and logs).
public enum AgentRegistry {
    public static let maxPending = 10
    public static let rejectionCooldown: TimeInterval = 24 * 60 * 60
    public static let maxBodyBytes = 16 * 1024
    public static let maxName = 40
    public static let maxDescription = 500
    public static let maxAuthHeader = AgentCompletion.maxAuthHeader

    /// What changed, for the controller to act on.
    public enum Effect: Equatable, Sendable {
        case none
        /// A new pending record; `authHeader` goes to the keychain under its id.
        case registered(AgentRegistration, authHeader: String?)
        /// Gone: its profile (if approved) and its keychain item go too.
        case deleted(AgentRegistration)
    }

    /// Rejected records past the cooldown, and approved ones whose profile the user deleted.
    public static func prune(_ registrations: inout [AgentRegistration], profiles: [AgentProfile], now: Date) {
        let ids = Set(profiles.map(\.id))
        registrations.removeAll { record in
            switch record.status {
            case .pending: false
            case .approved: !ids.contains(record.id)
            case .rejected: now.timeIntervalSince(record.decidedAt ?? record.createdAt) >= rejectionCooldown
            }
        }
    }

    public static func pending(_ registrations: [AgentRegistration]) -> [AgentRegistration] {
        registrations.filter { $0.status == .pending }
    }

    public typealias CompletionProblem = AgentCompletion.Problem

    public static func validHeader(_ value: String) -> Bool { AgentCompletion.validHeader(value) }

    /// What's wrong with the URL and header typed (or pasted) for `record`, nil when it can be approved.
    public static func completionProblem(_ record: AgentRegistration, url: String, authHeader: String) -> CompletionProblem? {
        guard record.status == .pending else { return .notPending }
        return AgentCompletion.problem(needs: record.needs, url: url, authHeader: authHeader)
    }

    /// Approve, with what the user filled in: the record's profile joins the agents. Returns the
    /// header to put in the keychain (nil: keep what's there).
    @discardableResult
    public static func approve(_ id: UUID, url: String = "", authHeader: String = "", registrations: inout [AgentRegistration],
                               profiles: inout [AgentProfile], now: Date) -> Result<(AgentRegistration, authHeader: String?), CompletionProblem> {
        guard let index = registrations.firstIndex(where: { $0.id == id && $0.status == .pending }) else { return .failure(.notPending) }
        if let problem = completionProblem(registrations[index], url: url, authHeader: authHeader) { return .failure(problem) }
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = authHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty, let parsed = try? AgentWebhook.url(url) { registrations[index].url = parsed.absoluteString }
        if !header.isEmpty { registrations[index].hasAuthHeader = true }
        registrations[index].status = .approved
        registrations[index].decidedAt = now
        let record = registrations[index]
        if !profiles.contains(where: { $0.id == id }) { profiles.append(record.profile) }
        return .success((record, header.isEmpty ? nil : header))
    }

    /// Reject: the record stays (as rejected) for the cooldown, so the same name and URL can't
    /// ask again at once.
    @discardableResult
    public static func reject(_ id: UUID, registrations: inout [AgentRegistration], now: Date) -> AgentRegistration? {
        guard let index = registrations.firstIndex(where: { $0.id == id && $0.status == .pending }) else { return nil }
        registrations[index].status = .rejected
        registrations[index].decidedAt = now
        return registrations[index]
    }

    // MARK: The endpoints

    /// `/v1/agents` and `/v1/agents/{id}`; other routes aren't this handler's.
    public static func handle(_ route: AgentRoute, body: Data, registrations: inout [AgentRegistration], profiles: inout [AgentProfile],
                              now: Date = Date()) -> (AgentHTTPResponse, Effect) {
        prune(&registrations, profiles: profiles, now: now)
        switch route {
        case .listAgents:
            return (.json(200, list(registrations: registrations, profiles: profiles)), .none)
        case .agentInfo(let id):
            guard let info = list(registrations: registrations, profiles: profiles).first(where: { $0.id == id }) else {
                return (.error(404, "unknown_agent"), .none)
            }
            return (.json(200, info), .none)
        case .deleteAgent(let id):
            guard let index = registrations.firstIndex(where: { $0.id == id }) else {
                return (profiles.contains { $0.id == id } ? .error(403, "not_registered_by_api") : .error(404, "unknown_agent"), .none)
            }
            // Deleting a rejection would let it ask again at once: it stays for the cooldown.
            guard registrations[index].status != .rejected else { return (.error(429, "rejected_recently"), .none) }
            let record = registrations.remove(at: index)
            profiles.removeAll { $0.id == id }
            return (.json(200, ["deleted": id.uuidString]), .deleted(record))
        case .registerAgent:
            return register(body, registrations: &registrations, profiles: profiles, now: now)
        default:
            return (.error(404, "not_found"), .none)
        }
    }

    static func register(_ data: Data, registrations: inout [AgentRegistration], profiles: [AgentProfile], now: Date) -> (AgentHTTPResponse, Effect) {
        guard data.count <= maxBodyBytes else { return (.error(413, "too_large"), .none) }
        guard let body = try? AgentJSON.decode(AgentRegisterBody.self, from: data) else { return (.error(400, "bad_request"), .none) }
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maxName, !name.contains(where: \.isNewline) else { return (.error(400, "bad_name"), .none) }
        guard body.kind == "webhook" else { return (.error(400, "bad_kind"), .none) }
        // No URL: the user fills it in when approving.
        let rawURL = (body.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var address = ""
        if !rawURL.isEmpty {
            do { address = try AgentWebhook.url(rawURL).absoluteString } catch AgentWebhook.Problem.insecureURL {
                return (.error(400, "insecure_url"), .none)
            } catch { return (.error(400, "bad_url"), .none) }
        }
        let auth = (body.authHeader ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !auth.isEmpty, !validHeader(auth) { return (.error(400, "bad_auth_header"), .none) }
        let description = (body.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard description.count <= maxDescription else { return (.error(400, "bad_description"), .none) }

        // The same agent again: what it already has. Without a URL the name alone says it's the same.
        if let profile = profiles.first(where: { sameName($0.name, name) }) {
            guard address.isEmpty || (profile.webhookURL ?? "").trimmingCharacters(in: .whitespaces) == address else {
                return (.error(409, "name_taken"), .none)
            }
            if let record = registrations.first(where: { $0.id == profile.id }) { return (.json(200, receipt(record)), .none) }
            return (.json(200, AgentReceipt(agentId: profile.id, status: .approved, needs: [])), .none)
        }
        if let record = registrations.first(where: { sameName($0.name, name) }) {
            guard address.isEmpty || record.url.isEmpty || record.url == address else { return (.error(409, "name_taken"), .none) }
            if record.status == .rejected { return (.error(429, "rejected_recently"), .none) }
            return (.json(200, receipt(record)), .none)
        }
        guard pending(registrations).count < maxPending else { return (.error(429, "too_many_pending"), .none) }
        let record = AgentRegistration(name: name, url: address, async: body.async ?? false, description: description, createdAt: now,
                                       hasAuthHeader: !auth.isEmpty)
        registrations.append(record)
        return (.json(201, receipt(record)), .registered(record, authHeader: auth.isEmpty ? nil : auth))
    }

    /// Settings' agents and the records not approved (yet), each once.
    public static func list(registrations: [AgentRegistration], profiles: [AgentProfile]) -> [AgentRegistrationInfo] {
        let fromAPI = Set(registrations.map(\.id))
        let approved = profiles.map { profile in
            AgentRegistrationInfo(id: profile.id, name: profile.name, kind: profile.usesWebhook ? "webhook" : "xai",
                                  urlHost: profile.usesWebhook ? URL(string: profile.webhookURL ?? "")?.host : nil,
                                  status: .approved, async: profile.usesWebhook && profile.async, registered: fromAPI.contains(profile.id),
                                  needs: [])
        }
        let waiting = registrations.filter { $0.status != .approved }.map { record in
            AgentRegistrationInfo(id: record.id, name: record.name, kind: "webhook", urlHost: record.host.isEmpty ? nil : record.host,
                                  status: record.status, async: record.async, registered: true, needs: record.status == .pending ? record.needs : [])
        }
        return approved + waiting
    }

    private static func receipt(_ record: AgentRegistration) -> AgentReceipt {
        AgentReceipt(agentId: record.id, status: record.status, needs: record.status == .pending ? record.needs : [])
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b) == .orderedSame
    }
}
