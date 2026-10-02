import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct AutomationEventTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ number: Int, _ kind: LinkedWorkItem.Kind = .issue, minutes: Double = 0, label: String? = nil, author: String = "alice") -> GitHubListItem {
        GitHubListItem(kind: kind, repo: "acme/app", number: number, title: "Item \(number)", author: author,
                       labels: label.map { [GitHubLabel(name: $0, color: nil)] } ?? [], createdAt: t0.addingTimeInterval(minutes * 60))
    }

    func deck(_ triggers: [AutomationTrigger]) -> (DeckData, UUID) {
        var deck = DeckData()
        let project = deck.addProject(path: "/tmp/acme")
        let a = Automation(name: "Triage", prompt: "Triage it.", projectID: project.id, triggers: triggers)
        deck.automations.append(a)
        return (deck, a.id)
    }

    @Test func githubTriggerRoundTripsAndUnknownKindsAreDropped() throws {
        let triggers: [AutomationTrigger] = [.github(GitHubEventTrigger(event: .pullRequestOpened, label: "bug", author: "bob")), .daily(ClockTime(hour: 8, minute: 30))]
        var a = Automation(name: "x", prompt: "p", projectID: UUID(), triggers: triggers)
        a.eventLedger.primed["github:pr:acme/app"] = t0
        a.eventLedger.claimed = ["github:pr:acme/app:1"]
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(Automation.self, from: data)
        #expect(back.triggers == triggers)
        #expect(back.eventLedger == a.eventLedger)
        #expect(String(decoding: data, as: UTF8.self).contains(#""kind":"github""#))

        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","triggers":[{"kind":"github","event":"somethingNew"},{"kind":"slack"},{"kind":"github","event":"issueOpened"}]}"#
        let decoded = try JSONDecoder().decode(Automation.self, from: Data(json.utf8))
        #expect(decoded.triggers == [.github(GitHubEventTrigger(event: .issueOpened))])
    }

    @Test func eventOnlyAutomationHasNoSchedule() {
        var a = Automation(name: "x", prompt: "p", projectID: UUID(), triggers: [.github(GitHubEventTrigger(event: .issueOpened))])
        a.reschedule(now: t0)
        #expect(a.nextRunAt == nil)
        #expect(a.isWatchingEvents)
        #expect(AutomationSchedule.evaluate(a, now: t0.addingTimeInterval(86_400)) == nil)
    }

    @Test func filtersMatchLabelAndAuthor() {
        let trigger = GitHubEventTrigger(event: .issueOpened, label: " Bug ", author: "@Alice")
        #expect(trigger.matches(item(1, label: "bug")))
        #expect(!trigger.matches(item(2, label: "docs")))
        #expect(!trigger.matches(item(3, label: "bug", author: "eve")))
        #expect(!trigger.matches(item(4, .pr, label: "bug")))
        #expect(GitHubEventTrigger(event: .pullRequestOpened, label: "", author: nil).matches(item(5, .pr)))
    }

    @Test func firstPollPrimesWithoutRunningThenNewItemsRunOnce() throws {
        var (deck, id) = deck([.github(GitHubEventTrigger(event: .issueOpened))])
        let scope = AutomationEvents.scope(.issue, repo: "acme/app")
        let existing = [item(1, minutes: -600), item(2, minutes: -1)]
        // Not primed: nothing is new.
        #expect(AutomationEvents.newEvents(for: try #require(deck.automation(id)), kind: .issue, repo: "acme/app", items: existing).isEmpty)
        deck.primeEvents(id, scope: scope, existing: existing, now: t0)
        #expect(AutomationEvents.newEvents(for: try #require(deck.automation(id)), kind: .issue, repo: "acme/app", items: existing).isEmpty)

        // Next poll: one new issue, plus an old one that slid into the list window (not new).
        let later = [item(3, minutes: 5), item(4, minutes: 3), item(0, minutes: -9000)] + existing
        let fresh = AutomationEvents.newEvents(for: try #require(deck.automation(id)), kind: .issue, repo: "acme/app", items: later)
        #expect(fresh.map(\.number) == [4, 3])   // oldest first

        let claimed = deck.claimEvent(id, item: fresh[0], now: t0.addingTimeInterval(400))
        let run = try #require(claimed)
        #expect(run.trigger == .event && run.eventKey == "github:issue:acme/app:4" && run.eventSummary == "#4 Item 4")
        let again = deck.claimEvent(id, item: fresh[0])
        #expect(again == nil)   // claimed once
        #expect(AutomationEvents.newEvents(for: try #require(deck.automation(id)), kind: .issue, repo: "acme/app", items: later).map(\.number) == [3])
        #expect(deck.automation(id)?.lastRunStatus == .pending)
    }

    @Test func primingTwiceKeepsTheFirstDate() throws {
        var (deck, id) = deck([.github(GitHubEventTrigger(event: .pullRequestOpened))])
        let scope = AutomationEvents.scope(.pr, repo: "Acme/App")
        deck.primeEvents(id, scope: scope, existing: [], now: t0)
        deck.primeEvents(id, scope: scope, existing: [], now: t0.addingTimeInterval(999))
        #expect(deck.automation(id)?.eventLedger.primed[scope] == t0)
        #expect(scope == "github:pr:acme/app")
    }

    @Test func disablingForgetsPrimingSoNoBacklogReplays() {
        var (deck, id) = deck([.github(GitHubEventTrigger(event: .issueOpened))])
        deck.primeEvents(id, scope: "github:issue:acme/app", existing: [], now: t0)
        deck.updateAutomation(id) { $0.enabled = false; $0.reschedule(now: self.t0) }
        #expect(deck.automation(id)?.eventLedger.primed.isEmpty == true)
        let run = deck.claimEvent(id, item: item(9))
        #expect(run == nil)   // not watching
    }

    @Test func ledgerIsCapped() {
        var ledger = AutomationEventLedger()
        ledger.claim((0..<(AutomationEventLedger.maxClaimed + 10)).map { "k\($0)" })
        #expect(ledger.claimed.count == AutomationEventLedger.maxClaimed)
        #expect(!ledger.isClaimed("k0") && ledger.isClaimed("k\(AutomationEventLedger.maxClaimed + 9)"))
    }

    @Test func eventPromptAppendsTheItem() {
        let prompt = AutomationEvents.prompt("  Triage this.\n", item: item(12, label: "bug"))
        #expect(prompt == "Triage this.\n\nNew issue in acme/app: #12 Item 12\nhttps://github.com/acme/app/issues/12\nOpened by @alice\nLabels: bug")
        #expect(AutomationEvents.watchedKinds(Automation(triggers: [.github(GitHubEventTrigger(event: .pullRequestOpened)), .github(GitHubEventTrigger(event: .issueOpened))])) == [.issue, .pr])
    }
}
