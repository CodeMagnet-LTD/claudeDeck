import AppKit
import ClaudeDeckCore
import Foundation
import Observation

/// What the sidebar shows for one ClaudeDeck session.
enum DisplayState: Equatable {
    case notStarted       // no terminal process (app just launched, or closed)
    case starting         // process running, no hook event yet
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
    var claudePath: String?

    @ObservationIgnored let terminals = TerminalRegistry()
    @ObservationIgnored private let store: DeckDataStore
    @ObservationIgnored private let statusDir = StatusDirectory.defaultURL()
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var tailers: [UUID: FileTailer] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Last notified state per session. Blocked states include the hook timestamp so a second
    /// permission request in the same turn notifies again.
    @ObservationIgnored private var lastNotified: [UUID: String] = [:]
    /// When the user last submitted input (Enter / a choice) while the session was blocked.
    private var answeredAt: [UUID: Date] = [:]
    @ObservationIgnored private var pendingCompact: Set<UUID> = []
    /// Hook files older than the terminal's launch belong to a previous process.
    @ObservationIgnored private var launchedAt: [UUID: Date] = [:]
    /// Set by the UI layer (notifications, dock, bounce).
    @ObservationIgnored var onAttention: ((AttentionEvent) -> Void)?
    @ObservationIgnored var onCountsChanged: (() -> Void)?
    /// Opens the main window scene (set by a SwiftUI view that has `openWindow`).
    @ObservationIgnored var openMainWindow: (() -> Void)?

    init(store: DeckDataStore = .default()) {
        self.store = store
        self.deck = store.load()
        terminals.onExit = { [weak self] id, _ in self?.terminalExited(id) }
        terminals.onUserInput = { [weak self] id, data in self?.userTyped(id, data) }
    }

    // MARK: Lifecycle

    func start() {
        installHooks()
        watcher = DirectoryWatcher(url: statusDir) { [weak self] in
            Task { @MainActor in self?.reloadStatuses() }
        }
        watcher?.start()
        reloadStatuses(initial: true)
        cleanupStatusFiles()
        // Resolving `claude` runs the login shell; keep it off the main thread.
        Task { @MainActor in
            claudePath = await Task.detached { ShellEnvironment.resolveClaude() }.value
            launchInitialSessions()
        }
    }

    private func launchInitialSessions() {
        let toResume = deck.sessions.filter(\.isOpen)
        if deck.settings.resumeOnLaunch {
            for session in toResume { launch(session.id, resume: true, automatic: true) }
        } else {
            for session in toResume { deck.updateSession(session.id) { $0.isOpen = false } }
        }
        if let selected = deck.selectedSessionID, deck.session(selected) != nil, !terminals.isRunning(selected) {
            launch(selected, resume: true, automatic: true)
        }
        scheduleSave()
    }

    /// Called on quit: remember which sessions were open so they come back next launch.
    func prepareForQuit() {
        for session in deck.sessions {
            let open = terminals.isRunning(session.id)
            deck.updateSession(session.id) { $0.isOpen = open }
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
                }
                scheduleSave()
            }
            followTranscript(for: id, path: status.transcriptPath)
            if status.event == "SessionStart", status.source == "resume" { compactIfNeeded(id, transcript: status.transcriptPath) }
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
            if activity == .idle, focusedSessionID == session.id { seenAt[session.id] = Date() }
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
            case .needsPermission: "İzin istiyor" + (status.detail.map { ": \($0)" } ?? "")
            case .needsAnswer: "Soru soruyor" + (status.detail.map { ": \($0)" } ?? "")
            case .idle: status.detail.map { "Bitti — \($0)" } ?? "Bitti — sıra sende"
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

    func launch(_ id: UUID, resume: Bool, automatic: Bool = false, resumeID: String? = nil) {
        guard let session = deck.session(id), let project = deck.project(session.projectID) else { return }
        if terminals.isRunning(id) { return }
        let sid = resumeID ?? (resume ? deck.resumableID(for: id) : nil)
        var args = ["--name", session.name]
        if let sid { args += ["--resume", sid] }
        if automatic, sid != nil, deck.settings.compactOnResume { pendingCompact.insert(id) }
        transcriptSignals[id] = nil
        answeredAt[id] = nil
        hookStatuses[id] = nil
        launchedAt[id] = Date()
        terminals.start(id: id, cwd: project.path, claudePath: claudePath, args: args)
        deck.updateSession(id) { $0.isOpen = true }
        lastNotified[id] = nil
        scheduleSave()
        onCountsChanged?()
    }

    private func compactIfNeeded(_ id: UUID, transcript: String?) {
        guard pendingCompact.remove(id) != nil, let transcript else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: transcript)[.size] as? Int) ?? 0
        guard size > deck.settings.compactThresholdKB * 1024 else { return }
        // Give the TUI a moment to draw its prompt, then type /compact like the user would.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            terminals.type("/compact\r", into: id)
        }
    }

    func stop(_ id: UUID) {
        terminals.terminate(id)
    }

    private func terminalExited(_ id: UUID) {
        tailers[id]?.stop()
        tailers[id] = nil
        pendingCompact.remove(id)
        deck.updateSession(id) { $0.isOpen = false }
        scheduleSave()
        onCountsChanged?()
    }

    // MARK: Selection

    var selectedSessionID: UUID? {
        get { deck.selectedSessionID }
        set {
            guard deck.selectedSessionID != newValue else { return }
            deck.selectedSessionID = newValue
            if let newValue {
                markSeen(newValue)
                // Selecting a session not yet started in this app run continues it automatically.
                // Sessions ended during this run (/exit, "Oturumu bitir") wait for "Devam et".
                if terminals.view(for: newValue) == nil { launch(newValue, resume: true) }
            }
            scheduleSave()
        }
    }

    /// The session currently in front of the user (app active + selected).
    var focusedSessionID: UUID? {
        NSApp.isActive && NSApp.keyWindow != nil ? deck.selectedSessionID : nil
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
        if terminals.isRunning(id), status(of: id).display.isIdle {
            terminals.type("/rename \(trimmed)\r", into: id)
        }
        scheduleSave()
    }

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
        try? store.save(deck)
    }
}

extension DisplayState {
    var activityValue: SessionActivity? {
        if case .activity(let a) = self { a } else { nil }
    }
}
