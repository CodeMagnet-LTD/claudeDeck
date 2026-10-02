import Foundation

// Claude plan usage (5-hour and weekly windows) from the endpoint Claude Code's own `/usage` uses,
// and the "you've hit your limit" entries Claude Code writes into transcripts.
//
// The OAuth credential belongs to Claude Code: it is only read (never refreshed, rotated or
// written) and never logged. An expired token simply means "unavailable" until Claude Code
// refreshes it itself.

/// One usage window: how much of it is used and when it resets.
public struct UsageWindow: Sendable, Equatable {
    /// Percent of the window used, 0–100.
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = UsageWindow.clamp(usedPercent)
        self.resetsAt = resetsAt
    }

    public var isExhausted: Bool { usedPercent >= 100 }

    static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(100, max(0, value)) : 0
    }
}

/// The plan's usage as reported by `api/oauth/usage`.
public struct ClaudeUsage: Sendable, Equatable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var fetchedAt: Date

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
    }

    public var isEmpty: Bool { fiveHour == nil && sevenDay == nil }

    /// When the plan is usable again if a window is used up (the later reset when both are).
    public var exhaustedUntil: Date? {
        [fiveHour, sevenDay].compactMap { $0 }.filter(\.isExhausted).compactMap(\.resetsAt).max()
    }
}

/// What the usage meter shows.
public enum UsageState: Sendable, Equatable {
    /// Not fetched yet.
    case idle
    /// No Claude sign-in (or it expired / the account has no plan usage): the meter hides.
    case unavailable
    case ok(ClaudeUsage)
    /// The last fetch failed; `last` is the last good value, shown as stale.
    case failed(last: ClaudeUsage?)

    public var usage: ClaudeUsage? {
        switch self {
        case .ok(let usage): usage
        case .failed(let last): last
        case .idle, .unavailable: nil
        }
    }
}

public enum ClaudeUsageAPI {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"
    public static let userAgent = "claude-code/2.1.0"
    public static let keychainService = "Claude Code-credentials"
    public static let pollInterval: TimeInterval = 5 * 60

    /// Parses the usage response: `{"five_hour": {"utilization": 62.0, "resets_at": "…"}, "seven_day": {…}, …}`.
    /// Unknown keys are ignored. Returns nil for a body that isn't a JSON object.
    public static func parse(_ data: Data, now: Date = Date()) -> ClaudeUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ClaudeUsage(fiveHour: window(object["five_hour"]), sevenDay: window(object["seven_day"]), fetchedAt: now)
    }

    static func window(_ raw: Any?) -> UsageWindow? {
        guard let rec = raw as? [String: Any] else { return nil }
        let used = number(rec["utilization"]) ?? number(rec["used_percentage"]) ?? number(rec["usedPercent"])
        guard let used else { return nil }
        return UsageWindow(usedPercent: used, resetsAt: timestamp(rec["resets_at"] ?? rec["resetsAt"]))
    }

    static func number(_ raw: Any?) -> Double? {
        if let n = raw as? NSNumber, !(raw is Bool) { return n.doubleValue }
        if let s = raw as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Epoch seconds or milliseconds (numbers or numeric strings), or an ISO 8601 date with any
    /// number of fractional digits.
    public static func timestamp(_ raw: Any?) -> Date? {
        if let value = number(raw) {
            guard value.isFinite, value > 0 else { return nil }
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
        }
        guard let string = (raw as? String)?.trimmingCharacters(in: .whitespaces), !string.isEmpty else { return nil }
        return parseISODate(string)
    }

    static func parseISODate(_ string: String) -> Date? {
        // ISO8601DateFormatter takes at most millisecond precision: cut longer fractions to 3 digits.
        var s = string
        if let dot = s.firstIndex(of: "."), s.contains("T") {
            let digits = s[s.index(after: dot)...].prefix(while: \.isNumber)
            if digits.count > 3 {
                s.replaceSubrange(s.index(after: dot)..<digits.endIndex, with: digits.prefix(3))
            }
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// The access token in Claude Code's credentials blob (Keychain item or `.credentials.json`),
    /// or nil when there is none or it has expired. A missing expiry counts as usable — the
    /// request itself fails if it isn't.
    public static func accessToken(fromCredentials blob: Data, now: Date = Date()) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: blob) as? [String: Any] else { return nil }
        let oauth = object["claudeAiOauth"] as? [String: Any] ?? object
        guard let token = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        if let expires = number(oauth["expiresAt"]) {
            let expiry = Date(timeIntervalSince1970: expires > 10_000_000_000 ? expires / 1000 : expires)
            if now >= expiry { return nil }
        }
        return token
    }

    /// Seconds until the next fetch: the normal interval, doubled per consecutive failure up to an hour.
    public static func nextDelay(failures: Int, base: TimeInterval = pollInterval) -> TimeInterval {
        guard failures > 0 else { return base }
        return min(3600, base * pow(2, Double(min(failures, 6))))
    }
}

public enum UsageFormat {
    /// "47m", "3h 54m", "6d 7h"; "now" once passed.
    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return String(localized: "now") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return String(localized: "\(max(minutes, 1))m") }
        let hours = minutes / 60, mins = minutes % 60
        if hours >= 24 {
            let days = hours / 24, rem = hours % 24
            return rem > 0 ? String(localized: "\(days)d \(rem)h") : String(localized: "\(days)d")
        }
        return mins > 0 ? String(localized: "\(hours)h \(mins)m") : String(localized: "\(hours)h")
    }

    public static func percent(_ window: UsageWindow) -> String {
        "\(Int(window.usedPercent.rounded()))%"
    }
}

// MARK: - Usage limit in the transcript

/// The last limit-relevant entry in a transcript chunk.
public enum UsageLimitEvent: Sendable, Equatable {
    /// Claude stopped on the plan's usage limit ("You've hit your session limit · resets 3:20am (Europe/Istanbul)").
    case hit(at: Date, resetsAt: Date?)
    /// A later regular message (the user carried on, or the session works again).
    case cleared(at: Date)
}

extension Transcript {
    /// The last usage-limit hit, or a later main-thread message that supersedes it, in a chunk of
    /// complete JSONL lines. nil when the chunk has neither.
    public static func lastUsageLimitEvent(in chunk: String) -> UsageLimitEvent? {
        for line in chunk.split(separator: "\n").reversed() {
            guard line.contains("\"user\"") || line.contains("\"assistant\""),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  object["isSidechain"] as? Bool != true
            else { continue }
            let at = (object["timestamp"] as? String).flatMap(parseDate) ?? Date()
            if type == "assistant", object["error"] as? String == "rate_limit" || object["isApiErrorMessage"] as? Bool == true,
               let text = messageText(object), isUsageLimitText(text) {
                return .hit(at: at, resetsAt: limitResetDate(in: text, after: at))
            }
            // Tool results and meta lines (e.g. "[Request interrupted…]") count as activity too.
            return .cleared(at: at)
        }
        return nil
    }

    static func messageText(_ object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String { return s }
        return (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.first
    }

    static func isUsageLimitText(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("hit your") && lower.contains("limit") || lower.contains("usage limit reached")
    }

    /// The reset time in a limit message, as the first such moment after `after` (the entry's time):
    /// "resets 3:20am (Europe/Istanbul)", "resets 6am", "resets Oct 7, 5pm (…)", "resets Oct 7 at 5pm",
    /// or the old "Claude AI usage limit reached|1738425600".
    public static func limitResetDate(in text: String, after: Date) -> Date? {
        if let bar = text.range(of: "limit reached|"),
           let epoch = Double(text[bar.upperBound...].prefix(while: \.isNumber)) {
            return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
        }
        let pattern = #"resets\s+(?:(?:on\s+)?([A-Za-z]{3,9})\s+(\d{1,2}),?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)(?:\s*\(([^)]+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? {
            Range(m.range(at: i), in: text).map { String(text[$0]) }
        }
        guard var hour = group(3).flatMap(Int.init), (1...12).contains(hour) else { return nil }
        let minute = group(4).flatMap(Int.init) ?? 0
        let pm = group(5)?.lowercased() == "pm"
        hour = hour % 12 + (pm ? 12 : 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = group(6).flatMap { TimeZone(identifier: $0.trimmingCharacters(in: .whitespaces)) } ?? .current
        var wanted = DateComponents(hour: hour, minute: minute, second: 0)
        if let monthName = group(1), let day = group(2).flatMap(Int.init) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let month = months.firstIndex(of: String(monthName.lowercased().prefix(3))) else { return nil }
            wanted.month = month + 1
            wanted.day = day
        }
        return calendar.nextDate(after: after, matching: wanted, matchingPolicy: .nextTime)
    }
}
