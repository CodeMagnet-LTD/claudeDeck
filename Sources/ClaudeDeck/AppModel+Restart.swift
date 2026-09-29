import AppKit
import ClaudeDeckCore
import os
import SwiftUI

private let restartLog = Logger(subsystem: "ClaudeDeck", category: "restart")

/// "Restart Session": quit a session's `claude` process and start it again in the same pane,
/// resumed into the same conversation — so MCP servers, settings and CLAUDE.md changes made
/// since it started are picked up.
extension AppModel {
    enum RestartBusyPolicy {
        /// Ask before interrupting a session that is working or waiting for permission.
        case ask
        /// The user already agreed (Restart All → "Restart All").
        case force
        /// Leave busy sessions alone (Restart All → "Skip Busy Sessions").
        case skip
    }

    func canRestart(_ id: UUID?) -> Bool {
        guard let id, deck.session(id) != nil else { return false }
        return terminals.isRunning(id) && !restartingSessions.contains(id)
    }

    var restartableClaudeSessions: [DeckSession] {
        deck.sessions.filter { $0.kind == .claude && canRestart($0.id) }
    }

    /// Restarts one session. Claude sessions relaunch through `launch` (the same argument path as
    /// every other start) with `automatic: false`, so the post-resume automation (`/compact`, the
    /// "continue" message — see `afterResume`) never runs: a restart continues exactly where the
    /// conversation was, and a restart must not start a new turn on its own.
    /// Shell sessions re-run the shell and their startup command.
    /// - Parameter interactive: false for batch restarts — no dialogs; sessions that would need
    ///   one (unknown conversation id) are skipped and returned as not restarted.
    @discardableResult
    func restartSession(_ id: UUID, busy: RestartBusyPolicy = .ask, interactive: Bool = true) async -> Bool {
        guard canRestart(id), let session = deck.session(id) else { return false }
        if session.kind == .shell {
            restartingSessions.insert(id)
            defer { restartingSessions.remove(id) }
            await stopForRestart(id, graceful: false)
            launch(id, resume: false)
            return true
        }

        if SessionRestart.needsConfirmation(status(of: id).display.activityValue) {
            switch busy {
            case .skip: return false
            case .force: break
            case .ask:
                guard Confirm.ask(String(localized: "Restart \"\(session.name)\"?"),
                                  detail: String(localized: "Claude is working; restarting interrupts the current turn."),
                                  action: String(localized: "Restart")) else { return false }
            }
        }

        let plan = SessionRestart.plan(
            claudeSessionID: session.claudeSessionID,
            resumableID: deck.resumableID(for: id),
            worktreeName: session.worktreeName,
            workingDirectoryExists: session.workingDirectory.map { FileManager.default.fileExists(atPath: $0) }
        )
        switch plan {
        case .resume, .fresh:
            break
        case .continueLatest:
            // `--continue` takes the newest conversation in the folder — possibly another session's.
            guard interactive, Confirm.ask(
                String(localized: "Restart \"\(session.name)\" with the most recent conversation?"),
                detail: String(localized: "ClaudeDeck doesn't know this session's conversation yet, so it will be restarted with --continue: the most recent conversation in its folder, which may belong to another session."),
                action: String(localized: "Restart")
            ) else {
                restartLog.info("Restart of \(session.name, privacy: .public) skipped: conversation id unknown")
                return false
            }
        case .unavailable:
            restartLog.info("Restart of \(session.name, privacy: .public) skipped: worktree missing")
            if interactive {
                let alert = NSAlert()
                alert.messageText = String(localized: "Can't restart \"\(session.name)\"")
                alert.informativeText = String(localized: "The session's worktree folder no longer exists.")
                alert.runAsSheet()
            }
            return false
        }

        restartingSessions.insert(id)
        defer { restartingSessions.remove(id) }
        // Re-read: the session may have become idle (or busy) while a dialog was open.
        await stopForRestart(id, graceful: SessionRestart.exitsGracefully(status(of: id).display.activityValue))
        guard deck.session(id) != nil, !terminals.isRunning(id) else { return false }
        switch plan {
        case .resume(let sid):
            launch(id, resume: true, resumeID: sid)
        case .continueLatest:
            restartLog.info("Restarting \(session.name, privacy: .public) with --continue (conversation id unknown)")
            launch(id, resume: false, continueLatest: true)
        case .fresh:
            // The conversation had no messages yet (no transcript), so nothing is lost.
            restartLog.info("Restarting \(session.name, privacy: .public) fresh (empty conversation)")
            launch(id, resume: false)
        case .unavailable:
            return false
        }
        return true
    }

    /// Restarts every running Claude session one after another (e.g. after adding an MCP server).
    /// Busy sessions are asked about once for all of them.
    func restartAllClaudeSessions() async {
        let targets = restartableClaudeSessions
        guard !targets.isEmpty else { NSSound.beep(); return }
        let busyCount = targets.filter { SessionRestart.needsConfirmation(status(of: $0.id).display.activityValue) }.count
        var policy = RestartBusyPolicy.force
        if busyCount > 0 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Restart all Claude sessions?")
            alert.informativeText = String(localized: "\(busyCount) of \(targets.count) sessions are working; restarting interrupts their current turn.")
            alert.addButton(withTitle: String(localized: "Restart All"))
            alert.addButton(withTitle: String(localized: "Skip Busy Sessions"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            switch alert.runAsSheet() {
            case .alertFirstButtonReturn: policy = .force
            case .alertSecondButtonReturn: policy = .skip
            default: return
            }
        }
        var skipped: [String] = []
        for session in targets {
            if !(await restartSession(session.id, busy: policy, interactive: false)) { skipped.append(session.name) }
        }
        if !skipped.isEmpty {
            restartLog.info("Restart All skipped: \(skipped.joined(separator: ", "), privacy: .public)")
        }
    }

    /// Stops the process without it counting as "ended": an idle Claude is asked to `/exit`
    /// (up to 3 s), anything else — or a timeout — gets SIGTERM (SIGKILL after 5 s, see
    /// `TerminalRegistry.reap`). Returns once the old process is gone, so its late hook events
    /// can't be mistaken for the new process's.
    private func stopForRestart(_ id: UUID, graceful: Bool) async {
        if graceful {
            // Ctrl+C first clears a draft in the prompt; otherwise "/exit" would be appended to it
            // and sent to Claude as a message.
            terminals.type("\u{3}", into: id)
            try? await Task.sleep(for: .milliseconds(200))
            if terminals.isRunning(id) { terminals.type("/exit\r", into: id) }
            let deadline = ContinuousClock.now + .seconds(3)
            while terminals.isRunning(id), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard terminals.isRunning(id) else { return }
        let pid = terminals.view(for: id)?.process.shellPid ?? 0
        terminals.terminate(id)
        guard pid > 0 else { return }
        // `reap` collects the child (kill -0 fails once it's gone); give up after the SIGKILL.
        let deadline = ContinuousClock.now + .seconds(6)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// App menu items (File menu): restart the selected session (⌘⌥R) or every Claude session.
struct RestartCommands: View {
    let model: AppModel

    var body: some View {
        let selected = model.selectedSessionID
        let isShell = selected.flatMap { model.deck.session($0) }?.kind == .shell
        Button(isShell ? String(localized: "Restart Terminal") : String(localized: "Restart Session")) {
            if let selected { Task { await model.restartSession(selected) } }
        }
        .keyboardShortcut("r", modifiers: [.command, .option])
        .disabled(!model.canRestart(selected))
        Button("Restart All Claude Sessions") {
            Task { await model.restartAllClaudeSessions() }
        }
        .disabled(model.restartableClaudeSessions.isEmpty)
    }
}
