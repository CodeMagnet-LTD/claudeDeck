import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct SessionRestartTests {
    @Test func resumesKnownConversation() {
        #expect(SessionRestart.plan(claudeSessionID: "abc", resumableID: "abc", worktreeName: nil, workingDirectoryExists: nil) == .resume("abc"))
        #expect(SessionRestart.plan(claudeSessionID: "abc", resumableID: "abc", worktreeName: "wt", workingDirectoryExists: true) == .resume("abc"))
    }

    @Test func emptyConversationStartsFresh() {
        #expect(SessionRestart.plan(claudeSessionID: "abc", resumableID: nil, worktreeName: nil, workingDirectoryExists: nil) == .fresh)
    }

    @Test func unknownConversationFallsBackToContinue() {
        #expect(SessionRestart.plan(claudeSessionID: nil, resumableID: nil, worktreeName: nil, workingDirectoryExists: nil) == .continueLatest)
        #expect(SessionRestart.plan(claudeSessionID: nil, resumableID: nil, worktreeName: "wt", workingDirectoryExists: true) == .continueLatest)
    }

    @Test func missingWorktreeIsUnavailable() {
        // Never `--worktree` + `--continue`: that would create a new worktree instead of restarting.
        #expect(SessionRestart.plan(claudeSessionID: nil, resumableID: nil, worktreeName: "wt", workingDirectoryExists: nil) == .unavailable)
        #expect(SessionRestart.plan(claudeSessionID: "abc", resumableID: nil, worktreeName: "wt", workingDirectoryExists: false) == .unavailable)
    }

    @Test func confirmationOnlyWhenBusy() {
        #expect(SessionRestart.needsConfirmation(.running))
        #expect(SessionRestart.needsConfirmation(.needsPermission))
        #expect(SessionRestart.needsConfirmation(.needsAnswer))
        #expect(!SessionRestart.needsConfirmation(.idle))
        #expect(!SessionRestart.needsConfirmation(nil))
        #expect(SessionRestart.exitsGracefully(.idle))
        #expect(!SessionRestart.exitsGracefully(.running))
        #expect(!SessionRestart.exitsGracefully(nil))
    }
}
