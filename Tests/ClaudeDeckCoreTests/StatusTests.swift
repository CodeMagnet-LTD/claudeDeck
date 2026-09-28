import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct StatusTests {
    func status(_ sid: String, _ tid: String?, _ state: SessionActivity, at t: TimeInterval, pid: Int32? = 42) -> HookStatus {
        HookStatus(sessionID: sid, terminalID: tid, pid: pid, state: state, event: "x", updatedAt: Date(timeIntervalSince1970: t))
    }

    @Test func interruptAfterRunningBecomesIdle() {
        let hook = status("s", "T", .running, at: 100)
        let r = EffectiveStatus.resolve(hook: hook, transcript: .init(kind: .interrupted, at: Date(timeIntervalSince1970: 101)), processAlive: true)
        #expect(r?.activity == .idle)
    }

    @Test func denyWhileWaitingForPermissionBecomesIdle() {
        let hook = status("s", "T", .needsPermission, at: 100)
        let r = EffectiveStatus.resolve(hook: hook, transcript: .init(kind: .toolDenied, at: Date(timeIntervalSince1970: 105)), processAlive: true)
        #expect(r?.activity == .idle)
        #expect(r?.detail?.contains("reddedildi") == true)
    }

    @Test func answeringAPermissionMeansRunningAgain() {
        let hook = status("s", "T", .needsPermission, at: 100)
        let r = EffectiveStatus.resolve(hook: hook, transcript: nil, answeredAt: Date(timeIntervalSince1970: 101), processAlive: true)
        #expect(r?.activity == .running)
        // An answer given before the prompt appeared doesn't count.
        let old = EffectiveStatus.resolve(hook: hook, transcript: nil, answeredAt: Date(timeIntervalSince1970: 99), processAlive: true)
        #expect(old?.activity == .needsPermission)
    }

    @Test func olderInterruptIsIgnored() {
        let hook = status("s", "T", .running, at: 100)
        let r = EffectiveStatus.resolve(hook: hook, transcript: .init(kind: .interrupted, at: Date(timeIntervalSince1970: 99)), processAlive: true)
        #expect(r?.activity == .running)
    }

    @Test func deadProcessIsEnded() {
        let r = EffectiveStatus.resolve(hook: status("s", "T", .running, at: 1), transcript: nil, processAlive: false)
        #expect(r?.activity == .ended)
    }

    @Test func latestFilePerTerminalWinsAfterClear() {
        let latest = StatusDirectory.latestByTerminal([
            status("old", "T", .idle, at: 10),
            status("new", "T", .running, at: 20),
            status("other", "U", .idle, at: 5),
            status("external", nil, .idle, at: 50),
        ])
        #expect(latest["T"]?.sessionID == "new")
        #expect(latest["U"]?.sessionID == "other")
        #expect(latest.count == 2)
    }

    @Test func cleanupKeepsLiveAndRecent() {
        let now = Date(timeIntervalSince1970: 100_000)
        let u = { (n: String) in URL(fileURLWithPath: "/d/\(n).json") }
        let entries: [(url: URL, status: HookStatus)] = [
            (u("live"), status("live", "A", .running, at: 1, pid: 1)),              // alive → keep even if old
            (u("superseded"), status("superseded", "B", .idle, at: 99_000, pid: 2)), // dead + superseded → delete
            (u("current"), status("current", "B", .idle, at: 99_500, pid: 2)),      // dead but current & recent → keep
            (u("stale"), status("stale", "C", .idle, at: 1, pid: 3)),               // dead + old → delete
        ]
        let deleted = StatusDirectory.filesToDelete(entries, now: now, isAlive: { $0 == 1 })
        #expect(Set(deleted.map(\.lastPathComponent)) == ["superseded.json", "stale.json"])
    }

    @Test func decodesHookOutput() throws {
        let json = #"{"session_id":"s1","terminal_id":"T","pid":123,"cwd":"/p","transcript_path":null,"state":"needsAnswer","event":"PreToolUse","detail":"Q?","tool_name":"AskUserQuestion","notification_type":null,"source":null,"updated_at":1790554934.41}"#
        let s = try HookStatus.decode(Data(json.utf8))
        #expect(s.state == .needsAnswer)
        #expect(s.pid == 123)
        #expect(s.updatedAt.timeIntervalSince1970 == 1790554934.41)
    }
}

@Suite struct TranscriptTests {
    @Test func detectsInterrupt() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"2026-09-14T22:03:22.421Z"}"#
        let s = Transcript.signal(fromLine: Substring(line))
        #expect(s?.kind == .interrupted)
        #expect(s?.at == Transcript.parseDate("2026-09-14T22:03:22.421Z"))
    }

    @Test func detectsToolDenial() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"timestamp":"2026-09-14T22:03:22Z"}"#
        #expect(Transcript.signal(fromLine: Substring(line))?.kind == .toolDenied)
    }

    @Test func ignoresAssistantQuotingTheMarker() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        #expect(Transcript.signal(fromLine: Substring(line)) == nil)
    }

    @Test func lastSignalInChunk() {
        let chunk = """
        {"type":"user","message":{"content":"[Request interrupted by user]"},"timestamp":"2026-01-01T00:00:01Z"}
        {"type":"assistant","message":{"content":[]}}
        {"type":"user","message":{"content":"[Request interrupted by user for tool use]"},"timestamp":"2026-01-01T00:00:02Z"}
        """
        #expect(Transcript.lastSignal(in: chunk)?.kind == .toolDenied)
    }

    @Test func projectDirectoryName() {
        #expect(Transcript.projectDirectoryName(for: "/Users/me/Desktop/Projects/my.app") == "-Users-me-Desktop-Projects-my-app")
        #expect(Transcript.projectDirectoryName(for: "/private/tmp/claude-501/x_y") == "-private-tmp-claude-501-x-y")
    }

    @Test func indexListsSessionsWithTitles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "deck-idx-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appending(path: Transcript.projectDirectoryName(for: "/w/app"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
        {"type":"user","isMeta":true,"message":{"content":"<command-name>x</command-name>"}}
        {"type":"user","message":{"content":"Add login screen"}}

        """.utf8).write(to: dir.appending(path: "aaa.jsonl"))
        try Data("""
        {"type":"custom-title","customTitle":"Billing work","sessionId":"bbb"}

        """.utf8).write(to: dir.appending(path: "bbb.jsonl"))
        let list = TranscriptIndex.sessions(forProject: "/w/app", root: root)
        #expect(Set(list.map(\.id)) == ["aaa", "bbb"])
        #expect(list.first { $0.id == "aaa" }?.title == "Add login screen")
        #expect(list.first { $0.id == "bbb" }?.title == "Billing work")
    }
}

@Suite struct DeckDataTests {
    @Test func sessionNamesFollowProject() throws {
        var deck = DeckData()
        let p = deck.addProject(path: "/w/monocode")
        #expect(deck.addSession(to: p.id)?.name == "monocode")
        #expect(deck.addSession(to: p.id)?.name == "monocode · 2")
        #expect(deck.addSession(to: p.id)?.name == "monocode · 3")
    }

    @Test func addingSameProjectTwiceReturnsExisting() {
        var deck = DeckData()
        let a = deck.addProject(path: "/w/app/")
        let b = deck.addProject(path: "/w/app")
        #expect(a.id == b.id)
        #expect(deck.projects.count == 1)
    }

    @Test func sectionsPinnedGroupsProjects() {
        var deck = DeckData()
        let g = deck.addGroup(name: "Clients")
        let a = deck.addProject(path: "/w/a")
        let b = deck.addProject(path: "/w/b")
        let c = deck.addProject(path: "/w/c")
        deck.updateProject(a.id) { $0.pinned = true }
        deck.updateProject(b.id) { $0.groupID = g.id }
        let s = deck.sections
        #expect(s.pinned.map(\.id) == [a.id])
        #expect(s.groups.first?.projects.map(\.id) == [b.id])
        #expect(s.ungrouped.map(\.id) == [c.id])

        deck.removeGroup(g.id)
        #expect(deck.sections.ungrouped.map(\.id) == [b.id, c.id])
    }

    @Test func removingProjectRemovesSessions() {
        var deck = DeckData()
        let p = deck.addProject(path: "/w/a")
        let s = deck.addSession(to: p.id)!
        deck.selectedSessionID = s.id
        deck.removeProject(p.id)
        #expect(deck.sessions.isEmpty)
    }

    @Test func persistsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "deck-\(UUID())/deck.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DeckDataStore(url: url)
        var deck = DeckData()
        let p = deck.addProject(path: "/w/a")
        let s = deck.addSession(to: p.id)!
        deck.updateSession(s.id) { $0.claudeSessionID = "abc" }
        deck.settings.compactThresholdKB = 123
        deck.selectedSessionID = s.id
        try store.save(deck)
        let loaded = store.load()
        // Dates survive to sub-millisecond precision; everything else exactly.
        #expect(abs(loaded.sessions[0].createdAt.timeIntervalSince(deck.sessions[0].createdAt)) < 0.001)
        var normalized = loaded
        normalized.sessions[0].createdAt = deck.sessions[0].createdAt
        #expect(normalized == deck)
    }

    @Test func panes() {
        var deck = DeckData()
        let p = deck.addProject(path: "/w/a")
        let a = deck.addSession(to: p.id)!.id, b = deck.addSession(to: p.id)!.id
        let c = deck.addSession(to: p.id)!.id, d = deck.addSession(to: p.id)!.id, e = deck.addSession(to: p.id)!.id

        deck.select(a)
        #expect(deck.panes == [a])
        let openedB = deck.openPane(b)                  // beside focused a
        #expect(openedB)
        #expect(deck.panes == [a, b] && deck.selectedSessionID == b)
        let openedC = deck.openPane(c, besideOf: a, before: true)
        #expect(openedC)
        #expect(deck.panes == [c, a, b])
        deck.select(a)                                 // visible: just focus
        #expect(deck.panes == [c, a, b] && deck.selectedSessionID == a)
        deck.select(d)                                 // not visible: replaces focused pane
        #expect(deck.panes == [c, d, b])
        let openedA = deck.openPane(a)
        #expect(openedA)
        let openedE = deck.openPane(e)                 // max 4
        #expect(!openedE)
        let moved = deck.openPane(b, besideOf: c, before: true)
        #expect(moved)
        #expect(deck.panes == [b, c, d, a])
        deck.closePane(a)                              // not focused: focus stays on b
        #expect(deck.panes == [b, c, d] && deck.selectedSessionID == b)
        deck.closePane(b)                              // focused: focus moves to its neighbour
        #expect(deck.panes == [c, d] && deck.selectedSessionID == c)
        deck.removeSession(c)
        #expect(deck.panes == [d] && deck.selectedSessionID == d)
    }

    @Test func openingBesideSingleViewKeepsCurrent() {
        var deck = DeckData()
        let p = deck.addProject(path: "/w/a")
        let a = deck.addSession(to: p.id)!.id, b = deck.addSession(to: p.id)!.id
        deck.selectedSessionID = a                     // legacy data: no panes yet
        deck.openPane(b)
        #expect(deck.panes == [a, b])
    }

    @Test func toleratesMissingKeys() throws {
        let deck = try JSONDecoder().decode(DeckData.self, from: Data(#"{"projects":[]}"#.utf8))
        #expect(deck.settings == DeckSettings())
    }
}
