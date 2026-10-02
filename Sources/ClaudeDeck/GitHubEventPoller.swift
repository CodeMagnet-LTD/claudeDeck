import AppKit
import ClaudeDeckCore
import Foundation

/// Watches the repositories of automations with GitHub triggers ("New GitHub issue" / "New pull
/// request") by polling `gh … list` every 2 minutes, also in menu-bar mode, like the scheduler.
/// The first poll of a repository only records what is already open; later polls start a run per
/// new matching item, deduplicated by the automation's claim ledger (see AutomationEvents.swift).
@MainActor
final class GitHubEventPoller {
    private unowned let model: AppModel
    private let scheduler: AutomationScheduler
    private var timer: Task<Void, Never>?
    private var polling = false
    private var lastAvailabilityCheck = Date.distantPast

    static let pollInterval: Duration = .seconds(120)
    static let listLimit = 30

    init(model: AppModel, scheduler: AutomationScheduler) {
        self.model = model
        self.scheduler = scheduler
    }

    func start() {
        guard timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            // Let launch-time work (resuming sessions) settle first.
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func poll() async {
        let watching = model.deck.automations.filter(\.isWatchingEvents)
        guard !watching.isEmpty, !polling else { return }
        polling = true
        defer { polling = false }
        let monitor = GitHubMonitor.shared
        if monitor.availability != .ready, Date().timeIntervalSince(lastAvailabilityCheck) > 600 || monitor.availability == nil {
            lastAvailabilityCheck = Date()
            await monitor.checkAvailability()
        }
        guard monitor.availability == .ready else { return }

        // One list per repository and kind, shared by the automations watching it.
        var lists: [String: [GitHubListItem]] = [:]
        for automation in watching {
            guard let projectID = automation.projectID, let project = model.deck.project(projectID),
                  case .success(let repo) = await GitHubRepoCache.shared.resolve(project.path) else { continue }
            for kind in AutomationEvents.watchedKinds(automation) {
                let scope = AutomationEvents.scope(kind, repo: repo)
                if lists[scope] == nil {
                    let limit = Self.listLimit
                    guard case .success(let items) = await Task.detached(operation: { GitHub.list(kind, repo: repo, limit: limit) }).value else { continue }
                    lists[scope] = items
                }
                let items = lists[scope] ?? []
                // Re-read: the deck may have changed while gh ran.
                guard let current = model.deck.automation(automation.id), current.isWatchingEvents,
                      current.projectID == projectID else { continue }
                if current.eventLedger.primed[scope] == nil {
                    model.mutate(userInitiated: false) { $0.primeEvents(automation.id, scope: scope, existing: items) }
                    continue
                }
                let fresh = AutomationEvents.newEvents(for: current, kind: kind, repo: repo, items: items)
                for item in fresh.prefix(AutomationEvents.maxDispatchPerPoll) {
                    guard scheduler.dispatchEvent(automation.id, item: item) else { break }
                }
            }
        }
    }
}
