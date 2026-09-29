import Foundation

// Automations: saved prompts that start a Claude session on a schedule or on demand.
// Scheduling model adapted from MonoCode (MIT): time triggers in the local time zone, a
// "claim" that advances `nextRunAt` before a run starts, and a missed-run grace period.

/// Time of day (local), 24h.
public struct ClockTime: Codable, Sendable, Equatable, Hashable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }
}

/// When an automation starts on its own. Only time triggers exist for now; other kinds
/// (e.g. repository events) can be added as new cases.
public enum AutomationTrigger: Sendable, Equatable, Hashable {
    /// Every hour at `minute`.
    case hourly(minute: Int)
    case daily(ClockTime)
    /// Monday–Friday.
    case weekdays(ClockTime)
    /// `weekday` in Calendar convention: 1 = Sunday … 7 = Saturday.
    case weekly(weekday: Int, ClockTime)

    /// The trigger family (for pickers / future non-time kinds).
    public enum Kind: String, Codable, Sendable, CaseIterable { case time }
    public var kind: Kind { .time }

    /// Calendar components that match this trigger's occurrences.
    var components: DateComponents {
        switch self {
        case .hourly(let minute): DateComponents(minute: min(max(minute, 0), 59), second: 0)
        case .daily(let t), .weekdays(let t): DateComponents(hour: t.hour, minute: t.minute, second: 0)
        case .weekly(let weekday, let t): DateComponents(hour: t.hour, minute: t.minute, second: 0, weekday: min(max(weekday, 1), 7))
        }
    }

    /// First occurrence strictly after `date`, in `calendar`'s time zone (DST-safe: a time
    /// skipped by a spring-forward jump runs at the next valid time that day).
    public func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date? {
        var from = date
        // weekdays: step through daily matches until one falls on Mon–Fri (at most 3 steps).
        for _ in 0..<8 {
            guard let next = calendar.nextDate(after: from, matching: components, matchingPolicy: .nextTime) else { return nil }
            if case .weekdays = self, !(2...6).contains(calendar.component(.weekday, from: next)) {
                from = next
                continue
            }
            return next
        }
        return nil
    }
}

extension AutomationTrigger: Codable {
    private enum CodingKeys: String, CodingKey { case kind, schedule, minute, hour, weekday }
    private enum Schedule: String, Codable { case hourly, daily, weekdays, weekly }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? Kind.time.rawValue
        guard kind == Kind.time.rawValue, let schedule = try? c.decode(Schedule.self, forKey: .schedule) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unsupported trigger")
        }
        let minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        let time = ClockTime(hour: try c.decodeIfPresent(Int.self, forKey: .hour) ?? 9, minute: minute)
        switch schedule {
        case .hourly: self = .hourly(minute: min(max(minute, 0), 59))
        case .daily: self = .daily(time)
        case .weekdays: self = .weekdays(time)
        case .weekly: self = .weekly(weekday: min(max(try c.decodeIfPresent(Int.self, forKey: .weekday) ?? 2, 1), 7), time)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .kind)
        switch self {
        case .hourly(let minute):
            try c.encode(Schedule.hourly, forKey: .schedule)
            try c.encode(minute, forKey: .minute)
        case .daily(let t), .weekdays(let t):
            try c.encode(self == .daily(t) ? Schedule.daily : Schedule.weekdays, forKey: .schedule)
            try c.encode(t.hour, forKey: .hour)
            try c.encode(t.minute, forKey: .minute)
        case .weekly(let weekday, let t):
            try c.encode(Schedule.weekly, forKey: .schedule)
            try c.encode(weekday, forKey: .weekday)
            try c.encode(t.hour, forKey: .hour)
            try c.encode(t.minute, forKey: .minute)
        }
    }
}

/// Where an automation's session runs.
public enum AutomationWorkspace: String, Codable, Sendable, CaseIterable {
    /// The project folder itself.
    case current
    /// A fresh git worktree per run (`claude --worktree`).
    case newWorktree
}

public enum AutomationRunStatus: String, Codable, Sendable, CaseIterable {
    case pending, running, succeeded, failed, skipped, cancelled

    public var isFinished: Bool { ![.pending, .running].contains(self) }
}

public enum AutomationRunTrigger: String, Codable, Sendable {
    case scheduled, manual
}

public struct Automation: Codable, Identifiable, Sendable, Equatable {
    public static let defaultGraceMinutes = 720

    public var id: UUID
    public var name: String
    public var prompt: String
    public var projectID: UUID?
    public var workspace: AutomationWorkspace
    /// Continue in the last run's session (when idle) instead of starting a new one.
    public var reuseSession: Bool
    public var triggers: [AutomationTrigger]
    /// A scheduled run found later than this (Mac asleep, app not running) is skipped.
    public var missedRunGraceMinutes: Int
    public var enabled: Bool
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    public var lastRunStatus: AutomationRunStatus?
    public var lastSessionID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String = "", prompt: String = "", projectID: UUID? = nil,
                workspace: AutomationWorkspace = .current, reuseSession: Bool = false,
                triggers: [AutomationTrigger] = [.weekdays(ClockTime(hour: 9, minute: 0))],
                missedRunGraceMinutes: Int = Automation.defaultGraceMinutes, enabled: Bool = true,
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.projectID = projectID
        self.workspace = workspace
        self.reuseSession = reuseSession
        self.triggers = triggers
        self.missedRunGraceMinutes = missedRunGraceMinutes
        self.enabled = enabled
        self.nextRunAt = nil
        self.lastRunAt = nil
        self.lastRunStatus = nil
        self.lastSessionID = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        workspace = (try? c.decodeIfPresent(AutomationWorkspace.self, forKey: .workspace)) ?? .current
        reuseSession = try c.decodeIfPresent(Bool.self, forKey: .reuseSession) ?? false
        // Unknown trigger kinds (written by a newer version) are dropped, not fatal.
        triggers = (try c.decodeIfPresent([Lossy<AutomationTrigger>].self, forKey: .triggers) ?? []).compactMap(\.value)
        missedRunGraceMinutes = try c.decodeIfPresent(Int.self, forKey: .missedRunGraceMinutes) ?? Self.defaultGraceMinutes
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        nextRunAt = try c.decodeIfPresent(Date.self, forKey: .nextRunAt)
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastRunStatus = try? c.decodeIfPresent(AutomationRunStatus.self, forKey: .lastRunStatus)
        lastSessionID = try c.decodeIfPresent(UUID.self, forKey: .lastSessionID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// Earliest occurrence of any trigger strictly after `date`.
    public func nextRunAt(after date: Date, calendar: Calendar = .current) -> Date? {
        triggers.compactMap { $0.nextOccurrence(after: date, calendar: calendar) }.min()
    }

    /// Whether the schedule can fire at all.
    public var isSchedulable: Bool { enabled && projectID != nil && !triggers.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Recomputes `nextRunAt` from `now` (after editing triggers or enabling) so a stale value
    /// neither fires nor gets reported as missed.
    public mutating func reschedule(now: Date = Date(), calendar: Calendar = .current) {
        nextRunAt = isSchedulable ? nextRunAt(after: now, calendar: calendar) : nil
    }
}

public struct AutomationRun: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var automationID: UUID
    public var trigger: AutomationRunTrigger
    public var scheduledFor: Date?
    public var startedAt: Date
    public var completedAt: Date?
    public var status: AutomationRunStatus
    public var sessionID: UUID?
    public var error: String?

    public init(id: UUID = UUID(), automationID: UUID, trigger: AutomationRunTrigger, scheduledFor: Date? = nil,
                startedAt: Date = Date(), status: AutomationRunStatus = .pending) {
        self.id = id
        self.automationID = automationID
        self.trigger = trigger
        self.scheduledFor = scheduledFor
        self.startedAt = startedAt
        self.completedAt = nil
        self.status = status
        self.sessionID = nil
        self.error = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        automationID = try c.decode(UUID.self, forKey: .automationID)
        trigger = (try? c.decodeIfPresent(AutomationRunTrigger.self, forKey: .trigger)) ?? .scheduled
        scheduledFor = try c.decodeIfPresent(Date.self, forKey: .scheduledFor)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        status = (try? c.decodeIfPresent(AutomationRunStatus.self, forKey: .status)) ?? .failed
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// Decodes an element or nil instead of failing the whole array.
struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Due evaluation

/// What the scheduler should do with an automation at `now`.
public struct AutomationDueDecision: Equatable, Sendable {
    /// The occurrence being handled (the latest one that is due).
    public var scheduledFor: Date
    /// Start a run (true), or record it as skipped because it is older than the grace period.
    public var dispatch: Bool
    /// Earlier due occurrences folded into this one (the Mac slept through them).
    public var missedEarlier: Int
    /// The schedule after this claim; always later than `now`.
    public var nextRunAt: Date?
}

public enum AutomationSchedule {
    /// nil when nothing is due. Several overdue occurrences collapse into the latest one, which
    /// runs if it is within the grace period and is skipped otherwise.
    public static func evaluate(_ automation: Automation, now: Date, calendar: Calendar = .current) -> AutomationDueDecision? {
        guard automation.isSchedulable, let first = automation.nextRunAt, first <= now else { return nil }
        var latest = first
        var missed = 0
        // Walk forward to the latest occurrence ≤ now (bounded: hourly for a year of sleep).
        for _ in 0..<10_000 {
            guard let next = automation.nextRunAt(after: latest, calendar: calendar), next <= now, next > latest else { break }
            latest = next
            missed += 1
        }
        let grace = TimeInterval(max(automation.missedRunGraceMinutes, 0) * 60)
        return AutomationDueDecision(
            scheduledFor: latest,
            dispatch: now.timeIntervalSince(latest) <= grace,
            missedEarlier: missed,
            nextRunAt: automation.nextRunAt(after: now, calendar: calendar)
        )
    }
}

// MARK: - DeckData

extension DeckData {
    public static let maxRunsPerAutomation = 50

    public func automation(_ id: UUID) -> Automation? { automations.first { $0.id == id } }

    public func runs(of automationID: UUID) -> [AutomationRun] {
        automationRuns.filter { $0.automationID == automationID }.sorted { $0.startedAt > $1.startedAt }
    }

    public mutating func updateAutomation(_ id: UUID, _ change: (inout Automation) -> Void) {
        guard let i = automations.firstIndex(where: { $0.id == id }) else { return }
        change(&automations[i])
    }

    public mutating func removeAutomation(_ id: UUID) {
        automations.removeAll { $0.id == id }
        automationRuns.removeAll { $0.automationID == id }
    }

    /// Appends a run and keeps only the newest `maxRunsPerAutomation` of that automation.
    public mutating func appendRun(_ run: AutomationRun) {
        automationRuns.append(run)
        let mine = automationRuns.filter { $0.automationID == run.automationID }
        guard mine.count > Self.maxRunsPerAutomation else { return }
        let keep = Set(mine.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maxRunsPerAutomation).map(\.id))
        automationRuns.removeAll { $0.automationID == run.automationID && !keep.contains($0.id) }
    }

    /// Updates a run and mirrors its status onto the automation.
    public mutating func updateRun(_ id: UUID, _ change: (inout AutomationRun) -> Void) {
        guard let i = automationRuns.firstIndex(where: { $0.id == id }) else { return }
        change(&automationRuns[i])
        let run = automationRuns[i]
        updateAutomation(run.automationID) {
            $0.lastRunStatus = run.status
            if let sid = run.sessionID { $0.lastSessionID = sid }
        }
    }

    /// Atomic claim of a scheduled occurrence: only succeeds while `nextRunAt` still equals
    /// `expected`, and advances it before anything is launched, so an occurrence never runs twice.
    /// Returns the new run (pending, or already skipped).
    public mutating func claimDue(_ automationID: UUID, expected: Date, decision: AutomationDueDecision, now: Date) -> AutomationRun? {
        guard let a = automation(automationID), a.isSchedulable, a.nextRunAt == expected, expected <= now else { return nil }
        var run = AutomationRun(automationID: automationID, trigger: .scheduled, scheduledFor: decision.scheduledFor, startedAt: now)
        if !decision.dispatch {
            run.status = .skipped
            run.completedAt = now
            run.error = "Missed the scheduled run beyond its grace period."
        } else if runs(of: automationID).contains(where: { !$0.status.isFinished }) {
            run.status = .skipped
            run.completedAt = now
            run.error = "The previous run was still in progress."
        }
        updateAutomation(automationID) {
            $0.nextRunAt = decision.nextRunAt
            $0.lastRunAt = now
            $0.lastRunStatus = run.status
        }
        appendRun(run)
        return run
    }

    /// On launch: runs left pending/running by a previous app process can't be finished any more.
    public mutating func recoverInterruptedRuns(now: Date = Date()) {
        for i in automationRuns.indices where !automationRuns[i].status.isFinished {
            automationRuns[i].status = .cancelled
            automationRuns[i].completedAt = now
            automationRuns[i].error = "Interrupted when ClaudeDeck quit."
            let run = automationRuns[i]
            updateAutomation(run.automationID) { a in
                if a.lastRunAt.map({ $0 <= run.startedAt }) ?? true { a.lastRunStatus = .cancelled }
            }
        }
    }
}
