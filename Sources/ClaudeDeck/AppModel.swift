import AppKit
import ClaudeDeckCore
import Foundation
import Observation

/// What the sidebar shows for one ClaudeDeck session.
enum DisplayState: Equatable {
    case notStarted       // no terminal process (app just launched, or closed)
    case starting         // process running, no hook event yet
    case shell            // plain terminal (no Claude status)
    case activity(SessionActivity)

    var isBlocked: Bool { if case .activity(let a) = self { a.isBlocked } else { false } }
    var isRunning: Bool { self == .activity(.running) }
    var isIdle: Bool { self == .activity(.idle) }
}

struct SessionStatus: Equatable {
    var display: DisplayState
    var detail: String?
    var updatedAt: Date?
}

/// A state change worth telling the user about.
struct AttentionEvent {
    var sessionID: UUID
    var activity: SessionActivity
    var title: String
    var body: String
}

@MainActor
@Observable
final class AppModel {
    private(set) var deck: DeckData
    private(set) var hookStatuses: [UUID: HookStatus] = [:]
    private var transcriptSignals: [UUID: TranscriptSignal] = [:]
    /// Last time the user looked at a session while it was idle (clears the yellow "unseen" badge).
    private var seenAt: [UUID: Date] = [:]
    var hookError: String?
    /// Project shown in the file browser: the last project or session clicked in the sidebar.
    var browsedProjectID: UUID?
    /// Session being dragged from the sidebar (set when the drag starts; the drop uses it directly
    /// instead of decoding the item provider).
    @ObservationIgnored var draggedSessionID: UUID?
    /// Project ids in the order they became active (sidebar "Active" section).
    @ObservationIgnored var activationOrder: [UUID] = []
    /// Last sidebar drag (not cleared by the drop) — tells a click from the start of a drag.
    @ObservationIgnored var lastDraggedSessionID: UUID?
    /// Highlighted sidebar row: a project or session id — whatever was clicked last.
    var sidebarSelection: UUID?
    /// Projects without a running session that the user opened in the sidebar (not persisted).
    var idleExpandedProjects: Set<UUID> = []
    var claudePath: String?
    /// Sessions being restarted (AppModel+Restart.swift): their brief exit isn't shown as "ended".
    var restartingSessions: Set<UUID> = []

    @ObservationIgnored let terminals = TerminalRegistry()
    @ObservationIgnored private let store: DeckDataStore
    @ObservationIgnored private let statusDir = ProcessInfo.processInfo.environment["CLAUDEDECK_STATE_DIR"]
        .map { URL(fileURLWithPath: $0) } ?? StatusDirectory.defaultURL()
    /// Demo mode (tools/demo.sh): fixture data only — never touches ~/.claude/settings.json or iCloud.
    static let isDemo = ProcessInfo.processInfo.environment["CLAUDEDECK_DEMO"] != nil
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var tailers: [UUID: FileTailer] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Last notified state per session. Blocked states include the hook timestamp so a second
    /// permission request in the same turn notifies again.
    @ObservationIgnored private var lastNotified: [UUID: String] = [:]
    /// When the user last submitted input (Enter / a choice) while the session was blocked.
    private var answeredAt: [UUID: Date] = [:]
    @ObservationIgnored private var pendingCompact: Set<UUID> = []
    /// Automatically resumed sessions that get the "continue" message once resumed (and compacted).
    @ObservationIgnored private var pendingContinue: Set<UUID> = []
    /// Hook files older than the terminal's launch belong to a previous process.
    @ObservationIgnored private var launchedAt: [UUID: Date] = [:]
    /// Claude sessions launched with the Pencil (Pen.app) MCP server (PaneHeader badge).
    private(set) var pencilSessions: Set<UUID> = []
    /// Set by the UI layer (notifications, dock, bounce).
    @ObservationIgnored var onAttention: ((AttentionEvent) -> Void)?
    @ObservationIgnored var onCountsChanged: (() -> Void)?
    /// Opens the main window scene (set by a SwiftUI view that has `openWindow`).
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// Opens a file in the built-in editor window (set alongside `openMainWindow`).
    @ObservationIgnored var openEditorWindow: ((URL) -> Void)?
    /// The main window's tabs (WorkspaceTabs.swift).
    let tabs = WorkspaceTabs()
    // MARK: iCloud sync (DeckSyncController) — begin
    @ObservationIgnored let sync = DeckSyncController()
    // MARK: iCloud sync — end
    // MARK: Automations (AutomationScheduler) — begin
    @ObservationIgnored private(set) var automations: AutomationScheduler?
    // MARK: Automations — end

    init(store: DeckDataStore = .default()) {
        self.store = store
        self.deck = store.load()
        terminals.onExit = { [weak self] id, _ in self?.terminalExited(id) }
        terminals.onUserInput = { [weak self] id, data in self?.userTyped(id, data) }
        terminals.fontSize = deck.settings.terminalFontSize
        terminals.onZoom = { [weak self] step in self?.zoomTerminals(by: Double(step)) }
        // Clicking into a pane's terminal focuses that session.
        terminals.onFocus = { [weak self] id in
            guard let self, self.deck.selectedSessionID != id else { return }
            self.selectedSessionID = id
        }
    }

    // MARK: Lifecycle

    func start() {
        if !Self.isDemo { installHooks() }
        automations = AutomationScheduler(model: self) // marks runs interrupted by the last quit
        watcher = DirectoryWatcher(url: statusDir) { [weak self] in
            Task { @MainActor in self?.reloadStatuses() }
        }
        watcher?.start()
        reloadStatuses(initial: true)
        cleanupStatusFiles()
        if !Self.isDemo { sync.start(model: self) } // iCloud sync (no-op unless enabled)
        // Resolving `claude` runs the login shell; keep it off the main thread.
        Task { @MainActor in
            claudePath = await Task.detached { ShellEnvironment.resolveClaude() }.value
            launchInitialSessions()
            if !Self.isDemo { automations?.start() } // 30 s schedule check + on wake
        }
    }

    private func launchInitialSessions() {
        let toStart = deck.sessionsToStartOnLaunch(resumeOpen: deck.settings.resumeOnLaunch)
        for session in deck.sessions where session.isOpen && !toStart.contains(where: { $0.id == session.id }) {
            deck.updateSession(session.id) { $0.isOpen = false }
        }
        for session in toStart { launch(session.id, resume: true, automatic: true) }
        if let selected = deck.selectedSessionID, deck.session(selected) != nil, !terminals.isRunning(selected) {
            launch(selected, resume: true, automatic: true)
        }
        scheduleSave()
    }

    /// Called on quit: remember which sessions were open so they come back next launch.
    func prepareForQuit() {
        for session in deck.sessions {
            let open = terminals.isRunning(session.id)
            let display = status(of: session.id).display
            let busy = open && session.kind == .claude && (display.isRunning || display.isBlocked)
            deck.updateSession(session.id) {
                $0.isOpen = open
                $0.busyAtQuit = busy
            }
        }
        saveNow()
        terminals.terminateAll()
    }

    func installHooks() {
        do {
            try HookInstaller.default().install()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
    }

    func uninstallHooks() {
        do {
            try HookInstaller.default().uninstall()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
    }

    func canResume(_ id: UUID) -> Bool { deck.resumableID(for: id) != nil }

    var hooksInstalled: Bool { HookInstaller.default().isInstalled() }

    // MARK: Status

    func status(of id: UUID) -> SessionStatus {
        if deck.session(id)?.kind == .shell {
            return terminals.isRunning(id)
                ? SessionStatus(display: .shell, detail: terminals.titles[id], updatedAt: nil)
                : SessionStatus(display: .notStarted, detail: nil, updatedAt: nil)
        }
        guard terminals.isRunning(id) else {
            return SessionStatus(display: .notStarted, detail: nil, updatedAt: deck.session(id)?.lastActivityAt)
        }
        guard let resolved = EffectiveStatus.resolve(
            hook: hookStatuses[id], transcript: transcriptSignals[id], answeredAt: answeredAt[id], processAlive: true
        ) else {
            return SessionStatus(display: .starting, detail: nil, updatedAt: nil)
        }
        return SessionStatus(display: .activity(resolved.activity), detail: resolved.detail, updatedAt: resolved.updatedAt)
    }

    /// Idle and not yet looked at since it became idle.
    func isUnseenIdle(_ id: UUID) -> Bool {
        let s = status(of: id)
        guard s.display.isIdle, let at = s.updatedAt else { return false }
        if hookStatuses[id]?.event == "SessionStart" { return false }
        return at > (seenAt[id] ?? .distantPast)
    }

    func needsAttention(_ id: UUID) -> Bool { status(of: id).display.isBlocked || isUnseenIdle(id) }

    var counts: (blocked: Int, running: Int, unseen: Int) {
        var blocked = 0, running = 0, unseen = 0
        for s in deck.sessions {
            let st = status(of: s.id)
            if st.display.isBlocked { blocked += 1 }
            else if st.display.isRunning { running += 1 }
            else if isUnseenIdle(s.id) { unseen += 1 }
        }
        return (blocked, running, unseen)
    }

    /// Sessions waiting for the user: blocked first, then finished-but-unseen; newest first.
    var attentionSessions: [DeckSession] {
        deck.sessions
            .filter { needsAttention($0.id) }
            .sorted {
                let (a, b) = (status(of: $0.id), status(of: $1.id))
                if a.display.isBlocked != b.display.isBlocked { return a.display.isBlocked }
                return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
            }
    }

    func markSeen(_ id: UUID) {
        seenAt[id] = Date()
        onCountsChanged?()
    }

    private func reloadStatuses(initial: Bool = false) {
        let entries = StatusDirectory.readAll(in: statusDir)
        let latest = StatusDirectory.latestByTerminal(entries.map(\.status))
        var next: [UUID: HookStatus] = [:]
        for session in deck.sessions {
            guard let status = latest[session.id.uuidString] else { continue }
            if let launched = launchedAt[session.id], status.updatedAt < launched { continue }
            next[session.id] = status
        }
        let previous = hookStatuses
        hookStatuses = next

        for (id, status) in next where previous[id] != status {
            if deck.session(id)?.claudeSessionID != status.sessionID || deck.session(id)?.lastActivityAt != status.updatedAt {
                deck.updateSession(id) {
                    $0.claudeSessionID = status.sessionID
                    $0.transcriptPath = status.transcriptPath
                    $0.lastActivityAt = status.updatedAt
                    // The worktree Claude created; only SessionStart, cwd may drift later.
                    if $0.worktreeName != nil, let cwd = status.cwd, status.event == "SessionStart" || $0.workingDirectory == nil {
                        $0.workingDirectory = cwd
                    }
                }
                scheduleSave()
            }
            followTranscript(for: id, path: status.transcriptPath)
            if status.event == "SessionStart", status.source == "resume" { afterResume(id, transcript: status.transcriptPath) }
        }
        if initial {
            for id in next.keys { lastNotified[id] = notifyKey(id) }
        } else {
            emitAttentionChanges()
        }
        onCountsChanged?()
    }

    private func followTranscript(for id: UUID, path: String?) {
        guard let path else { return }
        if tailers[id]?.url.path == path { return }
        tailers[id]?.stop()
        tailers[id] = nil
        let tailer = FileTailer(url: URL(fileURLWithPath: path)) { [weak self] chunk in
            guard let signal = Transcript.lastSignal(in: chunk) else { return }
            Task { @MainActor in self?.receive(signal, for: id) }
        }
        // The transcript appears with the first message; retried on the next status update.
        if tailer.start() { tailers[id] = tailer }
    }

    private func receive(_ signal: TranscriptSignal, for id: UUID) {
        transcriptSignals[id] = signal
        emitAttentionChanges()
        onCountsChanged?()
    }

    private func notifyKey(_ id: UUID) -> String? {
        guard let activity = status(of: id).display.activityValue else { return nil }
        if activity.isBlocked, let at = hookStatuses[id]?.updatedAt { return "\(activity)|\(at.timeIntervalSince1970)" }
        return activity.rawValue
    }

    /// Idle because of an interrupt or denial recorded in the transcript (not a Stop hook).
    private func endedByUser(_ id: UUID) -> Bool {
        guard let signal = transcriptSignals[id], let hook = hookStatuses[id] else { return false }
        return signal.at > hook.updatedAt && hook.state != .idle
    }

    /// Enter or a numbered choice while blocked = the user answered the prompt.
    private func userTyped(_ id: UUID, _ data: ArraySlice<UInt8>) {
        guard status(of: id).display.isBlocked else { return }
        let answered = data.contains(13) || (data.count == 1 && (0x31...0x39).contains(data.first!))
        guard answered else { return }
        answeredAt[id] = Date()
        lastNotified[id] = notifyKey(id)
        onCountsChanged?()
    }

    private func emitAttentionChanges() {
        for session in deck.sessions {
            let status = status(of: session.id)
            let key = notifyKey(session.id)
            defer { lastNotified[session.id] = key }
            guard let activity = status.display.activityValue, key != lastNotified[session.id], activity.isAttention else { continue }
            // Finished while the user is looking at it: already seen.
            if activity == .idle, isVisible(session.id) { seenAt[session.id] = Date() }
            // Esc / denied permission: the user did it themselves — no notification, not "unseen".
            if activity == .idle, endedByUser(session.id) {
                seenAt[session.id] = Date()
                continue
            }
            // Startup / resume sessions land in idle — that's not news.
            if activity == .idle, hookStatuses[session.id]?.event == "SessionStart" { continue }
            let project = deck.project(session.projectID)?.name ?? ""
            let title = session.name == project || project.isEmpty ? session.name : "\(session.name) — \(project)"
            let body: String = switch activity {
            case .needsPermission: String(localized: "Needs permission") + (status.detail.map { ": \($0)" } ?? "")
            case .needsAnswer: String(localized: "Asking a question") + (status.detail.map { ": \($0)" } ?? "")
            case .idle: status.detail.map { String(localized: "Done — \($0)") } ?? String(localized: "Done — your turn")
            default: ""
            }
            onAttention?(AttentionEvent(sessionID: session.id, activity: activity, title: title, body: body))
        }
    }

    private func cleanupStatusFiles() {
        let entries = StatusDirectory.readAll(in: statusDir)
        for url in StatusDirectory.filesToDelete(entries, now: Date()) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Terminals

    func launch(_ id: UUID, resume: Bool, automatic: Bool = false, resumeID: String? = nil, continueLatest: Bool = false) {
        guard let session = deck.session(id), let project = deck.project(session.projectID) else { return }
        if terminals.isRunning(id) { return }
        if session.kind == .shell {
            terminals.startShell(id: id, cwd: project.path)
            if let command = session.startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
                // Typed like the user would once the shell had a moment to load its rc files
                // (the pty buffers it meanwhile), so it lands in history and Ctrl+C keeps the shell.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    terminals.type(command + "\r", into: id)
                }
            }
            deck.updateSession(id) { $0.isOpen = true }
            scheduleSave()
            onCountsChanged?()
            return
        }
        let sid = resumeID ?? (resume ? deck.resumableID(for: id) : nil)
        var args = ["--name", session.name]
        if let sid { args += ["--resume", sid] } else if continueLatest { args.append("--continue") }
        // Worktree sessions run in their worktree; `--worktree` only when it doesn't exist yet.
        let worktreeDir = session.workingDirectory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        if sid == nil, worktreeDir == nil, let worktree = session.worktreeName { args += ["--worktree", worktree] }
        if automatic, sid != nil, deck.settings.compactOnResume { pendingCompact.insert(id) }
        if automatic, sid != nil, deck.settings.continueAfterResume,
           !deck.settings.continueOnlyIfBusy || session.busyAtQuit {
            pendingContinue.insert(id)
        }
        deck.updateSession(id) { $0.busyAtQuit = false }
        transcriptSignals[id] = nil
        answeredAt[id] = nil
        hookStatuses[id] = nil
        launchedAt[id] = Date()
        // Pencil MCP first: `--mcp-config` is variadic and the following `--name` ends it.
        let pencil = PencilApp.launchArgs(enabled: deck.settings.pencilMCP)
        if pencil.isEmpty { pencilSessions.remove(id) } else { pencilSessions.insert(id) }
        terminals.start(id: id, cwd: worktreeDir ?? project.path, claudePath: claudePath, args: pencil + args)
        deck.updateSession(id) { $0.isOpen = true }
        lastNotified[id] = nil
        scheduleSave()
        onCountsChanged?()
    }

    /// After an automatic resume: `/compact` if the context is over the threshold, then the
    /// "continue" message (after compaction has finished) — each only if enabled for this session.
    private func afterResume(_ id: UUID, transcript: String?) {
        let wantsCompact = pendingCompact.remove(id) != nil
        let wantsContinue = pendingContinue.remove(id) != nil
        guard wantsCompact || wantsContinue else { return }
        let threshold = deck.settings.compactThresholdTokens
        Task { @MainActor in
            // Give the TUI a moment to draw its prompt; then type like the user would.
            try? await Task.sleep(for: .seconds(2))
            if wantsCompact, let transcript {
                // The real context size (not the transcript file size, which never shrinks).
                let url = URL(fileURLWithPath: transcript)
                let tokens = await Task.detached { Transcript.contextTokens(of: url) }.value ?? 0
                if tokens > threshold {
                    let sentAt = Date()
                    terminals.type("/compact\r", into: id)
                    await waitUntilIdle(id, after: sentAt, timeout: .seconds(600))
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            guard wantsContinue, terminals.isRunning(id) else { return }
            let custom = deck.settings.continueMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = custom.isEmpty ? String(localized: "Continue where you left off.") : custom
            terminals.type(message + "\r", into: id)
        }
    }

    /// Waits for a hook event newer than `after` that leaves the session idle (e.g. compaction done).
    private func waitUntilIdle(_ id: UUID, after: Date, timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, terminals.isRunning(id) {
            if let hook = hookStatuses[id], hook.updatedAt > after, hook.state == .idle { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    func stop(_ id: UUID) {
        terminals.terminate(id)
    }

    private func terminalExited(_ id: UUID) {
        tailers[id]?.stop()
        tailers[id] = nil
        pendingCompact.remove(id)
        pendingContinue.remove(id)
        deck.updateSession(id) { $0.isOpen = false }
        scheduleSave()
        onCountsChanged?()
    }

    // MARK: Selection

    var selectedSessionID: UUID? {
        get { deck.selectedSessionID }
        set {
            sidebarSelection = newValue
            if newValue != nil { tabs.selectSessions() } // a session was picked: show it
            guard deck.selectedSessionID != newValue || (newValue.map { !deck.panes.contains($0) } ?? false) else { return }
            deck.select(newValue)
            if let newValue {
                browsedProjectID = deck.session(newValue)?.projectID
                markSeen(newValue)
                // Selecting a session not yet started in this app run continues it automatically.
                // Sessions ended during this run (/exit, "End Session") wait for "Resume".
                if terminals.view(for: newValue) == nil { launch(newValue, resume: true) }
            }
            scheduleSave()
        }
    }

    /// The session currently in front of the user (app active + selected).
    var focusedSessionID: UUID? {
        NSApp.isActive && NSApp.keyWindow != nil ? deck.selectedSessionID : nil
    }

    /// Sessions whose terminal the user can currently see (all split panes of the active window).
    func isVisible(_ id: UUID) -> Bool {
        NSApp.isActive && NSApp.keyWindow != nil && deck.visiblePanes.contains(id)
    }

    // MARK: Split panes

    /// Shows a session in a new pane beside `anchor` (or the focused pane).
    func openBeside(_ id: UUID, anchor: UUID? = nil, before: Bool = false) {
        guard deck.openPane(id, besideOf: anchor, before: before) else {
            NSSound.beep()
            return
        }
        markSeen(id)
        if terminals.view(for: id) == nil { launch(id, resume: true) }
        scheduleSave()
    }

    func closePane(_ id: UUID) {
        deck.closePane(id)
        scheduleSave()
    }

    // MARK: Deck mutations

    func mutate(_ change: (inout DeckData) -> Void) {
        change(&deck)
        scheduleSave()
    }

    @discardableResult
    func addProject(path: String) -> Project {
        let project = deck.addProject(path: path)
        scheduleSave()
        return project
    }

    @discardableResult
    func newSession(in projectID: UUID, resumeID: String? = nil, title: String? = nil) -> UUID? {
        var name: String?
        if let title, let project = deck.project(projectID) {
            name = "\(project.name) · \(title.prefix(30))"
        }
        guard let session = deck.addSession(to: projectID, claudeSessionID: resumeID, name: name) else { return nil }
        launch(session.id, resume: resumeID != nil, resumeID: resumeID)
        selectedSessionID = session.id
        return session.id
    }

    /// A plain terminal in the project folder.
    @discardableResult
    func newShell(in projectID: UUID) -> UUID? {
        guard let session = deck.addSession(to: projectID, kind: .shell) else { return nil }
        launch(session.id, resume: false)
        selectedSessionID = session.id
        return session.id
    }

    @discardableResult
    func newCommandShell(in projectID: UUID, command: String) -> UUID? {
        guard let session = deck.addCommandShell(to: projectID, command: command) else { return nil }
        launch(session.id, resume: false)
        selectedSessionID = session.id
        return session.id
    }

    func newShellInSelectedProject() {
        if let projectID = selectedProjectID ?? deck.projects.first?.id { newShell(in: projectID) }
    }

    func removeSession(_ id: UUID) {
        terminals.terminate(id)
        terminals.discard(id)
        tailers[id]?.stop()
        tailers[id] = nil
        deck.removeSession(id)
        hookStatuses[id] = nil
        transcriptSignals[id] = nil
        answeredAt[id] = nil
        seenAt[id] = nil
        launchedAt[id] = nil
        lastNotified[id] = nil
        pendingCompact.remove(id)
        pendingContinue.remove(id)
        scheduleSave()
        onCountsChanged?()
    }

    func removeProject(_ id: UUID) {
        for s in deck.sessions(in: id) { removeSession(s.id) }
        deck.removeProject(id)
        scheduleSave()
    }

    func renameSession(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        deck.updateSession(id) { $0.name = trimmed }
        // Running claude keeps its name until next start; /rename updates the live session.
        if deck.session(id)?.kind == .claude, terminals.isRunning(id), status(of: id).display.isIdle {
            terminals.type("/rename \(trimmed)\r", into: id)
        }
        scheduleSave()
    }

    // MARK: Permission actions support

    /// Prompts already denied from the app (see PermissionActions.swift): Esc leaves the state
    /// blocked until the transcript records the denial, and a second Esc would open the rewind picker.
    @ObservationIgnored var deniedPermissionStamps: [UUID: Date] = [:]

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        // iCloud sync: stamp local project/group edits and write the shared file.
        if let synced = sync.prepareSave(deck) { deck = synced }
        try? store.save(deck)
    }
}

extension DisplayState {
    var activityValue: SessionActivity? {
        if case .activity(let a) = self { a } else { nil }
    }
}
