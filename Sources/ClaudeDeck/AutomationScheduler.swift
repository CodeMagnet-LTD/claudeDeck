import AppKit
import ClaudeDeckCore
import Foundation

/// Starts automations: checks every 30 s (and on wake) for due schedules, claims them in the deck
/// (advancing `nextRunAt` first, so an occurrence never runs twice), then runs the prompt in a
/// Claude session and follows it until Claude is done. Only runs while the app is running.
@MainActor
final class AutomationScheduler {
    private unowned let model: AppModel
    private var timer: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// Runs being driven by this process (run id → task).
    private var active: [UUID: Task<Void, Never>] = [:]

    static let tickInterval: Duration = .seconds(30)
    /// How long a new / resumed session may take to show its prompt.
    static let startupTimeout: Duration = .seconds(180)
    /// A run still not finished after this long is marked failed (the session keeps running).
    static let runTimeout: Duration = .seconds(12 * 3600)

    init(model: AppModel) {
        self.model = model
        // Runs a previous app process left open can't be followed any more.
        if model.deck.automationRuns.contains(where: { !$0.status.isFinished }) {
            model.mutate { $0.recoverInterruptedRuns() }
        }
        // Old/stale schedules (e.g. created before a long quit) are evaluated on the first tick;
        // automations that never got a nextRunAt get one now.
        let unscheduled = model.deck.automations.filter { $0.isSchedulable && $0.nextRunAt == nil }
        if !unscheduled.isEmpty {
            model.mutate { deck in for a in unscheduled { deck.updateAutomation(a.id) { $0.reschedule() } } }
        }
    }

    /// Starts the 30 s timer and the wake check. Call once `claude` has been resolved.
    func start() {
        guard timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Claims and starts every due automation.
    func tick(now: Date = Date()) {
        for automation in model.deck.automations {
            guard let expected = automation.nextRunAt,
                  let decision = AutomationSchedule.evaluate(automation, now: now) else { continue }
            var claimed: AutomationRun?
            model.mutate { claimed = $0.claimDue(automation.id, expected: expected, decision: decision, now: now) }
            guard let run = claimed, run.status == .pending else { continue }
            execute(run: run, automationID: automation.id, reveal: false)
        }
    }

    /// "Run Now": runs regardless of the schedule (and of `enabled`), and shows the session.
    func runNow(_ automationID: UUID) {
        guard let automation = model.deck.automation(automationID), automation.projectID != nil,
              !automation.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        if model.deck.runs(of: automationID).contains(where: { !$0.status.isFinished }) { NSSound.beep(); return }
        let run = AutomationRun(automationID: automationID, trigger: .manual)
        model.mutate {
            $0.appendRun(run)
            $0.updateAutomation(automationID) { $0.lastRunAt = run.startedAt; $0.lastRunStatus = .pending }
        }
        execute(run: run, automationID: automationID, reveal: true)
    }

    func isActive(_ automationID: UUID) -> Bool {
        model.deck.runs(of: automationID).contains { !$0.status.isFinished }
    }

    /// Stops following a run (the session itself keeps going).
    func cancel(_ runID: UUID) {
        active[runID]?.cancel()
        finish(runID, .cancelled, error: String(localized: "Cancelled"))
    }

    // MARK: Execution

    private func execute(run: AutomationRun, automationID: UUID, reveal: Bool) {
        active[run.id] = Task { @MainActor [weak self] in
            await self?.perform(runID: run.id, automationID: automationID, reveal: reveal)
            self?.active[run.id] = nil
        }
    }

    private func perform(runID: UUID, automationID: UUID, reveal: Bool) async {
        guard let automation = model.deck.automation(automationID),
              let projectID = automation.projectID, model.deck.project(projectID) != nil else {
            return finish(runID, .failed, error: String(localized: "The project no longer exists."))
        }
        // Session: the last run's (if asked and it's free), else a new one.
        var sessionID: UUID?
        var needsLaunch = true
        if automation.reuseSession, let last = automation.lastSessionID, let session = model.deck.session(last), session.kind == .claude {
            if model.terminals.isRunning(last) {
                guard model.status(of: last).display.isIdle else {
                    return finish(runID, .skipped, error: String(localized: "The session is busy."))
                }
                needsLaunch = false
            }
            sessionID = last
        }
        if sessionID == nil { sessionID = createSession(for: automation, projectID: projectID) }
        guard let sessionID else { return finish(runID, .failed, error: String(localized: "Could not create a session.")) }

        model.mutate { deck in
            deck.updateRun(runID) {
                $0.sessionID = sessionID
                $0.status = .running
            }
        }
        if reveal {
            model.openMainWindow?()
            model.reveal(sessionID)
        }

        if needsLaunch {
            let launchedAt = Date()
            model.launch(sessionID, resume: automation.reuseSession)
            guard model.terminals.isRunning(sessionID) else {
                return finish(runID, .failed, error: String(localized: "Claude could not be started."))
            }
            guard await waitForIdle(sessionID, after: launchedAt, timeout: Self.startupTimeout, acceptAny: true) == .idle else {
                return finish(runID, .failed, error: String(localized: "Claude did not become ready."))
            }
            // Let the TUI finish drawing its input box.
            try? await Task.sleep(for: .seconds(1))
        }
        guard !Task.isCancelled else { return }

        let sentAt = Date()
        send(automation.prompt, to: sessionID)
        switch await waitForIdle(sessionID, after: sentAt, timeout: Self.runTimeout, acceptAny: false) {
        case .idle: finish(runID, .succeeded)
        case .failed(let detail): finish(runID, .failed, error: detail)
        case .exited: finish(runID, .failed, error: String(localized: "The session ended before Claude finished."))
        case .timedOut: finish(runID, .failed, error: String(localized: "Timed out waiting for Claude to finish."))
        case .cancelled: return
        }
    }

    /// A new `.claude` session named after the automation (in a fresh worktree if configured).
    private func createSession(for automation: Automation, projectID: UUID) -> UUID? {
        guard let project = model.deck.project(projectID) else { return nil }
        let base = "\(project.name) · \(automation.name.isEmpty ? String(localized: "Automation") : String(automation.name.prefix(30)))"
        let taken = Set(model.deck.sessions(in: projectID).map(\.name))
        var name = base
        var n = 2
        while taken.contains(name) { name = "\(base) \(n)"; n += 1 }

        var created: DeckSession?
        if automation.workspace == .newWorktree, model.isGitRepository(project) {
            let worktree = worktreeName(for: automation, project: project)
            model.mutate { deck in
                created = deck.addWorktreeSession(to: projectID, worktreeName: worktree)
                if let id = created?.id { deck.updateSession(id) { $0.name = name } }
            }
        } else {
            model.mutate { created = $0.addSession(to: projectID, name: name) }
        }
        return created?.id
    }

    /// "auto-<name>-<yyyyMMdd-HHmm>" when valid, else the project's next default worktree name.
    private func worktreeName(for automation: Automation, project: Project) -> String {
        let slug = String(automation.name.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-"
        }).split(separator: "-").joined(separator: "-").prefix(40)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let candidate = slug.isEmpty ? "auto-\(stamp)" : "auto-\(slug)-\(stamp)"
        let dir = URL(fileURLWithPath: project.path).appending(path: ".claude/worktrees/\(candidate)").path
        let clash = model.deck.sessions(in: project.id).contains { $0.worktreeName == candidate } || FileManager.default.fileExists(atPath: dir)
        return DeckData.isValidWorktreeName(candidate) && !clash ? candidate : model.defaultWorktreeName(for: project)
    }

    /// Types the prompt like the user would. Multi-line prompts go in as a bracketed paste so their
    /// newlines don't submit early; Enter follows once the paste has landed.
    private func send(_ prompt: String, to id: UUID) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains(where: \.isNewline) {
            model.terminals.type("\u{1B}[200~" + text + "\u{1B}[201~", into: id)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.model.terminals.type("\r", into: id)
            }
        } else {
            model.terminals.type(text + "\r", into: id)
        }
    }

    private enum WaitResult: Equatable { case idle, failed(String), exited, timedOut, cancelled }

    /// Polls the hook status until Claude is idle after `after`. `acceptAny`: any idle event counts
    /// (startup); otherwise only a finished turn (`Stop`). Blocked states (permission prompts)
    /// simply keep waiting — they surface in Needs Attention like any other session.
    private func waitForIdle(_ id: UUID, after: Date, timeout: Duration, acceptAny: Bool) async -> WaitResult {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return .cancelled }
            guard model.terminals.isRunning(id) else { return .exited }
            if let hook = model.hookStatuses[id], hook.updatedAt > after {
                if hook.state == .ended { return .exited }
                if hook.state == .idle {
                    if acceptAny { return .idle }
                    if hook.event == "Stop" { return .idle }
                    if hook.event == "StopFailure" { return .failed(hook.detail ?? String(localized: "Claude stopped with an error.")) }
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return .timedOut
    }

    private func finish(_ runID: UUID, _ status: AutomationRunStatus, error: String? = nil) {
        guard let run = model.deck.automationRuns.first(where: { $0.id == runID }), !run.status.isFinished else { return }
        model.mutate { deck in
            deck.updateRun(runID) {
                $0.status = status
                $0.completedAt = Date()
                $0.error = error
            }
        }
    }
}
