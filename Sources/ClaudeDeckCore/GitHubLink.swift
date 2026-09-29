import Foundation

/// A GitHub issue or pull request linked to a session. Details are fetched with the user's `gh`.
public struct LinkedWorkItem: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case issue, pr
    }

    public var kind: Kind
    /// "owner/name".
    public var repo: String
    public var number: Int
    public var url: String
    /// GitHub's `updatedAt` the user last looked at (opening the popover); newer = "updated" dot.
    public var lastSeenUpdatedAt: Date?

    public init(kind: Kind, repo: String, number: Int, url: String? = nil, lastSeenUpdatedAt: Date? = nil) {
        self.kind = kind
        self.repo = repo
        self.number = number
        self.url = url ?? Self.url(repo: repo, kind: kind, number: number)
        self.lastSeenUpdatedAt = lastSeenUpdatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .issue
        repo = try c.decode(String.self, forKey: .repo)
        number = try c.decode(Int.self, forKey: .number)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? Self.url(repo: repo, kind: kind, number: number)
        lastSeenUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenUpdatedAt)
    }

    /// "PR #12" / "#34".
    public var shortLabel: String { kind == .pr ? "PR #\(number)" : "#\(number)" }

    /// Same issue/PR (ignores the seen stamp).
    public func isSameItem(as other: LinkedWorkItem) -> Bool {
        kind == other.kind && number == other.number && repo.lowercased() == other.repo.lowercased()
    }

    public static func url(repo: String, kind: Kind, number: Int) -> String {
        "https://github.com/\(repo)/\(kind == .pr ? "pull" : "issues")/\(number)"
    }

    // MARK: Parsing

    // Adapted from MonoCode (MIT): github.com/owner/repo/(pull|issues)/N.
    private nonisolated(unsafe) static let urlPattern =
        /(?i)(?:https?:\/\/)?(?:www\.)?github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/(pull|pulls|issues)\/(\d+)/
    private nonisolated(unsafe) static let shortPattern = /^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)#(\d+)$/

    /// Parses a GitHub issue/PR URL (`https://github.com/owner/repo/pull/12`, with or without
    /// scheme, trailing path/query/fragment) or `owner/repo#12`. The short form can't tell an
    /// issue from a PR; it is `defaultKind` until resolved with `gh`.
    public static func parse(_ text: String, defaultKind: Kind = .issue) -> LinkedWorkItem? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = input.firstMatch(of: urlPattern) {
            guard let number = Int(m.4), number > 0, isValidRepoPart(String(m.1)), isValidRepoPart(String(m.2)) else { return nil }
            let kind: Kind = m.3.lowercased().hasPrefix("pull") ? .pr : .issue
            return LinkedWorkItem(kind: kind, repo: "\(m.1)/\(m.2)", number: number)
        }
        if let m = input.wholeMatch(of: shortPattern) {
            guard let number = Int(m.3), number > 0, isValidRepoPart(String(m.1)), isValidRepoPart(String(m.2)) else { return nil }
            return LinkedWorkItem(kind: defaultKind, repo: "\(m.1)/\(m.2)", number: number)
        }
        return nil
    }

    /// Whether `text` names an item only in the short `owner/repo#N` form (kind unknown).
    public static func isShortForm(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: shortPattern) != nil
    }

    private static func isValidRepoPart(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".."
    }
}
