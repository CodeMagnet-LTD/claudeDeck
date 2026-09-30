import Foundation

// UI-free sidebar logic: which rows the sidebar shows and in what order, the filter and its
// counts, the "waiting for you" tray order, ⌘J cycling, and when a changed layout may be applied
// without moving rows under the user's pointer. The app maps its state into the small value
// types below (AppModel+Sidebar.swift).

/// What the sidebar needs to know about one session.
public struct SidebarSession: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case stopped
        case starting
        case shell
        case running
        /// Needs permission or asks a question.
        case blocked
        /// "Your turn"; `unseen` until the user has looked at it since it finished.
        case idle(unseen: Bool)
    }

    public var id: UUID
    public var state: State
    public var updatedAt: Date?
    /// Runs in its own git worktree (keeps its project in the full header + sessions layout).
    public var isWorktree: Bool

    public init(id: UUID, state: State, updatedAt: Date? = nil, isWorktree: Bool = false) {
        self.id = id
        self.state = state
        self.updatedAt = updatedAt
        self.isWorktree = isWorktree
    }

    /// Has a live terminal (makes its project active).
    public var isOpen: Bool { state != .stopped }
    /// Claude is working or waiting on a permission / question.
    public var isWorking: Bool { state == .running || state == .blocked }
    /// Blocked, or finished and not yet seen — listed in the "waiting for you" tray.
    public var needsAttention: Bool { state == .blocked || state == .idle(unseen: true) }
}

public struct SidebarProject: Sendable, Equatable {
    public var id: UUID
    public var pinned: Bool
    /// Only set for a group that exists.
    public var groupID: UUID?
    public var sessions: [SidebarSession]

    public init(id: UUID, pinned: Bool = false, groupID: UUID? = nil, sessions: [SidebarSession]) {
        self.id = id
        self.pinned = pinned
        self.groupID = groupID
        self.sessions = sessions
    }

    public var isActive: Bool { sessions.contains(where: \.isOpen) }
    /// Exactly one session and no worktree: shown as a single sidebar row.
    public var isCompact: Bool { sessions.count == 1 && !sessions[0].isWorktree }
}

/// All | Waiting | Working at the top of the sidebar.
public enum SidebarFilter: String, Sendable, CaseIterable {
    case all
    case waiting
    case working

    public func matches(_ session: SidebarSession) -> Bool {
        switch self {
        case .all: true
        case .waiting: session.needsAttention
        case .working: session.isWorking
        }
    }
}

/// A top-level sidebar entry.
public enum SidebarItem: Hashable, Sendable {
    case project(UUID)
    case group(UUID)
}

/// Remembers the order in which items became active, so the Active section never re-sorts when
/// a status changes: a newly active item is appended, an item that stops being active is
/// forgotten (and appended again if it comes back).
public struct ActivationOrder: Sendable, Equatable {
    public private(set) var items: [SidebarItem] = []

    public init() {}

    /// Updates the memory with the currently active items and returns them in activation order.
    /// Items that became active together keep the order of `active`.
    public mutating func arrange(_ active: [SidebarItem]) -> [SidebarItem] {
        let current = Set(active)
        items.removeAll { !current.contains($0) }
        for item in active where !items.contains(item) { items.append(item) }
        return items
    }
}

/// Which rows the sidebar shows, by id only; the view looks up names and live status itself, so
/// a layout that is held back for a moment (see `LayoutGate`) never shows stale status.
public struct SidebarLayout: Sendable, Equatable {
    public var pinned: [UUID] = []
    public var active: [SidebarItem] = []
    public var inactive: [SidebarItem] = []
    public var projectsInGroup: [UUID: [UUID]] = [:]
    public var sessionsInProject: [UUID: [UUID]] = [:]
    /// Projects shown as one row (their only session). Based on all sessions, not the filtered ones.
    public var compact: Set<UUID> = []

    public init() {}

    /// - Parameters:
    ///   - groups: group ids in their saved order.
    ///   - projects: projects in their saved order.
    ///   - order: activation memory, updated in place (only while `filter` is `.all`, so a filter
    ///     never reshuffles the unfiltered order).
    public static func build(groups: [UUID], projects: [SidebarProject], filter: SidebarFilter, order: inout ActivationOrder) -> SidebarLayout {
        var layout = SidebarLayout()
        let knownGroups = Set(groups)
        func visibleSessions(_ p: SidebarProject) -> [UUID] { p.sessions.filter(filter.matches).map(\.id) }
        func isShown(_ p: SidebarProject) -> Bool { filter == .all || !visibleSessions(p).isEmpty }

        for p in projects {
            layout.sessionsInProject[p.id] = visibleSessions(p)
            if p.isCompact { layout.compact.insert(p.id) }
        }
        layout.pinned = projects.filter { $0.pinned && isShown($0) }.map(\.id)

        let rest = projects.filter { !$0.pinned }
        var members: [UUID: [SidebarProject]] = [:]
        var ungrouped: [SidebarProject] = []
        for p in rest {
            if let g = p.groupID, knownGroups.contains(g) { members[g, default: []].append(p) } else { ungrouped.append(p) }
        }

        // Candidates in saved order: ungrouped projects, then groups (as today's Inactive section).
        var activeNow: [SidebarItem] = []
        var inactive: [SidebarItem] = []
        for p in ungrouped {
            if p.isActive { activeNow.append(.project(p.id)) } else { inactive.append(.project(p.id)) }
        }
        for g in groups {
            let list = members[g] ?? []
            layout.projectsInGroup[g] = list.filter(isShown).map(\.id)
            if list.contains(where: \.isActive) { activeNow.append(.group(g)) } else { inactive.append(.group(g)) }
        }

        let ordered: [SidebarItem]
        if filter == .all {
            ordered = order.arrange(activeNow)
        } else {
            // Same relative order as the unfiltered list; not-yet-remembered items at the end.
            let rank = Dictionary(uniqueKeysWithValues: order.items.enumerated().map { ($1, $0) })
            ordered = activeNow.enumerated()
                .sorted { (rank[$0.element] ?? Int.max, $0.offset) < (rank[$1.element] ?? Int.max, $1.offset) }
                .map(\.element)
        }
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        func itemShown(_ item: SidebarItem) -> Bool {
            switch item {
            case .project(let id): byID[id].map(isShown) ?? false
            case .group(let id): filter == .all || !(layout.projectsInGroup[id] ?? []).isEmpty
            }
        }
        layout.active = ordered.filter(itemShown)
        // Inactive projects have nothing waiting or working: hidden whenever a filter is on.
        layout.inactive = filter == .all ? inactive : []
        return layout
    }
}

public enum SidebarAttention {
    /// Waiting = sessions needing attention; working = running or blocked sessions.
    public static func counts(_ sessions: [SidebarSession]) -> (waiting: Int, working: Int) {
        (sessions.filter(\.needsAttention).count, sessions.filter(\.isWorking).count)
    }

    /// The tray order (also ⌘J's): blocked first, then finished-unseen; within each, oldest first,
    /// so a new arrival is appended instead of pushing the other rows down.
    public static func order(_ sessions: [SidebarSession]) -> [UUID] {
        sessions.enumerated()
            .filter { $0.element.needsAttention }
            .sorted { a, b in
                let (x, y) = (a.element, b.element)
                if (x.state == .blocked) != (y.state == .blocked) { return x.state == .blocked }
                let (tx, ty) = (x.updatedAt ?? .distantPast, y.updatedAt ?? .distantPast)
                if tx != ty { return tx < ty }
                return a.offset < b.offset
            }
            .map(\.element.id)
    }

    /// ⌘J: the session after `current` in `order`, wrapping around; the first one when `current`
    /// isn't waiting (e.g. it was just seen and left the list). nil when nothing is waiting.
    public static func next(after current: UUID?, in order: [UUID]) -> UUID? {
        guard !order.isEmpty else { return nil }
        guard let current, let i = order.firstIndex(of: current) else { return order[0] }
        return order[(i + 1) % order.count]
    }
}

/// Holds back layout changes the user didn't cause while they might be about to click, so rows
/// never move under the pointer. A change is applied at once when it follows a user action
/// (their click, a menu command, the filter — including slow consequences such as a session
/// exiting after "End Session", hence `userGrace`); otherwise only once the pointer has been
/// outside the sidebar for `quietPeriod` since the last click there or the moment it left.
/// A change is never held longer than `maxHold`, in case the pointer leaving is never reported.
public struct LayoutGate<Value: Equatable & Sendable>: Sendable {
    public private(set) var shown: Value
    public private(set) var pending: Value?
    public var quietPeriod: TimeInterval
    public var userGrace: TimeInterval
    public var maxHold: TimeInterval
    public private(set) var pointerInside = false
    /// When the oldest change still held back was first offered.
    private var pendingSince: Date?
    private var lastInteraction: Date = .distantPast
    private var lastUserAction: Date = .distantPast

    public init(_ value: Value, quietPeriod: TimeInterval = 1.5, userGrace: TimeInterval = 1.5, maxHold: TimeInterval = 10) {
        self.shown = value
        self.quietPeriod = quietPeriod
        self.userGrace = userGrace
        self.maxHold = maxHold
    }

    public mutating func pointer(inside: Bool, at now: Date) {
        if pointerInside && !inside { lastInteraction = now }
        pointerInside = inside
    }

    public mutating func click(at now: Date) { lastInteraction = now }

    public mutating func userAction(at now: Date) { lastUserAction = max(lastUserAction, now) }

    public func canApply(at now: Date) -> Bool {
        if now.timeIntervalSince(lastUserAction) <= userGrace { return true }
        if let pendingSince, now.timeIntervalSince(pendingSince) >= maxHold { return true }
        return !pointerInside && now.timeIntervalSince(lastInteraction) >= quietPeriod
    }

    /// Offers the latest layout. Returns true if `shown` changed.
    @discardableResult
    public mutating func offer(_ value: Value, at now: Date) -> Bool {
        if value == shown {
            pending = nil
            pendingSince = nil
            return false
        }
        if pending == nil { pendingSince = now }
        pending = value
        return tick(at: now)
    }

    /// Applies a held-back layout if that is allowed now. Returns true if `shown` changed.
    @discardableResult
    public mutating func tick(at now: Date) -> Bool {
        guard let pending, canApply(at: now) else { return false }
        shown = pending
        self.pending = nil
        pendingSince = nil
        return true
    }
}
