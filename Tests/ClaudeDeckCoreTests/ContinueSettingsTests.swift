import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct ContinueSettingsTests {
    func settings(_ json: String) throws -> DeckSettings {
        try JSONDecoder().decode(DeckSettings.self, from: Data(json.utf8))
    }

    @Test func defaultsDoNotTypeIntoIdleSessions() throws {
        let s = try settings("{}")
        #expect(s.continueAllOnResume == false)
        #expect(s.compactOnResume == false)
    }

    @Test func legacyContinueEverySessionMigrates() throws {
        #expect(try settings(#"{"continueAfterResume": true, "continueOnlyIfBusy": false}"#).continueAllOnResume)
    }

    @Test func legacyBusyOnlyStaysOffForIdleSessions() throws {
        // Busy sessions now always continue; "only busy" must not turn into "everyone".
        #expect(try settings(#"{"continueAfterResume": true, "continueOnlyIfBusy": true}"#).continueAllOnResume == false)
        #expect(try settings(#"{"continueAfterResume": false, "continueOnlyIfBusy": false}"#).continueAllOnResume == false)
    }

    @Test func newKeyWins() throws {
        #expect(try settings(#"{"continueAllOnResume": false, "continueAfterResume": true, "continueOnlyIfBusy": false}"#).continueAllOnResume == false)
    }
}
