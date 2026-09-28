import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct DeckSyncTests {
    static let home = "/Users/me"
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// A "Mac": deck plus helpers that run the same steps as the app.
    func payload(_ deck: DeckData, at s: TimeInterval, home: String = home) -> SyncPayload {
        DeckSync.payload(from: deck, now: Self.t(s), home: home)
    }

    func merge(_ deck: DeckData, _ remote: SyncPayload, at s: TimeInterval, home: String = home) -> DeckData {
        DeckSync.merge(local: deck, remote: remote, now: Self.t(s), home: home)
    }

    func stamped(_ deck: DeckData, at s: TimeInterval) -> DeckData {
        var d = deck
        DeckSync.stamp(&d, now: Self.t(s))
        return d
    }

    // MARK: Decoding (old files must keep loading)

    @Test func legacyDeckFileWithoutNewKeysDecodes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/deck-legacy.json")
        let store = DeckDataStore(url: url)
        let deck = store.load()
        #expect(deck.projects.count == 1)
        #expect(deck.projects.first?.name == "api")
        #expect(deck.projects.first?.pinned == true)
        #expect(deck.groups.first?.name == "İş")
        #expect(deck.groups.first?.collapsed == true)
        #expect(deck.sessions.count == 1)
        #expect(deck.settings.bounceDock == false)
        #expect(deck.settings.iCloudSync == false)
        #expect(deck.syncState == DeckSyncState())
        // Decoding must not have produced a ".broken" copy.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(!siblings.contains { $0.contains("broken") })
    }

    @Test func deckWithSyncStateRoundTrips() throws {
        var deck = DeckData()
        deck.settings.iCloudSync = true
        let g = deck.addGroup(name: "G")
        deck.addProject(path: "/Users/me/a")
        deck.updateProject(deck.projects[0].id) { $0.groupID = g.id }
        deck.removeProject(deck.addProject(path: "/Users/me/gone").id)
        DeckSync.stamp(&deck, now: Self.t(0))
        let dir = FileManager.default.temporaryDirectory.appending(path: "decksync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeckDataStore(url: dir.appending(path: "deck.json"))
        try store.save(deck)
        #expect(store.load() == deck)
    }

    @Test func payloadDecodesWithMissingOptionalKeysAndRejectsNewerVersions() {
        let json = #"{"projects":[{"path":"~/x"}],"groups":[{"id":"11111111-1111-1111-1111-111111111111"}]}"#
        let p = SyncPayload.decode(Data(json.utf8))
        #expect(p?.projects.first?.name == "x")
        #expect(p?.projects.first?.pinned == false)
        #expect(p?.groups.count == 1)
        #expect(SyncPayload.decode(Data(#"{"version":99,"projects":[]}"#.utf8)) == nil)
        #expect(SyncPayload.decode(Data("garbage".utf8)) == nil)
    }

    // MARK: Payload

    @Test func payloadContainsOnlySyncedFieldsWithPortablePaths() {
        var deck = DeckData()
        let g = deck.addGroup(name: "Work")
        deck.updateGroup(g.id) { $0.collapsed = true }
        let p = deck.addProject(path: "/Users/me/code/app")
        deck.updateProject(p.id) { $0.groupID = g.id; $0.pinned = true; $0.collapsed = true }
        deck.addProject(path: "/opt/elsewhere")
        _ = deck.addSession(to: p.id)
        let payload = payload(deck, at: 0)
        #expect(payload.projects.map(\.path) == ["/opt/elsewhere", "~/code/app"])
        #expect(payload.projects[1] == SyncedProject(path: "~/code/app", name: "app", groupID: g.id, pinned: true, modifiedAt: Self.t(0)))
        #expect(payload.groups == [SyncedGroup(id: g.id, name: "Work", colorIndex: g.colorIndex, modifiedAt: Self.t(0))])
        let text = String(decoding: payload.encoded(), as: UTF8.self)
        #expect(!text.contains("collapsed"))
        #expect(!text.contains("sessions"))
    }

    @Test func payloadBytesAreCanonical() {
        var a = DeckData(), b = DeckData()
        let g1 = ProjectGroup(name: "One"), g2 = ProjectGroup(name: "Two")
        a.groups = [g1, g2]; b.groups = [g2, g1]
        a.addProject(path: "/Users/me/x"); a.addProject(path: "/Users/me/y")
        b.addProject(path: "/Users/me/y"); b.addProject(path: "/Users/me/x")
        #expect(payload(a, at: 0).encoded() == payload(b, at: 0).encoded())
    }

    @Test func stampsOnlyChangedItems() {
        var deck = DeckData()
        deck.addProject(path: "/Users/me/a")
        deck.addProject(path: "/Users/me/b")
        deck = stamped(deck, at: 0)
        deck.updateProject(deck.projects[1].id) { $0.name = "B" }
        deck.updateProject(deck.projects[0].id) { $0.collapsed = true } // not synced
        let p = payload(deck, at: 10)
        #expect(p.projects.first { $0.path == "~/a" }?.modifiedAt == Self.t(0))
        #expect(p.projects.first { $0.path == "~/b" }?.modifiedAt == Self.t(10))
    }

    // MARK: Merge

    @Test func remoteAddsMissingProjectsAndGroups() {
        var mac1 = DeckData()
        let g = mac1.addGroup(name: "Clients")
        let p = mac1.addProject(path: "/Users/me/clients/acme")
        mac1.updateProject(p.id) { $0.groupID = g.id; $0.pinned = true }

        var mac2 = DeckData()
        let own = mac2.addProject(path: "/Users/me/own")
        _ = mac2.addSession(to: own.id)
        let merged = merge(mac2, payload(mac1, at: 0), at: 5)

        #expect(merged.projects.count == 2)
        #expect(merged.projects[0].id == own.id)
        let added = merged.projects[1]
        #expect(added.path == "/Users/me/clients/acme")
        #expect(added.name == "acme")
        #expect(added.groupID == g.id)
        #expect(added.pinned == true)
        #expect(merged.groups.map(\.id) == [g.id])
        #expect(merged.groups[0].collapsed == false)
        #expect(merged.sessions == mac2.sessions)
    }

    @Test func homeRelativePathsMatchAcrossUserNames() {
        var mac1 = DeckData()
        mac1.addProject(path: "/Users/alice/code/app")
        var mac2 = DeckData()
        mac2.addProject(path: "/Users/bob/code/app")
        let merged = merge(mac2, payload(mac1, at: 0, home: "/Users/alice"), at: 1, home: "/Users/bob")
        #expect(merged.projects.map(\.path) == ["/Users/bob/code/app"])
    }

    @Test func renameConflictLastWriterWins() {
        var base = DeckData()
        base.addProject(path: "/Users/me/app")
        base = stamped(base, at: 0)
        var mac1 = base, mac2 = base
        mac1.updateProject(mac1.projects[0].id) { $0.name = "Mac1 name" }
        mac2.updateProject(mac2.projects[0].id) { $0.name = "Mac2 name" }
        mac1 = stamped(mac1, at: 10)
        mac2 = stamped(mac2, at: 20) // later edit

        let on1 = merge(mac1, payload(mac2, at: 20), at: 30)
        let on2 = merge(mac2, payload(mac1, at: 10), at: 30)
        #expect(on1.projects[0].name == "Mac2 name")
        #expect(on2.projects[0].name == "Mac2 name")
        // Local id and per-Mac fields are kept.
        #expect(on1.projects[0].id == mac1.projects[0].id)
    }

    @Test func olderRemoteEditLoses() {
        var local = DeckData()
        local.addProject(path: "/Users/me/app")
        local.updateProject(local.projects[0].id) { $0.name = "Local" }
        local = stamped(local, at: 50)
        let remote = SyncPayload(projects: [SyncedProject(path: "~/app", name: "Old", groupID: nil, pinned: true, modifiedAt: Self.t(10))])
        let merged = merge(local, remote, at: 60)
        #expect(merged.projects[0].name == "Local")
        #expect(merged.projects[0].pinned == false)
    }

    @Test func unstampedLocalEditsBeatOlderRemote() {
        // Edits made while sync was off get stamped at merge time.
        var local = DeckData()
        local.addProject(path: "/Users/me/app")
        local.updateProject(local.projects[0].id) { $0.name = "Local" }
        let remote = SyncPayload(projects: [SyncedProject(path: "~/app", name: "Remote", groupID: nil, pinned: false, modifiedAt: Self.t(10))])
        #expect(merge(local, remote, at: 60).projects[0].name == "Local")
    }

    @Test func equalStampsTieBreakDeterministically() {
        var base = DeckData()
        base.addProject(path: "/Users/me/app")
        var mac1 = base, mac2 = base
        mac1.updateProject(mac1.projects[0].id) { $0.name = "Aaa" }
        mac2.updateProject(mac2.projects[0].id) { $0.name = "Zzz" }
        let on1 = merge(mac1, payload(mac2, at: 5), at: 5)
        let on2 = merge(mac2, payload(mac1, at: 5), at: 5)
        #expect(on1.projects[0].name == on2.projects[0].name)
    }

    @Test func groupAssignmentAndGroupRenameSync() {
        var base = DeckData()
        let g = base.addGroup(name: "Old")
        base.addProject(path: "/Users/me/app")
        base = stamped(base, at: 0)
        var mac1 = base
        let g2 = mac1.addGroup(name: "New group")
        mac1.updateProject(mac1.projects[0].id) { $0.groupID = g2.id }
        mac1.updateGroup(g.id) { $0.name = "Renamed"; $0.colorIndex = 5 }

        var mac2 = base
        mac2.updateGroup(g.id) { $0.collapsed = true }
        let merged = merge(mac2, payload(mac1, at: 10), at: 20)
        #expect(merged.projects[0].groupID == g2.id)
        #expect(merged.groups.map(\.id) == [g.id, g2.id])
        #expect(merged.groups[0].name == "Renamed")
        #expect(merged.groups[0].colorIndex == 5)
        #expect(merged.groups[0].collapsed == true) // per-Mac
        #expect(merged.sections.groups[1].projects.map(\.path) == ["/Users/me/app"])
    }

    @Test func mergeIsIdempotent() {
        var mac1 = DeckData()
        mac1.addGroup(name: "G")
        mac1.addProject(path: "/Users/me/a")
        var mac2 = DeckData()
        mac2.addProject(path: "/Users/me/b")
        let remote = payload(mac1, at: 0)
        let once = merge(mac2, remote, at: 5)
        let twice = merge(once, remote, at: 9)
        #expect(once == twice)
    }

    @Test func mergeNeverDeletesLocalProjectsOrSessions() {
        var local = DeckData()
        let a = local.addProject(path: "/Users/me/a")
        let b = local.addProject(path: "/Users/me/b")
        _ = local.addSession(to: a.id)
        _ = local.addSession(to: b.id, kind: .shell)
        local.select(local.sessions[0].id)
        local = stamped(local, at: 0)
        let merged = merge(local, SyncPayload(), at: 10)
        #expect(merged == local)
        let other = merge(local, SyncPayload(projects: [SyncedProject(path: "~/c", name: "c", groupID: nil, pinned: false, modifiedAt: Self.t(5))]), at: 10)
        #expect(other.projects.prefix(2).map(\.id) == [a.id, b.id])
        #expect(other.sessions == local.sessions)
        #expect(other.selectedSessionID == local.selectedSessionID)
        #expect(other.panes == local.panes)
    }

    @Test func projectsMissingOnThisMacAreStillAdded() {
        let remote = SyncPayload(projects: [SyncedProject(path: "/Volumes/Nope/proj-\(UUID().uuidString)", name: "x", groupID: nil, pinned: false, modifiedAt: Self.t(0))])
        #expect(merge(DeckData(), remote, at: 1).projects.count == 1)
    }

    // MARK: Deletions (local tombstones)

    @Test func locallyDeletedProjectIsNotResurrectedByOlderRemote() {
        var mac1 = DeckData()
        mac1.addProject(path: "/Users/me/a")
        let remote = payload(mac1, at: 0) // file still has it
        var local = merge(DeckData(), remote, at: 1)
        #expect(local.projects.count == 1)
        local.removeProject(local.projects[0].id)
        local = stamped(local, at: 5)
        #expect(local.syncState.deletedProjects["/Users/me/a"] == Self.t(5))
        let after = merge(local, remote, at: 10)
        #expect(after.projects.isEmpty)
    }

    @Test func newerRemoteEditResurrectsDeletedProject() {
        var local = DeckData()
        local.addProject(path: "/Users/me/a")
        local = stamped(local, at: 0)
        local.removeProject(local.projects[0].id)
        local = stamped(local, at: 5)
        let remote = SyncPayload(projects: [SyncedProject(path: "~/a", name: "edited later", groupID: nil, pinned: false, modifiedAt: Self.t(20))])
        let after = merge(local, remote, at: 30)
        #expect(after.projects.map(\.name) == ["edited later"])
        #expect(after.syncState.deletedProjects.isEmpty)
    }

    @Test func reAddingLocallyClearsTombstone() {
        var local = DeckData()
        local.addProject(path: "/Users/me/a")
        local = stamped(local, at: 0)
        local.removeProject(local.projects[0].id)
        local = stamped(local, at: 5)
        local.addProject(path: "/Users/me/a")
        local = stamped(local, at: 6)
        #expect(local.syncState.deletedProjects.isEmpty)
        #expect(local.syncState.projects["/Users/me/a"]?.modifiedAt == Self.t(6))
    }

    @Test func locallyDeletedGroupIsNotResurrected() {
        var mac1 = DeckData()
        mac1.addGroup(name: "G")
        let remote = payload(mac1, at: 0)
        var local = merge(DeckData(), remote, at: 1)
        local.removeGroup(local.groups[0].id)
        local = stamped(local, at: 5)
        #expect(merge(local, remote, at: 10).groups.isEmpty)
    }

    // MARK: File-level convergence

    @Test func combineKeepsItemsDeletedHereSoMacsConverge() {
        // Mac1 deleted "a" locally; the file (written by Mac2) still has it.
        var mac2 = DeckData()
        mac2.addProject(path: "/Users/me/a")
        mac2.addProject(path: "/Users/me/b")
        let file = payload(mac2, at: 0)
        var mac1 = merge(DeckData(), file, at: 1)
        mac1.removeProject(mac1.projects[0].id)
        mac1 = stamped(mac1, at: 5)
        mac1 = merge(mac1, file, at: 6)
        let written = DeckSync.combine(payload(mac1, at: 6), file)
        // Mac1 writes back what's already there: no ping-pong.
        #expect(written.encoded() == file.encoded())
    }

    @Test func roundTripBetweenTwoMacsConverges() {
        var mac1 = DeckData()
        let g = mac1.addGroup(name: "G")
        let a = mac1.addProject(path: "/Users/me/a")
        mac1.updateProject(a.id) { $0.groupID = g.id }
        var mac2 = DeckData()
        mac2.addProject(path: "/Users/me/b")
        mac2.addGroup(name: "H")

        // The app persists stamps on every save (AppModel.saveNow → prepareSave).
        mac1 = stamped(mac1, at: 0)
        var file = DeckSync.combine(payload(mac1, at: 0), SyncPayload())
        mac2 = merge(mac2, file, at: 1)
        file = DeckSync.combine(payload(mac2, at: 1), file)
        mac1 = merge(mac1, file, at: 2)
        let final1 = DeckSync.combine(payload(mac1, at: 2), file)
        let final2 = DeckSync.combine(payload(mac2, at: 2), file)
        #expect(final1.encoded() == file.encoded())
        #expect(final2.encoded() == file.encoded())
        #expect(Set(mac1.projects.map(\.path)) == Set(mac2.projects.map(\.path)))
        #expect(Set(mac1.groups.map(\.id)) == Set(mac2.groups.map(\.id)))
        #expect(mac2.projects.first { $0.path == "/Users/me/a" }?.groupID == g.id)
        // Encoded payload decodes back to the same value.
        #expect(SyncPayload.decode(file.encoded()) == file)
    }

    // MARK: File I/O (temp directories only)

    func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "decksync-\(UUID().uuidString)/ClaudeDeck")
    }

    @Test func fileReadWriteAtomically() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let file = DeckSyncFile(folder: folder)
        #expect(file.read() == .missing)
        var deck = DeckData()
        deck.addProject(path: "/Users/me/a")
        let data = payload(deck, at: 0).encoded()
        try file.write(data)
        try file.write(data) // replacing an existing file
        #expect(file.read() == .ok(data, payload(deck, at: 0)))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(leftovers == ["projects.json"])
    }

    @Test func evictedOrBrokenFilesAreReportedNotRead() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = DeckSyncFile(folder: folder)
        try Data().write(to: folder.appending(path: ".projects.json.icloud"))
        #expect(file.read() == .notDownloaded)
        try Data("{not json".utf8).write(to: file.url)
        #expect(file.read() == .unreadable)
    }

    @Test func iCloudDriveAvailabilityUsesInjectedHome() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "decksync-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(DeckSyncFile.defaultFolder(home: home) == nil)
        try FileManager.default.createDirectory(at: DeckSyncFile.iCloudDriveRoot(home: home), withIntermediateDirectories: true)
        #expect(DeckSyncFile.defaultFolder(home: home)?.path.hasSuffix("com~apple~CloudDocs/ClaudeDeck") == true)
    }
}
