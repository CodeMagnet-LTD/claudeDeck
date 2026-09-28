import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct WorktreeSessionTests {
    static let projectID = "11111111-1111-1111-1111-111111111111"
    static let sessionID = "22222222-2222-2222-2222-222222222222"

    /// deck.json as written by a version without `kind`, `worktreeName`, `workingDirectory`.
    static let legacyJSON = """
    {
      "version": 1,
      "groups": [],
      "projects": [{ "id": "\(projectID)", "path": "/tmp/app", "name": "app", "pinned": false, "collapsed": false }],
      "sessions": [{
        "id": "\(sessionID)", "projectID": "\(projectID)", "name": "app",
        "claudeSessionID": "abc", "createdAt": 1700000000, "isOpen": true
      }],
      "settings": { "resumeOnLaunch": true },
      "panes": []
    }
    """

    func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    @Test func decodesLegacyFileWithoutWorktreeKeys() throws {
        let deck = try decoder().decode(DeckData.self, from: Data(Self.legacyJSON.utf8))
        #expect(deck.projects.count == 1)
        let session = try #require(deck.sessions.first)
        #expect(session.kind == .claude)
        #expect(session.worktreeName == nil)
        #expect(session.workingDirectory == nil)
        #expect(session.claudeSessionID == "abc")
    }

    @Test func roundTripsWorktreeFields() throws {
        var deck = DeckData()
        let project = deck.addProject(path: "/tmp/app")
        let added = deck.addWorktreeSession(to: project.id, worktreeName: "app-2"); let session = try #require(added)
        deck.updateSession(session.id) { $0.workingDirectory = "/tmp/app/.claude/worktrees/app-2" }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoded = try decoder().decode(DeckData.self, from: encoder.encode(deck))
        #expect(decoded.sessions.first?.worktreeName == "app-2")
        #expect(decoded.sessions.first?.workingDirectory == "/tmp/app/.claude/worktrees/app-2")
        #expect(decoded.sessions.first?.name == "app · app-2")
    }

    @Test func worktreeNameValidation() {
        for ok in ["app-2", "feature_x", "v1.2", "A.b-C_9"] { #expect(DeckData.isValidWorktreeName(ok), "\(ok)") }
        for bad in ["", "-x", ".x", "a..b", "a b", "a/b", "ş", "x.", "x.lock", "a~b", "a:b"] {
            #expect(!DeckData.isValidWorktreeName(bad), "\(bad)")
        }
    }

    @Test func nextWorktreeNameSkipsTaken() throws {
        var deck = DeckData()
        let project = deck.addProject(path: "/tmp/My App")
        #expect(deck.nextWorktreeName(for: project) == "My-App-2")
        deck.addWorktreeSession(to: project.id, worktreeName: "My-App-2")
        #expect(deck.nextWorktreeName(for: project) == "My-App-3")
        #expect(deck.nextWorktreeName(for: project, existing: ["My-App-3"]) == "My-App-4")
        #expect(DeckData.isValidWorktreeName(deck.nextWorktreeName(for: project)))
        let weird = deck.addProject(path: "/tmp/.çğ")
        #expect(DeckData.isValidWorktreeName(deck.nextWorktreeName(for: weird)))
    }

    @Test func resumableIDUsesWorkingDirectory() throws {
        var deck = DeckData()
        let project = deck.addProject(path: "/tmp/app")
        let added = deck.addWorktreeSession(to: project.id, worktreeName: "app-2"); let session = try #require(added)
        let wd = "/tmp/app/.claude/worktrees/app-2"
        deck.updateSession(session.id) {
            $0.claudeSessionID = "sid"
            $0.workingDirectory = wd
        }
        let expected = TranscriptIndex.defaultRoot()
            .appending(path: Transcript.projectDirectoryName(for: wd)).appending(path: "sid.jsonl").path
        #expect(deck.resumableID(for: session.id) { $0 == wd || $0 == expected } == "sid")
        // Transcript path derived from the project folder doesn't count.
        #expect(deck.resumableID(for: session.id) { $0 == wd } == nil)
        // Worktree folder deleted: not resumable even if the transcript is still there.
        #expect(deck.resumableID(for: session.id) { $0 == expected } == nil)
        // A stored transcript path from hooks wins.
        deck.updateSession(session.id) { $0.transcriptPath = "/t/sid.jsonl" }
        #expect(deck.resumableID(for: session.id) { $0 == wd || $0 == "/t/sid.jsonl" } == "sid")
    }
}
