import Foundation

/// A Claude session asking an agent by itself: `claudedeck-ask "<agent>" "<request>"` in its
/// terminal posts to the local API's `/v1/ask` with a token that only that session has
/// (`CLAUDEDECK_ASK_TOKEN`, never the API's own token). Only approved agents the user lets Claude
/// ask (`claudeCanAsk`) are reachable; the answer comes back as a note, like any other.
public enum AgentAsk {
    public static let path = "/v1/ask"
    public static let maxRequest = 4000

    /// The session whose token this is (`Authorization: Bearer …`), compared in constant time.
    public static func session(for header: String?, tokens: [UUID: String]) -> UUID? {
        guard let presented = AgentBearer.credential(from: header) else { return nil }
        var found: UUID?
        for (session, token) in tokens where AgentBearer.matches(presented, expected: token) { found = session }
        return found
    }

    /// The agents a request names: one by name (case-insensitively), or every allowed one for
    /// an empty name or "all".
    public static func targets(_ name: String, profiles: [AgentProfile], registrations: [AgentRegistration]) -> Result<[AgentProfile], AgentHTTPRequestRefusal> {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted.isEmpty || wanted.lowercased() == "all" {
            let allowed = profiles.filter(\.claudeCanAsk)
            return allowed.isEmpty ? .failure(.init(.error(404, "no_agent_allowed"))) : .success(allowed)
        }
        func same(_ other: String) -> Bool { other.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(wanted) == .orderedSame }
        if let profile = profiles.first(where: { same($0.name) }) {
            return profile.claudeCanAsk ? .success([profile]) : .failure(.init(.error(403, "not_allowed")))
        }
        if registrations.contains(where: { same($0.name) && $0.status != .approved }) { return .failure(.init(.error(409, "not_approved"))) }
        return .failure(.init(.error(404, "unknown_agent")))
    }

    /// The agents Claude may ask, for `GET /v1/ask` and `claudedeck-ask --list`.
    public static func list(_ profiles: [AgentProfile]) -> [String] { profiles.filter(\.claudeCanAsk).map(\.name) }

    /// `agent=…&request=…` (form-encoded, what `curl --data-urlencode` sends).
    public static func form(_ body: Data) -> (agent: String, request: String)? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        let items = AgentHTTP.queryItems(text)
        guard let agent = items["agent"] else { return nil }
        let request = (items["request"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (agent, String(request.prefix(maxRequest)))
    }

    /// The command put in every Claude session's reach. It holds no secret: the token is in the
    /// session's environment only.
    public static let script = #"""
    #!/bin/sh
    # claudedeck-ask: ask a ClaudeDeck agent about this Claude session. The answer comes back to
    # the user as a note in ClaudeDeck (they decide whether it reaches Claude).
    #   claudedeck-ask "<agent>" "<what to look at>"
    #   claudedeck-ask all "<what to look at>"     every agent you may ask
    #   claudedeck-ask --list                      the agents you may ask
    case "${1:-}" in
      ""|-h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
    if [ -z "${CLAUDEDECK_ASK_TOKEN:-}" ] || [ -z "${CLAUDEDECK_ASK_URL:-}" ]; then
      echo "claudedeck-ask: only works in a ClaudeDeck session started after ClaudeDeck 0.5.0." >&2; exit 2
    fi
    if [ "$1" = "--list" ]; then
      out=$(curl -sS -m 10 -w '\n%{http_code}' -H "Authorization: Bearer $CLAUDEDECK_ASK_TOKEN" "$CLAUDEDECK_ASK_URL" 2>&1)
    else
      out=$(curl -sS -m 30 -w '\n%{http_code}' -H "Authorization: Bearer $CLAUDEDECK_ASK_TOKEN" \
        --data-urlencode "agent=$1" --data-urlencode "request=${2:-}" "$CLAUDEDECK_ASK_URL" 2>&1)
    fi
    code=$(printf '%s\n' "$out" | tail -n 1)
    body=$(printf '%s\n' "$out" | sed '$d')
    case "$code" in
      2??) printf '%s\n' "$body"; exit 0 ;;
      000) echo "claudedeck-ask: ClaudeDeck's local API is off. Turn it on in Settings > Agents." >&2; exit 1 ;;
      *) printf 'claudedeck-ask: %s (HTTP %s)\n' "$body" "$code" >&2; exit 1 ;;
    esac
    """# + "\n"
}

/// Asks a Claude session may make by itself: at most `maxAsks` in `window` per session.
public struct AgentAskLimiter: Sendable, Equatable {
    public static let maxAsks = 5
    public static let window: TimeInterval = 10 * 60
    private var asks: [UUID: [Date]] = [:]

    public init() {}

    public mutating func allow(_ session: UUID, now: Date = Date()) -> Bool {
        var recent = (asks[session] ?? []).filter { now.timeIntervalSince($0) < Self.window }
        guard recent.count < Self.maxAsks else { asks[session] = recent; return false }
        recent.append(now)
        asks[session] = recent
        return true
    }
}
