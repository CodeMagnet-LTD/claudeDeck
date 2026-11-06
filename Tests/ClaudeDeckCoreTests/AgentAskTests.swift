import Foundation
import Testing
@testable import ClaudeDeckCore

/// `claudedeck-ask`: a Claude session asking an agent by itself, with its own token.
@Suite struct AgentAskTests {
    private let allowed = AgentProfile(name: "Grok Bot", webhookURL: "https://bots.example.com/h", claudeCanAsk: true)
    private let notAllowed = AgentProfile(name: "Kod Checker", webhookURL: "https://bots.example.com/k")

    @Test func onlyASessionsOwnTokenGetsIn() {
        let a = UUID(), b = UUID()
        let tokens = [a: "token-a-0123456789", b: "token-b-0123456789"]
        #expect(AgentAsk.session(for: "Bearer token-a-0123456789", tokens: tokens) == a)
        #expect(AgentAsk.session(for: "bearer token-b-0123456789", tokens: tokens) == b)
        #expect(AgentAsk.session(for: "Bearer token-c-0123456789", tokens: tokens) == nil)
        #expect(AgentAsk.session(for: nil, tokens: tokens) == nil)
        #expect(AgentAsk.session(for: "Bearer ", tokens: tokens) == nil)
        #expect(AgentAsk.session(for: "Bearer x", tokens: [:]) == nil)
    }

    @Test func onlyAllowedApprovedAgents() throws {
        let profiles = [allowed, notAllowed]
        let pending = AgentRegistration(name: "Waiting Bot", url: "https://w.example.com", async: false, description: "")
        func code(_ name: String) -> Int? {
            if case .failure(let refusal) = AgentAsk.targets(name, profiles: profiles, registrations: [pending]) { return refusal.response.status }
            return nil
        }
        #expect(try AgentAsk.targets("grok bot", profiles: profiles, registrations: []).get() == [allowed])
        #expect(code("Kod Checker") == 403)
        #expect(code("waiting bot") == 409)
        #expect(code("Nobody") == 404)
        #expect(try AgentAsk.targets("", profiles: profiles, registrations: []).get() == [allowed])
        #expect(try AgentAsk.targets("ALL", profiles: profiles, registrations: []).get() == [allowed])
        if case .failure(let refusal) = AgentAsk.targets("all", profiles: [notAllowed], registrations: []) {
            #expect(refusal.response.status == 404)
        } else { Issue.record("all with none allowed passed") }
        #expect(AgentAsk.list(profiles) == ["Grok Bot"])
    }

    @Test func formBodyKeepsSpacesTurkishAndNewlines() throws {
        let request = "Hata yönetimine bak & şunu: a=b\nikinci satır"
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "agent", value: "Grok Bot"), URLQueryItem(name: "request", value: request)]
        // What `curl --data-urlencode` sends: + and & and = encoded.
        let body = components.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "%20", with: "+")
        let form = try #require(AgentAsk.form(Data(body.utf8)))
        #expect(form.agent == "Grok Bot")
        #expect(form.request == request)
        #expect(AgentAsk.form(Data("request=x".utf8)) == nil)
        let long = try #require(AgentAsk.form(Data(("agent=a&request=" + String(repeating: "x", count: 9000)).utf8)))
        #expect(long.request.count == AgentAsk.maxRequest)
    }

    @Test func atMostFiveAsksInTenMinutes() {
        var limiter = AgentAskLimiter()
        let session = UUID(), other = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for minute in 0..<AgentAskLimiter.maxAsks {
            let ok = limiter.allow(session, now: start.addingTimeInterval(Double(minute) * 60))
            #expect(ok)
        }
        let sixth = limiter.allow(session, now: start.addingTimeInterval(300))
        let otherSession = limiter.allow(other, now: start.addingTimeInterval(300))
        let later = limiter.allow(session, now: start.addingTimeInterval(AgentAskLimiter.window + 1))
        #expect(!sixth && otherSession && later)
    }

    @Test func profilesSavedBeforeItAreNotAllowed() throws {
        let old = #"{"id":"\#(UUID().uuidString)","name":"Old","webhookURL":"https://o.example.com"}"#
        let profile = try JSONDecoder().decode(AgentProfile.self, from: Data(old.utf8))
        #expect(!profile.claudeCanAsk)
        // Approved self-registered agents start without it, too.
        #expect(!AgentRegistration(name: "R", url: "https://r.example.com", async: false, description: "").profile.claudeCanAsk)
    }

    @Test func scriptHoldsNoSecretAndUsesTheSessionEnvironment() {
        let script = AgentAsk.script
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("$CLAUDEDECK_ASK_TOKEN") && script.contains("$CLAUDEDECK_ASK_URL"))
        #expect(script.contains("--data-urlencode \"agent=$1\""))
        #expect(!script.contains("Bearer ey") && !script.contains("47647"))
    }
}
