import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct GitHubLinkTests {
    // MARK: URL parsing

    @Test func parsesPullRequestURL() throws {
        let item = try #require(LinkedWorkItem.parse("https://github.com/cli/cli/pull/14553"))
        #expect(item.kind == .pr)
        #expect(item.repo == "cli/cli")
        #expect(item.number == 14553)
        #expect(item.url == "https://github.com/cli/cli/pull/14553")
        #expect(item.shortLabel == "PR #14553")
    }

    @Test func parsesIssueURLWithExtras() throws {
        let item = try #require(LinkedWorkItem.parse("  github.com/Owner.Name/my-repo_2/issues/34#issuecomment-1?x=1 \n"))
        #expect(item.kind == .issue)
        #expect(item.repo == "Owner.Name/my-repo_2")
        #expect(item.number == 34)
        #expect(item.url == "https://github.com/Owner.Name/my-repo_2/issues/34")
        #expect(item.shortLabel == "#34")
        let files = try #require(LinkedWorkItem.parse("https://www.github.com/a/b/pull/7/files"))
        #expect(files.kind == .pr && files.number == 7)
    }

    @Test func parsesShortForm() throws {
        let item = try #require(LinkedWorkItem.parse("octo/app#12"))
        #expect(item.kind == .issue)
        #expect(item.repo == "octo/app")
        #expect(item.number == 12)
        #expect(LinkedWorkItem.parse("octo/app#12", defaultKind: .pr)?.kind == .pr)
        #expect(LinkedWorkItem.isShortForm("octo/app#12"))
        #expect(!LinkedWorkItem.isShortForm("https://github.com/octo/app/pull/12"))
    }

    @Test func rejectsNonItems() {
        #expect(LinkedWorkItem.parse("") == nil)
        #expect(LinkedWorkItem.parse("https://github.com/cli/cli") == nil)
        #expect(LinkedWorkItem.parse("https://github.com/cli/cli/pull/0") == nil)
        #expect(LinkedWorkItem.parse("https://github.com/cli/cli/commit/abc") == nil)
        #expect(LinkedWorkItem.parse("https://gitlab.com/a/b/issues/3") == nil)
        #expect(LinkedWorkItem.parse("#12") == nil)
        #expect(LinkedWorkItem.parse("a/b#x") == nil)
        #expect(LinkedWorkItem.parse("a b/c#1") == nil)
    }

    // MARK: Persistence

    /// Same date strategy as DeckDataStore.
    static func deckDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    static func deckEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    @Test func oldDeckWithoutLinkStillDecodes() throws {
        let deck = try Self.deckDecoder().decode(DeckData.self, from: Data(WorktreeSessionTests.legacyJSON.utf8))
        let session = try #require(deck.sessions.first)
        #expect(session.linkedWorkItem == nil)
        #expect(session.claudeSessionID == "abc")
    }

    @Test func linkRoundTrips() throws {
        var deck = try Self.deckDecoder().decode(DeckData.self, from: Data(WorktreeSessionTests.legacyJSON.utf8))
        let link = LinkedWorkItem(kind: .pr, repo: "cli/cli", number: 12, lastSeenUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        deck.sessions[0].linkedWorkItem = link
        let data = try Self.deckEncoder().encode(deck)
        let back = try Self.deckDecoder().decode(DeckData.self, from: data)
        #expect(back.sessions[0].linkedWorkItem == link)
    }

    @Test func malformedLinkDoesNotBreakTheDeck() throws {
        let json = WorktreeSessionTests.legacyJSON.replacingOccurrences(
            of: "\"isOpen\": true", with: "\"isOpen\": true, \"linkedWorkItem\": { \"kind\": \"pr\" }")
        let deck = try Self.deckDecoder().decode(DeckData.self, from: Data(json.utf8))
        #expect(deck.sessions.first?.linkedWorkItem == nil)
    }

    // MARK: gh JSON (trimmed from real `gh … view --json` output)

    static let prJSON = """
    {"author":{"id":"U_1","is_bot":false,"login":"octocat","name":"Octo"},
     "body":"Fixes **the** bug.\\n\\nSee #3.",
     "comments":[
       {"id":"IC_1","author":{"login":"spammer"},"authorAssociation":"NONE","body":"buy now","createdAt":"2026-03-02T21:43:46Z","isMinimized":true,"minimizedReason":"SPAM","url":"https://github.com/o/r/pull/12#issuecomment-1"},
       {"id":"IC_2","author":{"login":"alice"},"authorAssociation":"MEMBER","body":"Looks close.","createdAt":"2026-03-03T10:00:00Z","isMinimized":false,"url":"https://github.com/o/r/pull/12#issuecomment-2"},
       {"id":"IC_3","author":{"login":"bob"},"body":"   ","createdAt":"2026-03-03T11:00:00Z","isMinimized":false}
     ],
     "headRefName":"fix-bug","isDraft":false,
     "labels":[{"id":"L_1","name":"bug","description":"","color":"d73a4a"}],
     "latestReviews":[
       {"id":"","author":{"login":"carol"},"authorAssociation":"MEMBER","body":"","submittedAt":"2026-03-03T12:00:00Z","includesCreatedEdit":false,"reactionGroups":[],"state":"APPROVED","commit":{"oid":""}}
     ],
     "mergeStateStatus":"CLEAN","number":12,"reviewDecision":"",
     "state":"OPEN",
     "statusCheckRollup":[
       {"__typename":"CheckRun","completedAt":"2026-03-03T09:00:00Z","conclusion":"SUCCESS","detailsUrl":"https://x","name":"lint","startedAt":"2026-03-03T08:59:00Z","status":"COMPLETED","workflowName":"Lint"},
       {"__typename":"CheckRun","completedAt":"2026-03-03T09:00:00Z","conclusion":"FAILURE","detailsUrl":"https://x","name":"test","startedAt":"2026-03-03T08:59:00Z","status":"COMPLETED","workflowName":"CI"},
       {"__typename":"CheckRun","completedAt":"0001-01-01T00:00:00Z","conclusion":"","detailsUrl":"https://x","name":"build","startedAt":"2026-03-03T08:59:00Z","status":"IN_PROGRESS","workflowName":"CI"},
       {"__typename":"CheckRun","completedAt":"2026-03-03T09:00:00Z","conclusion":"SKIPPED","name":"deploy","status":"COMPLETED"},
       {"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS","targetUrl":"https://y","startedAt":"2026-03-03T08:59:00Z"}
     ],
     "title":"Fix the bug","updatedAt":"2026-03-03T12:00:00Z","url":"https://github.com/o/r/pull/12"}
    """

    static let issueJSON = """
    {"author":{"login":"dave"},"body":"It crashes.","comments":[],"labels":[],"number":34,
     "state":"CLOSED","title":"Crash on launch","updatedAt":"2026-01-05T08:30:00.123Z","url":"https://github.com/o/r/issues/34"}
    """

    @Test func decodesPullRequest() throws {
        let pr = try GitHub.decodeDetails(Data(Self.prJSON.utf8), kind: .pr)
        #expect(pr.number == 12)
        #expect(pr.title == "Fix the bug")
        #expect(pr.displayState == .open)
        #expect(pr.author == "octocat")
        #expect(pr.labels == [GitHubLabel(name: "bug", color: "d73a4a")])
        #expect(pr.reviewDecision == nil)   // "" means none
        #expect(pr.headRefName == "fix-bug")
        #expect(pr.mergeStateStatus == "CLEAN")
        #expect(pr.updatedAt == Date(timeIntervalSince1970: 1_772_539_200))
        // Spam-hidden and empty comments dropped; the review is kept although its body is empty.
        #expect(pr.comments.map(\.author) == ["alice", "carol"])
        #expect(pr.comments.last?.kind == .review)
        #expect(pr.comments.last?.reviewState == "APPROVED")
        let checks = try #require(pr.checks)
        #expect(checks.passed == 2)
        #expect(checks.failed == 1)
        #expect(checks.pending == 1)
        #expect(checks.skipped == 1)
        #expect(checks.failedNames == ["test"])
        #expect(checks.outcome == .failed)
    }

    @Test func decodesIssue() throws {
        let issue = try GitHub.decodeDetails(Data(Self.issueJSON.utf8), kind: .issue)
        #expect(issue.kind == .issue)
        #expect(issue.displayState == .closed)
        #expect(issue.checks == nil)
        #expect(issue.comments.isEmpty)
        #expect(issue.author == "dave")
        #expect(abs(issue.updatedAt.timeIntervalSince1970 - 1_767_601_800.123) < 0.01)
    }

    @Test func draftAndMergedStates() throws {
        var pr = try GitHub.decodeDetails(Data(Self.prJSON.utf8), kind: .pr)
        pr.isDraft = true
        #expect(pr.displayState == .draft)
        pr.state = "MERGED"
        #expect(pr.displayState == .merged)
    }

    @Test func decodesBranchPullRequest() throws {
        let json = """
        [{"number":5,"state":"CLOSED","url":"https://github.com/o/r/pull/5"},
         {"number":9,"state":"OPEN","url":"https://github.com/o/r/pull/9"}]
        """
        let item = try #require(try GitHub.decodeBranchPullRequest(Data(json.utf8)))
        #expect(item.kind == .pr && item.number == 9 && item.repo == "o/r")
        #expect(try GitHub.decodeBranchPullRequest(Data("[]".utf8)) == nil)
    }

    // MARK: Change detection

    @Test func detectsChanges() throws {
        let old = try GitHub.decodeDetails(Data(Self.prJSON.utf8), kind: .pr)
        #expect(GitHub.changes(from: old, to: old).isEmpty)

        var merged = old
        merged.state = "MERGED"
        merged.updatedAt = old.updatedAt.addingTimeInterval(60)
        #expect(GitHub.changes(from: old, to: merged).first == .merged)

        var newComment = old
        newComment.updatedAt = old.updatedAt.addingTimeInterval(60)
        newComment.comments.append(GitHubComment(id: "IC_9", kind: .comment, author: "erin", body: "hi",
                                                  createdAt: newComment.updatedAt, url: nil, reviewState: nil))
        #expect(GitHub.changes(from: old, to: newComment) == [.newComments(count: 1, lastAuthor: "erin")])

        var review = old
        review.updatedAt = old.updatedAt.addingTimeInterval(60)
        review.reviewDecision = "CHANGES_REQUESTED"
        review.comments.append(GitHubComment(id: "review-frank-1", kind: .review, author: "frank", body: "no",
                                             createdAt: review.updatedAt, url: nil, reviewState: "CHANGES_REQUESTED"))
        #expect(GitHub.changes(from: old, to: review) == [.changesRequested])

        var green = old
        green.checks = GitHubChecks(passed: 4)
        #expect(GitHub.changes(from: old, to: green) == [.ciPassed])
        #expect(GitHub.changes(from: green, to: old) == [.ciFailed])

        var touched = old
        touched.updatedAt = old.updatedAt.addingTimeInterval(5)
        #expect(GitHub.changes(from: old, to: touched) == [.updated])
    }
}
