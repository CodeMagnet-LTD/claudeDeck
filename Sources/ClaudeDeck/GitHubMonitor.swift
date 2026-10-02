import AppKit
import ClaudeDeckCore
import Observation

/// Fetches linked GitHub issues / pull requests with `gh` and notices when they change.
/// Polls every 60 s, only while there are links and the app is in front (or lives in the menu bar).
@MainActor
@Observable
final class GitHubMonitor {
    static let shared = GitHubMonitor()
    static let pollInterval: Duration = .seconds(60)

    /// nil until first checked (the first link or poll checks it).
    private(set) var availability: GitHubAvailability?
    private(set) var checkingAvailability = false
    /// Latest details per session id.
    private(set) var details: [UUID: GitHubItemDetails] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var loading: Set<UUID> = []
    /// CI repair keys (`CIRepair.key`) whose failing log is being fetched.
    var repairing: Set<String> = []
    /// Snapshot mode (DebugSnapshot): the session whose pane-header badge should open its popover.
    var debugPresentRequest: UUID?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Newest `updatedAt` already announced per session, so a change notifies once, not every poll.
    @ObservationIgnored private var notifiedUpdatedAt: [UUID: Date] = [:]

    func start(model: AppModel) {
        self.model = model
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollIfNeeded()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        // Launch runs before the app is active, and the loop skips while inactive: catch up on return.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastPoll) > 30 else { return }
                Task { await self.pollIfNeeded() }
            }
        }
    }

    @ObservationIgnored private var lastPoll = Date.distantPast

    private var linkedSessions: [DeckSession] {
        model?.deck.sessions.filter { $0.linkedWorkItem != nil } ?? []
    }

    private func pollIfNeeded() async {
        guard !linkedSessions.isEmpty, NSApp.isActive || NSApp.activationPolicy() == .accessory else { return }
        lastPoll = Date()
        if availability == nil { await checkAvailability() }
        // gh missing / logged out: the popover says so; no polling until the user re-checks.
        guard availability == .ready else { return }
        for session in linkedSessions { await refresh(session.id) }
    }

    /// Runs `gh auth status` again (after installing gh or `gh auth login`).
    func checkAvailability() async {
        guard !checkingAvailability else { return }
        checkingAvailability = true
        availability = await Task.detached { GitHub.availability() }.value
        checkingAvailability = false
    }

    /// Fetches the session's linked item now; announces what changed since the last fetch.
    func refresh(_ sessionID: UUID) async {
        guard let item = model?.deck.session(sessionID)?.linkedWorkItem, !loading.contains(sessionID) else { return }
        if availability == nil { await checkAvailability() }
        guard availability == .ready else { return }
        loading.insert(sessionID)
        let result = await Task.detached { GitHub.view(item) }.value
        loading.remove(sessionID)
        // The link may have been edited or removed meanwhile.
        guard let model, let session = model.deck.session(sessionID), let current = session.linkedWorkItem,
              current.isSameItem(as: item) else { return }
        switch result {
        case .failure(let error):
            errors[sessionID] = error.message
        case .success(let new):
            errors[sessionID] = nil
            let old = details[sessionID]
            details[sessionID] = new
            // Just linked: what's there now counts as seen.
            if current.lastSeenUpdatedAt == nil { setSeen(sessionID, new.updatedAt) }
            if let old, new.updatedAt > (notifiedUpdatedAt[sessionID] ?? old.updatedAt) || new.checks?.outcome != old.checks?.outcome {
                notifiedUpdatedAt[sessionID] = new.updatedAt
                let changes = GitHub.changes(from: old, to: new)
                if !changes.isEmpty { announce(changes, item: current, details: new, session: session) }
            } else if old == nil, let seen = current.lastSeenUpdatedAt, new.updatedAt > seen, notifiedUpdatedAt[sessionID] == nil {
                // First fetch since launch: changed while the app was closed (details of what are gone).
                notifiedUpdatedAt[sessionID] = new.updatedAt
                announce([.updated], item: current, details: new, session: session)
            }
        }
    }

    /// Newer than what the user last looked at (the "updated" dot).
    func hasUpdate(_ session: DeckSession) -> Bool {
        guard let seen = session.linkedWorkItem?.lastSeenUpdatedAt, let updated = details[session.id]?.updatedAt else { return false }
        return updated > seen
    }

    /// The popover was opened.
    func markSeen(_ sessionID: UUID) {
        guard let updated = details[sessionID]?.updatedAt else { return }
        setSeen(sessionID, updated)
    }

    private func setSeen(_ sessionID: UUID, _ date: Date) {
        guard let model, model.deck.session(sessionID)?.linkedWorkItem?.lastSeenUpdatedAt != date else { return }
        model.mutate { $0.updateSession(sessionID) { $0.linkedWorkItem?.lastSeenUpdatedAt = date } }
    }

    /// The link was added, changed or removed: drop cached state and fetch the new item.
    func linkChanged(_ sessionID: UUID) {
        details[sessionID] = nil
        errors[sessionID] = nil
        notifiedUpdatedAt[sessionID] = nil
        Task { await refresh(sessionID) }
    }

    // MARK: Notifications

    /// Uses the session attention pipeline (banner, Dock bounce), like a finished turn.
    private func announce(_ changes: [GitHubChange], item: LinkedWorkItem, details: GitHubItemDetails, session: DeckSession) {
        let text = changes.prefix(2).map(Self.describe).joined(separator: ", ")
        let title = "\(item.shortLabel): \(text)"
        let body = "\(details.title) — \(session.name)"
        model?.onAttention?(AttentionEvent(sessionID: session.id, activity: .idle, title: title, body: body))
    }

    static func describe(_ change: GitHubChange) -> String {
        switch change {
        case .merged: String(localized: "merged")
        case .closed: String(localized: "closed")
        case .reopened: String(localized: "reopened")
        case .ciFailed: String(localized: "CI failed")
        case .ciPassed: String(localized: "CI passed")
        case .approved: String(localized: "approved")
        case .changesRequested: String(localized: "changes requested")
        case .newReview(let author): String(localized: "new review from \(author)")
        case .newComments(let count, let author):
            count == 1 ? String(localized: "new comment from \(author)") : String(localized: "\(count) new comments")
        case .updated: String(localized: "updated")
        }
    }
}
