import Foundation
import Testing
@testable import ClaudeDeckCore

/// `POST/GET/DELETE /v1/agents`: agents signing themselves up and waiting for the user.
@Suite struct AgentRegistryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Deck {
        var registrations: [AgentRegistration] = []
        var profiles: [AgentProfile] = []
    }

    private func body(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: fields)
    }

    private func register(_ deck: inout Deck, name: String = "Grok Bot", url: String = "https://bots.example.com/hook",
                          auth: String? = nil, extra: [String: Any] = [:], at date: Date? = nil) -> (AgentHTTPResponse, AgentRegistry.Effect) {
        var fields: [String: Any] = ["name": name, "kind": "webhook", "url": url]
        if let auth { fields["auth_header"] = auth }
        fields.merge(extra) { $1 }
        return AgentRegistry.handle(.registerAgent, body: body(fields), registrations: &deck.registrations, profiles: &deck.profiles, now: date ?? now)
    }

    private func json(_ response: AgentHTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    private func error(_ response: AgentHTTPResponse) -> String? { json(response)["error"] as? String }

    @Test func registersAsPendingWithTheHeaderForTheKeychain() throws {
        var deck = Deck()
        let (response, effect) = register(&deck, auth: "Bearer s3cret-value", extra: ["async": true, "description": "Reviews diffs"])
        #expect(response.status == 201)
        #expect(json(response)["status"] as? String == "pending")
        let id = try #require((json(response)["agent_id"] as? String).flatMap(UUID.init))
        #expect(deck.registrations.count == 1 && deck.registrations[0].id == id)
        #expect(deck.registrations[0].async && deck.registrations[0].description == "Reviews diffs")
        guard case .registered(let record, let header) = effect else { Issue.record("no effect"); return }
        #expect(record.id == id && header == "Bearer s3cret-value")
        // The header is never in what's saved to deck.json.
        let saved = String(decoding: try JSONEncoder().encode(deck.registrations), as: UTF8.self)
        #expect(!saved.contains("s3cret"))
    }

    @Test func sameNameAndURLIsIdempotent() throws {
        var deck = Deck()
        let first = register(&deck)
        let again = register(&deck, name: "  grok bot ")
        #expect(again.0.status == 200)
        #expect(again.1 == .none)
        #expect(json(again.0)["agent_id"] as? String == json(first.0)["agent_id"] as? String)
        #expect(json(again.0)["status"] as? String == "pending")
        #expect(deck.registrations.count == 1)
    }

    @Test func sameNameOtherURLConflicts() {
        var deck = Deck()
        _ = register(&deck)
        let (response, effect) = register(&deck, url: "https://elsewhere.example.com/hook")
        #expect(response.status == 409 && error(response) == "name_taken" && effect == .none)
        // A name taken by an agent added in Settings, too.
        deck.profiles = [AgentProfile(name: "Kod Checker", model: "grok-4")]
        #expect(register(&deck, name: "kod checker").0.status == 409)
        // The same name and URL as a Settings webhook agent: that one, approved.
        deck.profiles.append(AgentProfile(name: "Hooked", webhookURL: "https://h.example.com/x"))
        let existing = register(&deck, name: "Hooked", url: "https://h.example.com/x")
        #expect(existing.0.status == 200 && json(existing.0)["status"] as? String == "approved")
    }

    @Test func refusesPlainHTTPExceptToThisMac() {
        var deck = Deck()
        let insecure = register(&deck, url: "http://bots.example.com/hook")
        #expect(insecure.0.status == 400 && error(insecure.0) == "insecure_url")
        #expect(register(&deck, name: "Bad", url: "ftp://x.example.com").0.status == 400)
        #expect(register(&deck, name: "Bad2", url: "not a url").0.status == 400)
        #expect(register(&deck, name: "Local", url: "http://127.0.0.1:8080/hook").0.status == 201)
        #expect(register(&deck, name: "Local2", url: "http://localhost:8080/hook").0.status == 201)
    }

    @Test func validatesNameKindBodyAndJSON() {
        var deck = Deck()
        #expect(error(register(&deck, name: "").0) == "bad_name")
        #expect(error(register(&deck, name: "   \t ").0) == "bad_name")
        #expect(error(register(&deck, name: String(repeating: "a", count: 41)).0) == "bad_name")
        #expect(register(&deck, name: String(repeating: "a", count: 40)).0.status == 201)
        #expect(error(register(&deck, name: "Line\nBreak").0) == "bad_name")
        #expect(error(register(&deck, name: "X", extra: ["kind": "xai"]).0) == "bad_kind")
        #expect(error(register(&deck, name: "Y", auth: "Bearer a\r\nX-Evil: 1").0) == "bad_auth_header")
        let broken = AgentRegistry.handle(.registerAgent, body: Data("{not json".utf8), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        #expect(broken.0.status == 400 && error(broken.0) == "bad_request")
        let missing = AgentRegistry.handle(.registerAgent, body: body(["name": "Z"]), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        #expect(missing.0.status == 400)
        let huge = register(&deck, name: "Huge", extra: ["description": String(repeating: "x", count: AgentRegistry.maxBodyBytes)])
        #expect(huge.0.status == 413)
        #expect(deck.registrations.count == 1)
    }

    @Test func requestsWithoutTheTokenAreRefused() throws {
        let request = AgentHTTPRequest(method: "POST", path: "/v1/agents", query: [:], headers: [:], body: Data())
        guard case .failure(let refusal) = AgentRoute.resolve(request, token: "secret") else { Issue.record("passed"); return }
        #expect(refusal.response.status == 401 && refusal.response.authenticate)
        var wrong = request
        wrong.headers["authorization"] = "Bearer nope"
        #expect((try? AgentRoute.resolve(wrong, token: "secret").get()) == nil)
        var right = request
        right.headers["authorization"] = "Bearer secret"
        #expect(try AgentRoute.resolve(right, token: "secret").get() == .registerAgent)
        // No token set up yet: nobody gets in.
        #expect((try? AgentRoute.resolve(right, token: nil).get()) == nil)
    }

    @Test func listingNeverShowsTheHeaderOnlyTheHost() throws {
        var deck = Deck()
        deck.profiles = [AgentProfile(name: "Grok", model: "grok-4"),
                         AgentProfile(name: "Manual Hook", webhookURL: "https://manual.example.com/path?key=abc")]
        let (created, _) = register(&deck, url: "https://bots.example.com/hook?token=zzz", auth: "Bearer top-secret-header")
        let id = try #require((json(created)["agent_id"] as? String).flatMap(UUID.init))
        let (list, _) = AgentRegistry.handle(.listAgents, body: Data(), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        let text = String(decoding: list.body, as: UTF8.self)
        #expect(list.status == 200)
        #expect(!text.contains("top-secret") && !text.contains("auth_header") && !text.contains("zzz") && !text.contains("key=abc"))
        let items = try #require(try JSONSerialization.jsonObject(with: list.body) as? [[String: Any]])
        #expect(items.count == 3)
        let mine = try #require(items.first { $0["id"] as? String == id.uuidString })
        #expect(mine["url_host"] as? String == "bots.example.com" && mine["status"] as? String == "pending" && mine["kind"] as? String == "webhook")
        #expect(items.first { $0["name"] as? String == "Grok" }?["kind"] as? String == "xai")

        let (info, _) = AgentRegistry.handle(.agentInfo(id), body: Data(), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        #expect(info.status == 200 && !String(decoding: info.body, as: UTF8.self).contains("top-secret"))
        #expect(json(info)["status"] as? String == "pending")
        let unknown = AgentRegistry.handle(.agentInfo(UUID()), body: Data(), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        #expect(unknown.0.status == 404)
    }

    /// The app asks only `settings.agents` (Ask Agent, automatic requests, the phone's list):
    /// a pending agent isn't there, an approved one is, with every permission off.
    @Test func pendingGetsNothingApprovedIsAnOrdinaryWebhookAgent() throws {
        var deck = Deck()
        let project = UUID()
        let (created, _) = register(&deck, extra: ["async": true])
        let id = try #require((json(created)["agent_id"] as? String).flatMap(UUID.init))
        #expect(deck.profiles.isEmpty)
        #expect(!deck.profiles.contains { $0.follows(project: project) || $0.id == id })

        let approved = try AgentRegistry.approve(id, registrations: &deck.registrations, profiles: &deck.profiles, now: now).get()
        #expect(approved.0.status == .approved && approved.authHeader == nil)
        let profile = try #require(deck.profiles.first { $0.id == id })
        #expect(profile.usesWebhook && profile.webhookURL == "https://bots.example.com/hook" && profile.async)
        #expect(!profile.canSendDirectly && !profile.autoTrigger && profile.autoProjects.isEmpty)
        #expect(profile.systemPrompt.isEmpty)
        let (info, _) = AgentRegistry.handle(.agentInfo(id), body: Data(), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        #expect(json(info)["status"] as? String == "approved")
        // Approving twice adds nothing.
        #expect((try? AgentRegistry.approve(id, registrations: &deck.registrations, profiles: &deck.profiles, now: now).get()) == nil)
        #expect(deck.profiles.count == 1)
        // Registering again: the same agent, approved.
        #expect(json(register(&deck).0)["status"] as? String == "approved")
    }

    @Test func atMostTenWaiting() {
        var deck = Deck()
        for index in 0..<AgentRegistry.maxPending {
            #expect(register(&deck, name: "Bot \(index)").0.status == 201)
        }
        let (response, effect) = register(&deck, name: "One Too Many")
        #expect(response.status == 429 && error(response) == "too_many_pending" && effect == .none)
        // One decided: room again.
        AgentRegistry.reject(deck.registrations[0].id, registrations: &deck.registrations, now: now)
        #expect(register(&deck, name: "One Too Many").0.status == 201)
    }

    @Test func rejectedCantAskAgainForADay() throws {
        var deck = Deck()
        let (created, _) = register(&deck)
        let id = try #require((json(created)["agent_id"] as? String).flatMap(UUID.init))
        #expect(AgentRegistry.reject(id, registrations: &deck.registrations, now: now)?.status == .rejected)
        #expect(deck.profiles.isEmpty)
        let soon = register(&deck, at: now.addingTimeInterval(3600))
        #expect(soon.0.status == 429 && error(soon.0) == "rejected_recently")
        let (info, _) = AgentRegistry.handle(.agentInfo(id), body: Data(), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        #expect(json(info)["status"] as? String == "rejected")
        // Nor clear its rejection by deleting itself.
        let delete = AgentRegistry.handle(.deleteAgent(id), body: Data(), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        #expect(delete.0.status == 429 && delete.1 == .none && deck.registrations.count == 1)
        #expect(register(&deck, at: now.addingTimeInterval(7200)).0.status == 429)
        // A rejected agent can't be approved afterwards.
        #expect((try? AgentRegistry.approve(id, registrations: &deck.registrations, profiles: &deck.profiles, now: now).get()) == nil)
        let later = register(&deck, at: now.addingTimeInterval(AgentRegistry.rejectionCooldown + 1))
        #expect(later.0.status == 201 && json(later.0)["agent_id"] as? String != id.uuidString)
    }

    @Test func deleteOnlyWhatTheAPIAdded() throws {
        var deck = Deck()
        let manual = AgentProfile(name: "Manual", webhookURL: "https://m.example.com")
        deck.profiles = [manual]
        let (created, _) = register(&deck)
        let id = try #require((json(created)["agent_id"] as? String).flatMap(UUID.init))
        _ = AgentRegistry.approve(id, registrations: &deck.registrations, profiles: &deck.profiles, now: now)

        let forbidden = AgentRegistry.handle(.deleteAgent(manual.id), body: Data(), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        #expect(forbidden.0.status == 403 && deck.profiles.contains(manual))
        let unknown = AgentRegistry.handle(.deleteAgent(UUID()), body: Data(), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        #expect(unknown.0.status == 404)
        let (deleted, effect) = AgentRegistry.handle(.deleteAgent(id), body: Data(), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        #expect(deleted.status == 200)
        guard case .deleted(let record) = effect else { Issue.record("no effect"); return }
        #expect(record.id == id && deck.registrations.isEmpty && deck.profiles == [manual])
    }

    @Test func approvedRecordGoesWhenItsProfileIsDeletedInSettings() throws {
        var deck = Deck()
        let (created, _) = register(&deck)
        let id = try #require((json(created)["agent_id"] as? String).flatMap(UUID.init))
        _ = AgentRegistry.approve(id, registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        deck.profiles.removeAll()
        AgentRegistry.prune(&deck.registrations, profiles: deck.profiles, now: now)
        #expect(deck.registrations.isEmpty)
        // It may ask again (pending once more).
        #expect(register(&deck).0.status == 201)
    }

    // MARK: Registering without a URL (Grok Bot routines can't see their own)

    private func registerWithoutURL(_ deck: inout Deck, name: String = "Grok Routine", extra: [String: Any] = [:]) -> (AgentHTTPResponse, AgentRegistry.Effect) {
        var fields: [String: Any] = ["name": name, "kind": "webhook"]
        fields.merge(extra) { $1 }
        return AgentRegistry.handle(.registerAgent, body: body(fields), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
    }

    @Test func registersWithoutURLAndSaysWhatItNeeds() throws {
        var deck = Deck()
        let (response, effect) = registerWithoutURL(&deck)
        #expect(response.status == 201)
        #expect(json(response)["status"] as? String == "pending")
        #expect(json(response)["needs"] as? [String] == ["url", "auth_header"])
        guard case .registered(let record, let header) = effect else { Issue.record("no effect"); return }
        #expect(record.url.isEmpty && record.host.isEmpty && header == nil && record.needs == ["url", "auth_header"])
        // With a header but no URL, only the URL is missing; with a URL, nothing.
        #expect(json(registerWithoutURL(&deck, name: "Has Header", extra: ["auth_header": "Bearer abc"]).0)["needs"] as? [String] == ["url"])
        #expect(json(registerWithoutURL(&deck, name: "Empty URL", extra: ["url": "  "]).0)["needs"] as? [String] == ["url", "auth_header"])
        #expect(json(register(&deck, name: "With URL").0)["needs"] as? [String] == [])
        // Listed without a host, with its needs.
        let id = try #require((json(response)["agent_id"] as? String).flatMap(UUID.init))
        let (info, _) = AgentRegistry.handle(.agentInfo(id), body: Data(), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        #expect(json(info)["url_host"] == nil || json(info)["url_host"] is NSNull)
        #expect(json(info)["needs"] as? [String] == ["url", "auth_header"])
    }

    @Test func withoutURLTheNameAloneIsIdempotent() throws {
        var deck = Deck()
        let first = registerWithoutURL(&deck)
        let again = registerWithoutURL(&deck, name: "grok routine")
        #expect(again.0.status == 200 && again.1 == .none && deck.registrations.count == 1)
        #expect(json(again.0)["agent_id"] as? String == json(first.0)["agent_id"] as? String)
        #expect(json(again.0)["needs"] as? [String] == ["url", "auth_header"])
        // Sending a URL later for the same name: still that record (the user fills it in).
        #expect(json(register(&deck, name: "Grok Routine").0)["agent_id"] as? String == json(first.0)["agent_id"] as? String)
        // Without a URL, an agent of that name in Settings is the one returned.
        deck.profiles.append(AgentProfile(name: "Manual", webhookURL: "https://m.example.com"))
        #expect(json(registerWithoutURL(&deck, name: "manual").0)["status"] as? String == "approved")
    }

    @Test func approvingWithoutTheMissingFieldsIsRefused() throws {
        var deck = Deck()
        let id = try #require((json(registerWithoutURL(&deck).0)["agent_id"] as? String).flatMap(UUID.init))
        var registrations = deck.registrations, profiles = deck.profiles
        func approve(_ url: String, _ header: String) -> AgentRegistry.CompletionProblem? {
            if case .failure(let problem) = AgentRegistry.approve(id, url: url, authHeader: header, registrations: &registrations,
                                                                  profiles: &profiles, now: now) { return problem }
            return nil
        }
        #expect(approve("", "") == .missingURL)
        #expect(approve("https://routines.example.com/hook", "") == .missingAuthHeader)
        #expect(approve("http://routines.example.com/hook", "Bearer x") == .insecureURL)
        #expect(approve("not a url", "Bearer x") == .badURL)
        #expect(approve("https://routines.example.com/hook", "Bearer a\r\nX-Evil: 1") == .badAuthHeader)
        #expect(approve("https://routines.example.com/hook", "Bearer şifre") == .badAuthHeader)
        #expect(approve("https://routines.example.com/hook", String(repeating: "a", count: AgentRegistry.maxAuthHeader + 1)) == .badAuthHeader)
        #expect(profiles.isEmpty && registrations[0].status == .pending)
        // The same rules the form uses (Mac and phone).
        #expect(AgentCompletion.problem(needs: ["url", "auth_header"], url: "", authHeader: "") == .missingURL)
        #expect(AgentCompletion.problem(needs: [], url: "", authHeader: "") == nil)
        #expect(AgentCompletion.problem(needs: [], url: "http://127.0.0.1:9/x", authHeader: "") == nil)
    }

    @Test func approvedWithPastedURLAndHeaderGetsWebhooks() throws {
        var deck = Deck()
        let id = try #require((json(registerWithoutURL(&deck, extra: ["async": true]).0)["agent_id"] as? String).flatMap(UUID.init))
        let result = try AgentRegistry.approve(id, url: " https://routines.example.com/r/abc?k=1 ", authHeader: " Bearer routine-secret ",
                                               registrations: &deck.registrations, profiles: &deck.profiles, now: now).get()
        #expect(result.authHeader == "Bearer routine-secret")
        #expect(result.0.status == .approved && result.0.url == "https://routines.example.com/r/abc?k=1" && result.0.hasAuthHeader)
        // Now an ordinary webhook agent (what Ask Agent and automatic requests use), permissions off.
        let profile = try #require(deck.profiles.first { $0.id == id })
        #expect(profile.usesWebhook && profile.webhookURL == "https://routines.example.com/r/abc?k=1" && profile.async)
        #expect(!profile.canSendDirectly && !profile.claudeCanAsk && profile.autoProjects.isEmpty)
        // GET: approved, host only, never the header, nothing needed.
        let (info, _) = AgentRegistry.handle(.agentInfo(id), body: Data(), registrations: &deck.registrations, profiles: &deck.profiles, now: now)
        let text = String(decoding: info.body, as: UTF8.self)
        #expect(json(info)["status"] as? String == "approved" && json(info)["url_host"] as? String == "routines.example.com")
        #expect(json(info)["needs"] as? [String] == [] && !text.contains("routine-secret") && !text.contains("abc?k"))
        // The saved record holds no header.
        #expect(!String(decoding: try JSONEncoder().encode(deck.registrations), as: UTF8.self).contains("routine-secret"))
    }

    @Test func recordsSavedBy050StillDecode() throws {
        let old = #"[{"id":"\#(UUID().uuidString)","name":"Old","url":"https://o.example.com/h","async":false,"description":"","status":"pending","createdAt":800000000}]"#
        let records = try JSONDecoder().decode([AgentRegistration].self, from: Data(old.utf8))
        #expect(records.first?.needs == [] && records.first?.hasAuthHeader == false)
        // A 0.5.0 phone's approval (no url / header) still decodes on the Mac.
        let message = #"{"agentRegistration":{"agentID":"\#(UUID().uuidString)","approve":true}}"#
        guard case .agentRegistration(_, true, nil, nil) = try JSONDecoder().decode(RemoteMessage.self, from: Data(message.utf8)) else {
            Issue.record("old approval didn't decode"); return
        }
    }

    @Test func routes() {
        let id = UUID()
        #expect(AgentRoute.match(method: "GET", path: "/v1/agents") == .route(.listAgents))
        #expect(AgentRoute.match(method: "POST", path: "/v1/agents/") == .route(.registerAgent))
        #expect(AgentRoute.match(method: "GET", path: "/v1/agents/\(id)") == .route(.agentInfo(id)))
        #expect(AgentRoute.match(method: "DELETE", path: "/v1/agents/\(id)") == .route(.deleteAgent(id)))
        #expect(AgentRoute.match(method: "PUT", path: "/v1/agents") == .methodNotAllowed)
        #expect(AgentRoute.match(method: "POST", path: "/v1/agents/\(id)") == .methodNotAllowed)
        #expect(AgentRoute.match(method: "GET", path: "/v1/agents/nope") == .notFound)
        let created = String(decoding: AgentHTTPResponse.error(429, "too_many_pending").encoded(), as: UTF8.self)
        #expect(created.hasPrefix("HTTP/1.1 429 Too Many Requests"))
    }

    @Test func remoteAgentDetailsRoundTripAndCapActivity() throws {
        let agent = RemoteAgentDetails.Agent(id: UUID(), name: "Grok Bot", kind: "webhook", target: "bots.example.com", async: true,
                                             followedProjects: ["mobile-app"], canSendDirectly: false, claudeCanAsk: true, registered: true)
        let activity = (0..<150).map { RemoteAgentDetails.Activity(id: UUID(), date: now, inbound: $0 % 2 == 0, agent: "Grok Bot", summary: "line \($0)", ok: true) }
        let details = RemoteAgentDetails(agents: [agent], activity: activity, apiOn: true)
        #expect(details.activity.count == RemoteAgentDetails.maxActivity && details.activity.first?.summary == "line 0")
        let message = RemoteMessage.agentDetailsAre(details)
        #expect(try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(message)) == message)
        #expect(try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(RemoteMessage.agentDetails)) == .agentDetails)
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.agentDetails))
    }

    @Test func remoteApprovalRoundTrips() throws {
        let id = UUID()
        let message = RemoteMessage.agentRegistration(agentID: id, approve: true)
        #expect(try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(message)) == message)
        var snapshot = RemoteSnapshot(hostName: "Mac", sessions: [])
        snapshot.pendingAgents = [RemotePendingAgent(id: id, name: "Bot", host: "b.example.com", description: "")]
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.pendingAgents == snapshot.pendingAgents)
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.agentApproval))
    }
}
