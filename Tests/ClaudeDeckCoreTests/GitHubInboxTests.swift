import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct GitHubInboxTests {
    @Test func decodesIssueAndPullRequestLists() throws {
        let json = """
        [{"number":7,"title":"Crash on start","author":{"login":"alice"},"labels":[{"name":"bug","color":"d73a4a"}],
          "createdAt":"2026-01-02T10:00:00Z","updatedAt":"2026-01-03T10:00:00Z","url":"https://github.com/acme/app/issues/7"},
         {"number":5,"title":"Docs","author":null,"labels":[],"createdAt":"2026-01-01T10:00:00Z","url":"https://github.com/acme/app/issues/5"}]
        """
        let items = try GitHub.decodeList(Data(json.utf8), kind: .issue, repo: "acme/app")
        #expect(items.count == 2)
        #expect(items[0].number == 7 && items[0].author == "alice" && items[0].labels.map(\.name) == ["bug"])
        #expect(items[1].author == nil && items[1].updatedAt == items[1].createdAt)
        #expect(items[0].workItem == LinkedWorkItem(kind: .issue, repo: "acme/app", number: 7))

        let prs = try GitHub.decodeList(Data(#"[{"number":3,"title":"Add X","isDraft":true,"createdAt":"2026-01-02T10:00:00.123Z"}]"#.utf8), kind: .pr, repo: "acme/app")
        #expect(prs[0].isDraft && prs[0].url == "https://github.com/acme/app/pull/3")
        #expect(prs[0].workPrompt == "Work on this GitHub pull request: #3 Add X\nhttps://github.com/acme/app/pull/3")
    }

    @Test func parsesActionsIDsFromCheckURLs() {
        let check = GitHubFailedCheck(name: "test", workflowName: "CI", detailsURL: "https://github.com/acme/app/actions/runs/123456/job/789?pr=4")
        #expect(check.runID == 123456 && check.jobID == 789)
        #expect(check.canRepair)
        #expect(check.displayName == "CI / test")
        let runOnly = GitHubFailedCheck(name: "lint", detailsURL: "https://github.com/acme/app/actions/runs/42")
        #expect(runOnly.runID == 42 && runOnly.jobID == nil)
        let external = GitHubFailedCheck(name: "ci/circleci", detailsURL: "https://circleci.com/gh/acme/app/1")
        #expect(!external.canRepair && external.displayName == "ci/circleci")
        #expect(CIRepair.key(repo: "Acme/App", number: 4, check: check) == "acme/app#4:job-789")
    }

    @Test func failedChecksComeFromStatusCheckRollup() throws {
        let json = """
        {"number":4,"title":"T","state":"OPEN","updatedAt":"2026-01-01T00:00:00Z","url":"https://github.com/acme/app/pull/4",
         "statusCheckRollup":[
          {"__typename":"CheckRun","name":"build","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE",
           "detailsUrl":"https://github.com/acme/app/actions/runs/10/job/11"},
          {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/acme/app/actions/runs/10/job/12"},
          {"__typename":"StatusContext","context":"deploy","state":"ERROR","targetUrl":"https://example.com/d/1"}]}
        """
        let details = try GitHub.decodeDetails(Data(json.utf8), kind: .pr)
        let checks = try #require(details.checks)
        #expect(checks.failed == 2 && checks.passed == 1)
        #expect(checks.failedChecks.map(\.name) == ["build", "deploy"])
        #expect(checks.failedChecks[0].jobID == 11 && checks.failedChecks[0].workflowName == "CI")
        #expect(!checks.failedChecks[1].canRepair)
    }

    @Test func trimsFailedLogs() {
        let log = (1...50).map { "build\tRun tests\t2026-01-01T00:00:0\($0 % 10).1234567Z \u{1B}[31mline \($0)\u{1B}[0m" }.joined(separator: "\n") + "\n\n"
        let full = CIRepair.trimLog(log)
        #expect(full.hasPrefix("line 1\nline 2"))
        #expect(full.hasSuffix("line 50"))
        let tail = CIRepair.trimLog(log, maxCharacters: 30)
        #expect(tail.hasPrefix("…(earlier log lines omitted)\n"))
        #expect(tail.hasSuffix("line 49\nline 50"))
        #expect(!tail.contains("line 1\n"))
        // One huge line still yields its tail.
        #expect(CIRepair.trimLog(String(repeating: "x", count: 100), maxCharacters: 10) == String(repeating: "x", count: 10))
    }

    @Test func repairPromptNamesTheCheckAndLog() {
        let check = GitHubFailedCheck(name: "test", workflowName: "CI", detailsURL: "https://github.com/acme/app/actions/runs/1/job/2")
        let prompt = CIRepair.prompt(repo: "acme/app", number: 4, branch: "feature", check: check, log: "boom")
        #expect(prompt.contains("\"CI / test\" failed on pull request #4 (acme/app), branch feature"))
        #expect(prompt.contains("```\nboom\n```"))
    }

    @Test func repairLedgerReplacesAndCaps() {
        var deck = DeckData()
        deck.recordCIRepair(CIRepairRequest(key: "a"))
        deck.recordCIRepair(CIRepairRequest(key: "a"))
        #expect(deck.ciRepairRequests.count == 1)
        for i in 0..<(CIRepair.maxRequests + 5) { deck.recordCIRepair(CIRepairRequest(key: "k\(i)")) }
        #expect(deck.ciRepairRequests.count == CIRepair.maxRequests)
        #expect(deck.ciRepairRequest("a") == nil)
        #expect(deck.ciRepairRequest("k\(CIRepair.maxRequests + 4)") != nil)
    }

    @Test func oldDeckWithoutNewFieldsDecodes() throws {
        let json = #"{"version":1,"projects":[],"sessions":[],"automations":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","triggers":[{"kind":"time","schedule":"daily","hour":9,"minute":0}]}],"automationRuns":[{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","automationID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","trigger":"scheduled","status":"succeeded"}]}"#
        let deck = try JSONDecoder().decode(DeckData.self, from: Data(json.utf8))
        #expect(deck.ciRepairRequests.isEmpty)
        #expect(deck.automations[0].eventLedger == AutomationEventLedger())
        #expect(deck.automationRuns[0].eventKey == nil)
        // A broken ledger entry doesn't lose the deck.
        let broken = #"{"ciRepairRequests":[{"key":"x","requestedAt":0},{"nope":1}]}"#
        #expect(try JSONDecoder().decode(DeckData.self, from: Data(broken.utf8)).ciRepairRequests.map(\.key) == ["x"])
    }
}
