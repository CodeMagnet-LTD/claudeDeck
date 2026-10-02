import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct WorkspaceTabListTests {
    private let a = WorkspaceTab.file(URL(fileURLWithPath: "/p/a.swift"))
    private let b = WorkspaceTab.file(URL(fileURLWithPath: "/p/b.swift"))
    private let c = WorkspaceTab.file(URL(fileURLWithPath: "/p/c.swift"))
    private let d = WorkspaceTab.diff(repo: "/p", path: "a.swift", staged: false)

    @Test func startsWithSessionsOnly() {
        let list = WorkspaceTabList()
        #expect(list.tabs == [.sessions])
        #expect(list.isSessionsSelected)
    }

    @Test func openingSelectsAndReopeningDoesNotDuplicate() {
        var list = WorkspaceTabList()
        list.open(a)
        list.open(b)
        #expect(list.tabs == [.sessions, a, b])
        #expect(list.selected == b)
        list.open(a)
        #expect(list.tabs == [.sessions, a, b])
        #expect(list.selected == a)
        list.open(.sessions)
        #expect(list.tabs.count == 3 && list.isSessionsSelected)
    }

    @Test func opensNextToTheSelectedTab() {
        var list = WorkspaceTabList()
        list.open(a)
        list.open(b)
        list.select(a)
        list.open(c)
        #expect(list.tabs == [.sessions, a, c, b])
    }

    @Test func previewIsReplacedInPlaceUntilPinned() {
        var list = WorkspaceTabList()
        list.open(a)
        list.open(b, preview: true)
        list.open(.automations)
        list.open(d, preview: true)
        #expect(list.tabs == [.sessions, a, d, .automations])
        #expect(list.preview == d && list.selected == d)
        list.pin(d)
        list.open(c, preview: true)
        #expect(list.tabs == [.sessions, a, d, c, .automations])
        #expect(list.preview == c)
        // A permanent open of the preview tab pins it; a preview open of a normal tab just selects it.
        list.open(a, preview: true)
        #expect(list.preview == c && list.selected == a)
        list.open(c)
        #expect(list.preview == nil && list.selected == c)
    }

    @Test func closingSelectsTheNeighbour() {
        var list = WorkspaceTabList()
        list.open(a)
        list.open(b)
        list.open(c)
        list.select(b)
        list.close(b)
        #expect(list.tabs == [.sessions, a, c] && list.selected == c)
        list.close(c)
        #expect(list.selected == a)
        list.close(.sessions)
        #expect(list.tabs == [.sessions, a])
        list.close(a)
        #expect(list.tabs == [.sessions] && list.isSessionsSelected)
    }

    @Test func closingTheSelectedPreviewClearsIt() {
        var list = WorkspaceTabList()
        list.open(a, preview: true)
        list.close(a)
        #expect(list.preview == nil)
        list.open(b, preview: true)
        #expect(list.tabs == [.sessions, b])
    }

    @Test func othersAndRightNeverIncludeSessions() {
        var list = WorkspaceTabList()
        list.open(a)
        list.open(b)
        list.open(c)
        #expect(list.others(than: b) == [a, c])
        #expect(list.others(than: .sessions) == [a, b, c])
        #expect(list.tabsToTheRight(of: a) == [b, c])
        #expect(list.tabsToTheRight(of: c).isEmpty)
    }

    @Test func reorderKeepsSessionsFirst() {
        var list = WorkspaceTabList()
        list.open(a)
        list.open(b)
        list.open(c)
        list.move(c, to: a)
        #expect(list.tabs == [.sessions, c, a, b])
        list.move(a, to: .sessions)
        #expect(list.tabs == [.sessions, a, c, b])
        list.move(.sessions, to: b)
        #expect(list.tabs.first == .sessions)
        list.move(a, to: b)
        #expect(list.tabs == [.sessions, c, b, a])
    }

    @Test func commandNumbers() {
        var list = WorkspaceTabList()
        #expect(list.tab(forCommandNumber: 1) == .sessions)
        #expect(list.tab(forCommandNumber: 2) == nil)
        #expect(list.tab(forCommandNumber: 9) == .sessions)
        list.open(a)
        list.open(b)
        #expect(list.tab(forCommandNumber: 2) == a)
        #expect(list.tab(forCommandNumber: 3) == b)
        #expect(list.tab(forCommandNumber: 4) == nil)
        #expect(list.tab(forCommandNumber: 9) == b)
        #expect(list.tab(forCommandNumber: 0) == nil)
    }

    @Test func neighbourSelectionWraps() {
        var list = WorkspaceTabList()
        list.selectNeighbour(forward: true)
        #expect(list.isSessionsSelected)
        list.open(a)
        list.open(b)
        list.selectNeighbour(forward: true)
        #expect(list.isSessionsSelected)
        list.selectNeighbour(forward: false)
        #expect(list.selected == b)
    }

    @Test func restoreDropsDiffsAndMissingFiles() throws {
        var list = WorkspaceTabList()
        list.open(a)
        list.open(.automations)
        list.open(b, preview: true)
        list.open(d)
        let data = try JSONEncoder().encode(list.persistable)
        let decoded = try JSONDecoder().decode(WorkspaceTabList.self, from: data)
        let restored = decoded.restored { $0.lastPathComponent != "a.swift" }
        #expect(restored.tabs == [.sessions, .automations, b])
        #expect(restored.isSessionsSelected) // the diff was selected
        #expect(restored.preview == b)

        list.select(a)
        let gone = try JSONDecoder().decode(WorkspaceTabList.self, from: JSONEncoder().encode(list.persistable))
            .restored { _ in false }
        #expect(gone.tabs == [.sessions, .automations] && gone.isSessionsSelected && gone.preview == nil)
    }

    @Test func decodesGarbageTolerantly() throws {
        let list = try JSONDecoder().decode(WorkspaceTabList.self, from: Data(#"{"tabs":[{"automations":{}}]}"#.utf8))
        #expect(list.tabs == [.sessions, .automations])
        #expect(list.isSessionsSelected)
        let empty = try JSONDecoder().decode(WorkspaceTabList.self, from: Data("{}".utf8))
        #expect(empty.tabs == [.sessions])
    }

    @Test func inboxTabPersists() throws {
        var list = WorkspaceTabList()
        list.open(.inbox)
        let back = try JSONDecoder().decode(WorkspaceTabList.self, from: JSONEncoder().encode(list.persistable))
        #expect(back.tabs == [.sessions, .inbox] && back.selected == .inbox)
    }

    @Test func oldSettingsDecodeWithTabsDefault() throws {
        let json = #"{"settings":{"openFilesInBuiltInEditor":true}}"#
        let deck = try JSONDecoder().decode(DeckData.self, from: Data(json.utf8))
        #expect(deck.settings.openFilesInSeparateWindow == false)
        var settings = DeckSettings()
        settings.openFilesInSeparateWindow = true
        let round = try JSONDecoder().decode(DeckSettings.self, from: JSONEncoder().encode(settings))
        #expect(round.openFilesInSeparateWindow == true)
    }
}
