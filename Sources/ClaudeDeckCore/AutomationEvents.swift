import Foundation

// Event triggers for automations: a new GitHub issue / pull request in the project's repository.
// Model adapted from MonoCode (MIT): event keys like "github:pr:owner/repo:N" and a claim ledger,
// so an event starts at most one run; the first poll of a repository only records what exists.

public struct GitHubEventTrigger: Codable, Sendable, Equatable, Hashable {
    public enum Event: String, Codable, Sendable, CaseIterable {
        case issueOpened, pullRequestOpened

        public var itemKind: LinkedWorkItem.Kind { self == .issueOpened ? .issue : .pr }
    }

    public var event: Event
    /// Only items carrying this label (case-insensitive); nil / empty = any.
    public var label: String?
    /// Only items opened by this GitHub login (case-insensitive, "@" optional); nil / empty = anyone.
    public var author: String?

    public init(event: Event, label: String? = nil, author: String? = nil) {
        self.event = event
        self.label = label
        self.author = author
    }

    public func matches(_ item: GitHubListItem) -> Bool {
        guard item.kind == event.itemKind else { return false }
        if let label = Self.normalized(label), !item.labels.contains(where: { $0.name.lowercased() == label }) { return false }
        if let author = Self.normalized(author).map({ $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }),
           item.author?.lowercased() != author { return false }
        return true
    }

    private static func normalized(_ text: String?) -> String? {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty ? nil : t
    }
}

/// Per automation: the repositories ("scopes") already primed, and the events already claimed.
public struct AutomationEventLedger: Codable, Sendable, Equatable {
    public static let maxClaimed = 500

    /// Scope (`AutomationEvents.scope`) → when its existing items were recorded.
    public var primed: [String: Date] = [:]
    /// Event keys that started (or were recorded as existing), oldest first.
    public var claimed: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primed = (try? c.decodeIfPresent([String: Date].self, forKey: .primed)) ?? [:]
        claimed = (try? c.decodeIfPresent([String].self, forKey: .claimed)) ?? []
    }

    public func isClaimed(_ key: String) -> Bool { claimed.contains(key) }

    mutating func claim(_ keys: [String]) {
        let existing = Set(claimed)
        claimed += keys.filter { !existing.contains($0) }
        if claimed.count > Self.maxClaimed { claimed.removeFirst(claimed.count - Self.maxClaimed) }
    }
}

public enum AutomationEvents {
    /// Items created this long before priming still count as new if the priming list missed them
    /// (GitHub's list can lag a few seconds behind a just-opened item).
    public static let primingSlack: TimeInterval = 120
    /// At most this many events start per automation per poll; the rest wait for the next poll.
    public static let maxDispatchPerPoll = 3

    /// "github:issue:owner/repo".
    public static func scope(_ kind: LinkedWorkItem.Kind, repo: String) -> String {
        "github:\(kind.rawValue):\(repo.lowercased())"
    }

    /// "github:pr:owner/repo:12".
    public static func key(_ item: GitHubListItem) -> String {
        "\(scope(item.kind, repo: item.repo)):\(item.number)"
    }

    /// The item kinds an automation's GitHub triggers watch.
    public static func watchedKinds(_ automation: Automation) -> [LinkedWorkItem.Kind] {
        let kinds = Set(automation.githubTriggers.map(\.event.itemKind))
        return [.issue, .pr].filter { kinds.contains($0) }
    }

    /// New, unclaimed items (oldest first) that match one of the automation's triggers. Empty while
    /// the scope isn't primed yet (the caller primes it with the same list).
    public static func newEvents(for automation: Automation, kind: LinkedWorkItem.Kind, repo: String,
                                 items: [GitHubListItem]) -> [GitHubListItem] {
        guard let primedAt = automation.eventLedger.primed[scope(kind, repo: repo)] else { return [] }
        let triggers = automation.githubTriggers.filter { $0.event.itemKind == kind }
        return items
            .filter { $0.kind == kind && $0.createdAt > primedAt.addingTimeInterval(-primingSlack) }
            .filter { !automation.eventLedger.isClaimed(key($0)) }
            .filter { item in triggers.contains { $0.matches(item) } }
            .sorted { ($0.createdAt, $0.number) < ($1.createdAt, $1.number) }
    }

    /// The text typed into the run's session: the automation's prompt, then the item.
    public static func prompt(_ automationPrompt: String, item: GitHubListItem) -> String {
        let base = automationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["\(item.kind == .pr ? "New pull request" : "New issue") in \(item.repo): #\(item.number) \(item.title)", item.url]
        if let author = item.author { lines.append("Opened by @\(author)") }
        if !item.labels.isEmpty { lines.append("Labels: \(item.labels.map(\.name).joined(separator: ", "))") }
        return base + "\n\n" + lines.joined(separator: "\n")
    }

    /// "#12 Title".
    public static func summary(_ item: GitHubListItem) -> String {
        "\(item.kind == .pr ? "PR " : "")#\(item.number) \(item.title)"
    }
}

extension Automation {
    public var githubTriggers: [GitHubEventTrigger] { triggers.compactMap(\.githubEvent) }

    /// Enabled, complete and with at least one GitHub trigger: the event poller watches it.
    public var isWatchingEvents: Bool {
        enabled && projectID != nil && !githubTriggers.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension DeckData {
    /// First poll of a repository: everything listed now counts as already seen (no backlog flood).
    public mutating func primeEvents(_ automationID: UUID, scope: String, existing: [GitHubListItem], now: Date = Date()) {
        updateAutomation(automationID) { a in
            guard a.eventLedger.primed[scope] == nil else { return }
            a.eventLedger.primed[scope] = now
            a.eventLedger.claim(existing.map(AutomationEvents.key))
        }
    }

    /// Atomic claim of one event: false if it already ran (or the automation stopped watching).
    /// Returns the new pending run otherwise.
    public mutating func claimEvent(_ automationID: UUID, item: GitHubListItem, now: Date = Date()) -> AutomationRun? {
        let key = AutomationEvents.key(item)
        guard let a = automation(automationID), a.isWatchingEvents, !a.eventLedger.isClaimed(key) else { return nil }
        var run = AutomationRun(automationID: automationID, trigger: .event, startedAt: now)
        run.eventKey = key
        run.eventSummary = AutomationEvents.summary(item)
        updateAutomation(automationID) {
            $0.eventLedger.claim([key])
            $0.lastRunAt = now
            $0.lastRunStatus = .pending
        }
        appendRun(run)
        return run
    }
}
