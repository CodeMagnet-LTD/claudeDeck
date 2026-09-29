import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct AutomationTests {
    static let nyCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// Local date in New York.
    func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        Self.nyCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func next(_ t: AutomationTrigger, after date: Date) -> Date? {
        t.nextOccurrence(after: date, calendar: Self.nyCalendar)
    }

    // MARK: Triggers

    @Test func hourly() {
        #expect(next(.hourly(minute: 15), after: at(2026, 3, 2, 10, 0)) == at(2026, 3, 2, 10, 15))
        #expect(next(.hourly(minute: 15), after: at(2026, 3, 2, 10, 15)) == at(2026, 3, 2, 11, 15))
        #expect(next(.hourly(minute: 0), after: at(2026, 3, 2, 23, 30)) == at(2026, 3, 3, 0, 0))
    }

    @Test func daily() {
        let t = AutomationTrigger.daily(ClockTime(hour: 9, minute: 0))
        #expect(next(t, after: at(2026, 3, 2, 8, 59)) == at(2026, 3, 2, 9))
        #expect(next(t, after: at(2026, 3, 2, 9)) == at(2026, 3, 3, 9))
    }

    @Test func weekdaysSkipWeekend() {
        let t = AutomationTrigger.weekdays(ClockTime(hour: 9, minute: 0))
        // Friday 2026-03-06 after 9:00 → Monday 2026-03-09.
        #expect(next(t, after: at(2026, 3, 6, 10)) == at(2026, 3, 9, 9))
        // Saturday → Monday.
        #expect(next(t, after: at(2026, 3, 7, 8)) == at(2026, 3, 9, 9))
        // Wednesday before 9 → same day.
        #expect(next(t, after: at(2026, 3, 4, 7)) == at(2026, 3, 4, 9))
    }

    @Test func weekly() {
        // Friday (6) 16:00; 2026-03-02 is a Monday.
        let t = AutomationTrigger.weekly(weekday: 6, ClockTime(hour: 16, minute: 0))
        #expect(next(t, after: at(2026, 3, 2, 12)) == at(2026, 3, 6, 16))
        #expect(next(t, after: at(2026, 3, 6, 16)) == at(2026, 3, 13, 16))
    }

    @Test func dailyAcrossSpringForward() {
        // DST starts in New York on 2026-03-08 (02:00 → 03:00).
        let t = AutomationTrigger.daily(ClockTime(hour: 9, minute: 0))
        let first = next(t, after: at(2026, 3, 6, 12))!
        let second = next(t, after: first)!
        #expect(first == at(2026, 3, 7, 9))
        #expect(Self.nyCalendar.component(.hour, from: second) == 9)
        #expect(second.timeIntervalSince(first) == 23 * 3600)
    }

    @Test func nonexistentTimeStillAdvances() {
        // 02:30 doesn't exist on 2026-03-08; whatever it resolves to must be after the input.
        let t = AutomationTrigger.daily(ClockTime(hour: 2, minute: 30))
        let start = at(2026, 3, 7, 12)
        let n = next(t, after: start)!
        #expect(n > start)
        #expect(next(t, after: n)! > n)
    }

    @Test func automationPicksEarliestTrigger() {
        var a = Automation(prompt: "x", projectID: UUID(), triggers: [
            .weekly(weekday: 2, ClockTime(hour: 9, minute: 0)),
            .daily(ClockTime(hour: 18, minute: 0)),
        ])
        a.reschedule(now: at(2026, 3, 4, 12), calendar: Self.nyCalendar)
        #expect(a.nextRunAt == at(2026, 3, 4, 18))
        a.enabled = false
        a.reschedule(now: at(2026, 3, 4, 12), calendar: Self.nyCalendar)
        #expect(a.nextRunAt == nil)
    }

    // MARK: Due evaluation

    func automation(next: Date, grace: Int = 60) -> Automation {
        var a = Automation(prompt: "do it", projectID: UUID(), triggers: [.hourly(minute: 0)], missedRunGraceMinutes: grace)
        a.nextRunAt = next
        return a
    }

    @Test func notDueYet() {
        #expect(AutomationSchedule.evaluate(automation(next: at(2026, 3, 2, 10)), now: at(2026, 3, 2, 9, 59), calendar: Self.nyCalendar) == nil)
    }

    @Test func dueWithinGrace() throws {
        let d = try #require(AutomationSchedule.evaluate(automation(next: at(2026, 3, 2, 10)), now: at(2026, 3, 2, 10, 0), calendar: Self.nyCalendar))
        #expect(d.dispatch)
        #expect(d.scheduledFor == at(2026, 3, 2, 10))
        #expect(d.missedEarlier == 0)
        #expect(d.nextRunAt == at(2026, 3, 2, 11))
    }

    @Test func overdueCollapsesToLatest() throws {
        // Slept from 10:00 to 13:20: 10, 11, 12, 13 due → 13:00 runs (20 min late, grace 60).
        let d = try #require(AutomationSchedule.evaluate(automation(next: at(2026, 3, 2, 10)), now: at(2026, 3, 2, 13, 20), calendar: Self.nyCalendar))
        #expect(d.scheduledFor == at(2026, 3, 2, 13))
        #expect(d.missedEarlier == 3)
        #expect(d.dispatch)
        #expect(d.nextRunAt == at(2026, 3, 2, 14))
    }

    @Test func beyondGraceIsSkipped() throws {
        var a = automation(next: at(2026, 3, 2, 9), grace: 30)
        a.triggers = [.daily(ClockTime(hour: 9, minute: 0))]
        let d = try #require(AutomationSchedule.evaluate(a, now: at(2026, 3, 2, 10), calendar: Self.nyCalendar))
        #expect(!d.dispatch)
        #expect(d.nextRunAt == at(2026, 3, 3, 9))
    }

    @Test func disabledOrIncompleteNeverDue() {
        var a = automation(next: at(2026, 3, 2, 10))
        a.enabled = false
        #expect(AutomationSchedule.evaluate(a, now: at(2026, 3, 2, 11), calendar: Self.nyCalendar) == nil)
        a.enabled = true
        a.projectID = nil
        #expect(AutomationSchedule.evaluate(a, now: at(2026, 3, 2, 11), calendar: Self.nyCalendar) == nil)
    }

    // MARK: Claim / history

    @Test func claimIsAtomic() throws {
        var deck = DeckData()
        let a = automation(next: at(2026, 3, 2, 10))
        deck.automations = [a]
        let now = at(2026, 3, 2, 10, 0)
        let decision = try #require(AutomationSchedule.evaluate(a, now: now, calendar: Self.nyCalendar))
        let claimed = deck.claimDue(a.id, expected: a.nextRunAt!, decision: decision, now: now)
        let run = try #require(claimed)
        #expect(run.status == .pending)
        #expect(deck.automation(a.id)?.nextRunAt == at(2026, 3, 2, 11))
        // A second claim of the same occurrence fails: nextRunAt already moved on.
        #expect(deck.claimDue(a.id, expected: a.nextRunAt!, decision: decision, now: now) == nil)
        #expect(deck.automationRuns.count == 1)
    }

    @Test func claimSkipsWhilePreviousRunActive() throws {
        var deck = DeckData()
        let a = automation(next: at(2026, 3, 2, 10))
        deck.automations = [a]
        var active = AutomationRun(automationID: a.id, trigger: .manual, startedAt: at(2026, 3, 2, 9, 50))
        active.status = .running
        deck.appendRun(active)
        let now = at(2026, 3, 2, 10)
        let decision = try #require(AutomationSchedule.evaluate(a, now: now, calendar: Self.nyCalendar))
        let claimed = deck.claimDue(a.id, expected: a.nextRunAt!, decision: decision, now: now)
        let run = try #require(claimed)
        #expect(run.status == .skipped)
    }

    @Test func historyIsCapped() {
        var deck = DeckData()
        let a = Automation(prompt: "x")
        let other = Automation(prompt: "y")
        deck.automations = [a, other]
        deck.appendRun(AutomationRun(automationID: other.id, trigger: .manual))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<60 {
            deck.appendRun(AutomationRun(automationID: a.id, trigger: .manual, startedAt: base.addingTimeInterval(Double(i))))
        }
        let runs = deck.runs(of: a.id)
        #expect(runs.count == DeckData.maxRunsPerAutomation)
        #expect(runs.first?.startedAt == base.addingTimeInterval(59))
        #expect(runs.last?.startedAt == base.addingTimeInterval(10))
        #expect(deck.runs(of: other.id).count == 1)
    }

    @Test func recoversInterruptedRuns() {
        var deck = DeckData()
        let a = Automation(prompt: "x")
        deck.automations = [a]
        var run = AutomationRun(automationID: a.id, trigger: .scheduled)
        run.status = .running
        deck.appendRun(run)
        var done = AutomationRun(automationID: a.id, trigger: .manual)
        done.status = .succeeded
        deck.appendRun(done)
        deck.recoverInterruptedRuns()
        #expect(deck.automationRuns.first { $0.id == run.id }?.status == .cancelled)
        #expect(deck.automationRuns.first { $0.id == run.id }?.error == "Interrupted when ClaudeDeck quit.")
        #expect(deck.automationRuns.first { $0.id == done.id }?.status == .succeeded)
    }

    // MARK: Persistence

    func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    @Test func oldDeckWithoutAutomationsDecodes() throws {
        let json = """
        { "version": 1, "groups": [], "projects": [], "sessions": [], "settings": {}, "panes": [] }
        """
        let deck = try decoder().decode(DeckData.self, from: Data(json.utf8))
        #expect(deck.automations.isEmpty)
        #expect(deck.automationRuns.isEmpty)
    }

    @Test func roundTripsAndToleratesUnknownTriggers() throws {
        var deck = DeckData()
        var a = Automation(name: "Bugs", prompt: "find bugs", projectID: UUID(), workspace: .newWorktree, reuseSession: true,
                           triggers: [.hourly(minute: 5), .daily(ClockTime(hour: 7, minute: 30)),
                                      .weekdays(ClockTime(hour: 9, minute: 0)), .weekly(weekday: 6, ClockTime(hour: 16, minute: 0))],
                           createdAt: Date(timeIntervalSince1970: 1_700_000_000)) // whole seconds survive JSON exactly
        a.nextRunAt = Date(timeIntervalSince1970: 1_800_000_000)
        deck.automations = [a]
        deck.appendRun(AutomationRun(automationID: a.id, trigger: .manual, startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(deck)
        let back = try decoder().decode(DeckData.self, from: data)
        #expect(back.automations == deck.automations)
        #expect(back.automationRuns == deck.automationRuns)

        // A trigger kind from a future version is dropped; the automation survives.
        let json = """
        { "automations": [{ "id": "\(UUID().uuidString)", "name": "x", "prompt": "p",
          "triggers": [{ "kind": "github", "event": "pr.opened" }, { "kind": "time", "schedule": "daily", "hour": 8, "minute": 0 }] }] }
        """
        let future = try decoder().decode(DeckData.self, from: Data(json.utf8))
        #expect(future.automations.first?.triggers == [.daily(ClockTime(hour: 8, minute: 0))])
        #expect(future.automations.first?.missedRunGraceMinutes == Automation.defaultGraceMinutes)
    }
}
