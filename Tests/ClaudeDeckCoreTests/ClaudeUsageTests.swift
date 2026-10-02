import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct ClaudeUsageTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func parsesFiveHourAndWeeklyWindows() throws {
        let body = #"""
        {"five_hour": {"utilization": 62.4, "resets_at": "2026-10-02T21:30:00.204799+00:00", "used_dollars": null},
         "seven_day": {"utilization": 18.0, "resets_at": "2026-10-07T09:00:00Z"},
         "seven_day_opus": null, "extra_usage": {"is_enabled": false}, "limits": [], "unknown_new_key": 3}
        """#
        let usage = try #require(ClaudeUsageAPI.parse(Data(body.utf8), now: now))
        #expect(usage.fiveHour?.usedPercent == 62.4)
        #expect(usage.fiveHour?.resetsAt == ClaudeUsageAPI.parseISODate("2026-10-02T21:30:00.204Z"))
        #expect(usage.sevenDay?.usedPercent == 18)
        #expect(usage.sevenDay?.resetsAt == ClaudeUsageAPI.parseISODate("2026-10-07T09:00:00Z"))
        #expect(usage.fetchedAt == now)
        #expect(usage.exhaustedUntil == nil)
    }

    @Test func toleratesOtherShapes() throws {
        let body = #"{"five_hour": {"used_percentage": 140, "resets_at": 1790003600}, "seven_day": {"utilization": 100, "resets_at": 1790100000000}}"#
        let usage = try #require(ClaudeUsageAPI.parse(Data(body.utf8), now: now))
        #expect(usage.fiveHour?.usedPercent == 100) // clamped
        #expect(usage.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_790_003_600))
        #expect(usage.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_790_100_000)) // ms
        #expect(usage.exhaustedUntil == Date(timeIntervalSince1970: 1_790_100_000)) // the later one
    }

    @Test func missingOrBrokenBodies() {
        #expect(ClaudeUsageAPI.parse(Data("nope".utf8)) == nil)
        #expect(ClaudeUsageAPI.parse(Data("[1]".utf8)) == nil)
        let empty = ClaudeUsageAPI.parse(Data(#"{"five_hour": null, "seven_day": {"resets_at": "x"}}"#.utf8))
        #expect(empty?.isEmpty == true)
    }

    @Test func readsTheAccessTokenWithoutTouchingExpiredOnes() {
        let future = Int((now.timeIntervalSince1970 + 3600) * 1000)
        let past = Int((now.timeIntervalSince1970 - 60) * 1000)
        let blob = { (expires: Int) in Data(#"{"claudeAiOauth": {"accessToken": "tok-123", "refreshToken": "r", "expiresAt": \#(expires)}}"#.utf8) }
        #expect(ClaudeUsageAPI.accessToken(fromCredentials: blob(future), now: now) == "tok-123")
        #expect(ClaudeUsageAPI.accessToken(fromCredentials: blob(past), now: now) == nil)
        #expect(ClaudeUsageAPI.accessToken(fromCredentials: Data(#"{"accessToken": "flat"}"#.utf8), now: now) == "flat")
        #expect(ClaudeUsageAPI.accessToken(fromCredentials: Data(#"{"claudeAiOauth": {"accessToken": "  "}}"#.utf8), now: now) == nil)
        #expect(ClaudeUsageAPI.accessToken(fromCredentials: Data("garbage".utf8), now: now) == nil)
    }

    @Test func backsOffOnFailures() {
        #expect(ClaudeUsageAPI.nextDelay(failures: 0) == 300)
        #expect(ClaudeUsageAPI.nextDelay(failures: 1) == 600)
        #expect(ClaudeUsageAPI.nextDelay(failures: 2) == 1200)
        #expect(ClaudeUsageAPI.nextDelay(failures: 10) == 3600)
    }

    @Test func formatsCountdowns() {
        #expect(UsageFormat.countdown(to: now.addingTimeInterval(-5), now: now) == "now")
        #expect(UsageFormat.countdown(to: now.addingTimeInterval(20), now: now) == "1m")
        #expect(UsageFormat.countdown(to: now.addingTimeInterval(47 * 60 + 30), now: now) == "47m")
        #expect(UsageFormat.countdown(to: now.addingTimeInterval(80 * 60), now: now) == "1h 20m")
        #expect(UsageFormat.countdown(to: now.addingTimeInterval(3 * 3600), now: now) == "3h")
        #expect(UsageFormat.countdown(to: now.addingTimeInterval(6 * 86400 + 7 * 3600), now: now) == "6d 7h")
        #expect(UsageFormat.percent(UsageWindow(usedPercent: 61.6, resetsAt: nil)) == "62%")
    }

    @Test func oldSettingsContinueAfterTheLimitByDefault() throws {
        let old = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"continueMessage": "go on", "notifications": false}"#.utf8))
        #expect(old.continueAfterUsageLimit)
        let off = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"continueAfterUsageLimit": false}"#.utf8))
        #expect(off.continueAfterUsageLimit == false)
    }
}

@Suite struct UsageLimitTranscriptTests {
    let istanbul = TimeZone(identifier: "Europe/Istanbul")!

    func date(_ iso: String) -> Date { ClaudeUsageAPI.parseISODate(iso)! }

    func hitLine(_ text: String, at: String = "2026-10-02T20:05:00.000Z") -> String {
        #"{"type":"assistant","isSidechain":false,"timestamp":"\#(at)","error":"rate_limit","isApiErrorMessage":true,"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    @Test func detectsALimitHitWithItsResetTime() {
        // 20:05Z = 23:05 in Istanbul (UTC+3); "resets 3:20am" is the next morning, 00:20Z.
        let chunk = #"{"type":"user","timestamp":"2026-10-02T20:04:00Z","message":{"role":"user","content":"do it"}}"# + "\n"
            + hitLine("You've hit your session limit · resets 3:20am (Europe/Istanbul)")
        #expect(Transcript.lastUsageLimitEvent(in: chunk) == .hit(at: date("2026-10-02T20:05:00Z"), resetsAt: date("2026-10-03T00:20:00Z")))
    }

    @Test func aLaterMessageClearsTheHit() {
        let chunk = hitLine("You've hit your session limit · resets 6am (Europe/Istanbul)") + "\n"
            + #"{"type":"user","timestamp":"2026-10-02T21:00:00Z","message":{"role":"user","content":"continue"}}"#
        #expect(Transcript.lastUsageLimitEvent(in: chunk) == .cleared(at: date("2026-10-02T21:00:00Z")))
    }

    @Test func ignoresOtherErrorsAndSidechains() {
        let stalled = #"{"type":"assistant","timestamp":"2026-10-02T20:00:00Z","error":"server_error","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: Response stalled mid-stream."}]}}"#
        #expect(Transcript.lastUsageLimitEvent(in: stalled) == .cleared(at: date("2026-10-02T20:00:00Z")))
        let side = #"{"type":"assistant","isSidechain":true,"timestamp":"2026-10-02T20:00:00Z","message":{"content":"x"}}"#
        #expect(Transcript.lastUsageLimitEvent(in: side) == nil)
        #expect(Transcript.lastUsageLimitEvent(in: #"{"type":"system","subtype":"x"}"#) == nil)
    }

    @Test func resetTimeFormats() {
        let at = date("2026-10-02T20:05:00Z") // 23:05 Istanbul
        #expect(Transcript.limitResetDate(in: "resets 11:50pm (Europe/Istanbul)", after: at) == date("2026-10-02T20:50:00Z"))
        #expect(Transcript.limitResetDate(in: "resets 10:30pm (Europe/Istanbul)", after: at) == date("2026-10-03T19:30:00Z")) // passed → tomorrow
        #expect(Transcript.limitResetDate(in: "resets 12am (Europe/Istanbul)", after: at) == date("2026-10-02T21:00:00Z"))
        #expect(Transcript.limitResetDate(in: "You've hit your weekly limit · resets Oct 7, 5pm (Europe/Istanbul)", after: at) == date("2026-10-07T14:00:00Z"))
        #expect(Transcript.limitResetDate(in: "resets Oct 7 at 5pm (Europe/Istanbul)", after: at) == date("2026-10-07T14:00:00Z"))
        #expect(Transcript.limitResetDate(in: "Claude AI usage limit reached|1790003600", after: at) == Date(timeIntervalSince1970: 1_790_003_600))
        #expect(Transcript.limitResetDate(in: "You've hit your session limit", after: at) == nil)
    }
}
