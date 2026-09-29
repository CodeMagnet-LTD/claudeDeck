import Foundation

/// How "Restart Session" brings a running Claude session back after stopping its process
/// (so new MCP servers, settings and CLAUDE.md changes are picked up).
public enum RestartPlan: Equatable, Sendable {
    /// `--resume <id>`: the same conversation.
    case resume(String)
    /// The conversation id is known but has no transcript yet (nothing was sent): a fresh start
    /// loses nothing. Still confirmed by the user.
    case fresh
    /// The conversation id is unknown (no hook event yet): `--continue` picks the most recent
    /// conversation in the working directory, which may belong to another session — confirmed.
    case continueLatest
    /// A worktree session whose worktree is gone: there is nothing sensible to restart into.
    case unavailable
}

public enum SessionRestart {
    /// - Parameters:
    ///   - claudeSessionID: the id the hook reported for the running conversation.
    ///   - resumableID: `DeckData.resumableID(for:)` — the id, if its transcript exists.
    ///   - worktreeName: set for worktree sessions.
    ///   - workingDirectoryExists: whether the session's worktree directory exists (nil if it has none).
    public static func plan(claudeSessionID: String?, resumableID: String?, worktreeName: String?,
                            workingDirectoryExists: Bool?) -> RestartPlan {
        // Without its directory `launch` would create a new worktree (`--worktree`), not restart.
        if worktreeName != nil, workingDirectoryExists != true { return .unavailable }
        if workingDirectoryExists == false { return .unavailable }
        if let resumableID { return .resume(resumableID) }
        return claudeSessionID == nil ? .continueLatest : .fresh
    }

    /// Restarting interrupts the current turn (or an open prompt): ask first.
    public static func needsConfirmation(_ activity: SessionActivity?) -> Bool {
        guard let activity else { return false }
        return activity == .running || activity.isBlocked
    }

    /// Only an idle TUI is asked to quit via `/exit`; anything else is terminated.
    public static func exitsGracefully(_ activity: SessionActivity?) -> Bool { activity == .idle }
}
