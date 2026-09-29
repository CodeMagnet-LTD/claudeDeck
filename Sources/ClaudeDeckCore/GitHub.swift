import Foundation

/// Whether the GitHub CLI can be used.
public enum GitHubAvailability: Sendable, Equatable {
    /// `gh` not found (login shell PATH, Homebrew locations).
    case missing
    /// `gh` found but `gh auth status` fails: the user has to run `gh auth login`.
    case unauthenticated
    case ready
}

public struct GitHubError: Error, Sendable, Equatable, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct GitHubLabel: Sendable, Equatable, Hashable, Decodable {
    public var name: String
    /// Hex without "#", e.g. "d73a4a".
    public var color: String?
}

/// A comment or a review on an issue / pull request.
public struct GitHubComment: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case comment, review }
    public var id: String
    public var kind: Kind
    public var author: String
    public var body: String
    public var createdAt: Date
    public var url: String?
    /// Reviews: APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, PENDING.
    public var reviewState: String?
}

/// Aggregated CI result of a pull request's `statusCheckRollup`.
public struct GitHubChecks: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable { case passed, failed, pending }
    public var passed = 0
    public var failed = 0
    public var pending = 0
    /// Other terminal results that are neither success nor failure (SKIPPED, NEUTRAL, STALE).
    public var skipped = 0
    public var failedNames: [String] = []

    public var total: Int { passed + failed + pending + skipped }
    public var outcome: Outcome { failed > 0 ? .failed : pending > 0 ? .pending : .passed }
}

/// The display state used for the badge color.
public enum GitHubItemState: String, Sendable, Equatable {
    case open, draft, merged, closed
}

/// Everything shown in the linked-item popover, from `gh {issue|pr} view --json …`.
public struct GitHubItemDetails: Sendable, Equatable {
    public var kind: LinkedWorkItem.Kind
    public var number: Int
    public var title: String
    /// OPEN, CLOSED, MERGED.
    public var state: String
    public var isDraft: Bool
    public var labels: [GitHubLabel]
    public var author: String?
    public var body: String
    public var updatedAt: Date
    public var url: String
    /// Comments and reviews (non-empty bodies or a review verdict), oldest first; spam-hidden ones dropped.
    public var comments: [GitHubComment]
    // Pull requests only.
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED; nil when none.
    public var reviewDecision: String?
    public var checks: GitHubChecks?
    public var headRefName: String?
    public var mergeStateStatus: String?

    public var displayState: GitHubItemState {
        switch state.uppercased() {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: isDraft ? .draft : .open
        }
    }
}

/// Something that happened to a linked item between two polls (for the notification text).
public enum GitHubChange: Sendable, Equatable {
    case merged, closed, reopened
    case ciFailed, ciPassed
    case approved, changesRequested
    case newReview(author: String)
    case newComments(count: Int, lastAuthor: String)
    case updated
}

/// The user's GitHub CLI (`gh`). No tokens are stored in the app: every call runs `gh`
/// with the account the user logged in with. All functions block — call off the main thread.
public enum GitHub {
    // MARK: Locating gh

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var resolved = false
        var path: String?
    }
    private static let cache = Cache()

    /// Absolute path of `gh`, or nil. `CLAUDEDECK_GH_PATH` overrides it. GUI apps don't inherit
    /// the shell PATH, so Homebrew locations are probed, then the login shell is asked.
    /// A miss is not cached (the user may install gh while the app runs).
    public static func executable() -> String? {
        cache.lock.lock()
        if cache.resolved, let path = cache.path, FileManager.default.isExecutableFile(atPath: path) {
            cache.lock.unlock()
            return path
        }
        cache.lock.unlock()
        let path = locate()
        cache.lock.lock()
        cache.resolved = path != nil
        cache.path = path
        cache.lock.unlock()
        return path
    }

    private static func locate() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let path = env["CLAUDEDECK_GH_PATH"], !path.isEmpty { return path }
        for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let shell = env["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        for flags in ["-lc", "-lic"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = [flags, "command -v gh"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            // A prompting or slow rc file must not hang the caller.
            let deadline = Date().addingTimeInterval(8)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate(); continue }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if let line = text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces),
               line.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: line) {
                return line
            }
        }
        return nil
    }

    // MARK: Running gh

    /// Runs `gh args` in `dir`; stdout on success, gh's error message otherwise.
    public static func run(_ args: [String], in dir: URL? = nil, timeout: TimeInterval = 30) -> Result<String, GitHubError> {
        guard let gh = executable() else { return .failure(GitHubError("GitHub CLI (gh) is not installed.")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = args
        p.currentDirectoryURL = dir ?? FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_PAGER"] = "cat"
        env["NO_COLOR"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        // gh shells out to git for repo detection: a real git (never the /usr/bin/git shim) first.
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for dir in [Git.executable?.deletingLastPathComponent().path, (gh as NSString).deletingLastPathComponent].compactMap({ $0 }).reversed()
            where !path.contains(dir) {
            path.insert(dir, at: 0)
        }
        env["PATH"] = path.joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(GitHubError(error.localizedDescription)) }
        // Both pipes are drained concurrently so a chatty stderr can't block the child.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        group.wait()
        let stdout = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0 else {
            let stderr = String(decoding: errBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = !stderr.isEmpty ? stderr : !stdout.isEmpty ? stdout : "gh \(args.first ?? "") failed"
            return .failure(GitHubError(detail))
        }
        return .success(stdout)
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }

    // MARK: Queries

    /// Installed and logged in to github.com?
    public static func availability() -> GitHubAvailability {
        guard executable() != nil else { return .missing }
        switch run(["auth", "status", "--hostname", "github.com"], timeout: 15) {
        case .success: return .ready
        case .failure: return .unauthenticated
        }
    }

    static let issueFields = "number,title,state,labels,author,body,updatedAt,url,comments"
    static let prFields = issueFields + ",isDraft,reviewDecision,statusCheckRollup,headRefName,mergeStateStatus,latestReviews"

    /// `gh {issue|pr} view N --repo R --json …`.
    public static func view(_ item: LinkedWorkItem) -> Result<GitHubItemDetails, GitHubError> {
        let fields = item.kind == .pr ? prFields : issueFields
        let args = [item.kind.rawValue, "view", "\(item.number)", "--repo", item.repo, "--json", fields]
        return run(args).flatMap { json in
            do { return .success(try decodeDetails(Data(json.utf8), kind: item.kind)) }
            catch { return .failure(GitHubError("Unexpected gh output: \(error.localizedDescription)")) }
        }
    }

    /// For `owner/repo#N`: a pull request if `gh pr view` finds one, otherwise an issue.
    public static func resolveKind(_ item: LinkedWorkItem) -> LinkedWorkItem {
        let asPR = LinkedWorkItem(kind: .pr, repo: item.repo, number: item.number, lastSeenUpdatedAt: item.lastSeenUpdatedAt)
        if case .success(let json) = run(["pr", "view", "\(item.number)", "--repo", item.repo, "--json", "url"]),
           let url = (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)))?["url"],
           let parsed = LinkedWorkItem.parse(url), parsed.kind == .pr {
            return asPR
        }
        return LinkedWorkItem(kind: .issue, repo: item.repo, number: item.number, lastSeenUpdatedAt: item.lastSeenUpdatedAt)
    }

    /// Posts a comment (the body goes through a temporary file, never the command line).
    public static func comment(on item: LinkedWorkItem, body: String) -> Result<Void, GitHubError> {
        let file = FileManager.default.temporaryDirectory.appending(path: "claudedeck-gh-comment-\(UUID().uuidString).md")
        do { try Data(body.utf8).write(to: file) } catch { return .failure(GitHubError(error.localizedDescription)) }
        defer { try? FileManager.default.removeItem(at: file) }
        return run([item.kind.rawValue, "comment", "\(item.number)", "--repo", item.repo, "--body-file", file.path]).map { _ in () }
    }

    /// The pull request for `branch` of the repository at `dir` (open ones first, then the newest).
    public static func pullRequest(forBranch branch: String, in dir: URL) -> Result<LinkedWorkItem?, GitHubError> {
        run(["pr", "list", "--head", branch, "--json", "number,url,state", "--state", "all", "--limit", "10"], in: dir).flatMap { json in
            do { return .success(try decodeBranchPullRequest(Data(json.utf8))) }
            catch { return .failure(GitHubError("Unexpected gh output: \(error.localizedDescription)")) }
        }
    }

    // MARK: Decoding

    private struct RawAuthor: Decodable { var login: String? }
    private struct RawComment: Decodable {
        var id: String?
        var author: RawAuthor?
        var body: String?
        var createdAt: Date?
        var url: String?
        var isMinimized: Bool?
    }
    private struct RawReview: Decodable {
        var id: String?
        var author: RawAuthor?
        var body: String?
        var submittedAt: Date?
        var state: String?
    }
    /// `statusCheckRollup` entries: `CheckRun` (status/conclusion/name) or `StatusContext` (state/context).
    private struct RawCheck: Decodable {
        var typename: String?
        var name: String?
        var context: String?
        var status: String?
        var conclusion: String?
        var state: String?
        enum CodingKeys: String, CodingKey {
            case typename = "__typename", name, context, status, conclusion, state
        }
    }
    private struct RawItem: Decodable {
        var number: Int
        var title: String
        var state: String
        var isDraft: Bool?
        var labels: [GitHubLabel]?
        var author: RawAuthor?
        var body: String?
        var updatedAt: Date
        var url: String
        var comments: [RawComment]?
        var reviewDecision: String?
        var statusCheckRollup: [RawCheck]?
        var headRefName: String?
        var mergeStateStatus: String?
        var latestReviews: [RawReview]?
    }

    static func jsonDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(text)")
        }
        return d
    }

    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    public static func decodeDetails(_ data: Data, kind: LinkedWorkItem.Kind) throws -> GitHubItemDetails {
        let raw = try jsonDecoder().decode(RawItem.self, from: data)
        var comments: [GitHubComment] = (raw.comments ?? []).enumerated().compactMap { i, c in
            guard c.isMinimized != true, let at = c.createdAt else { return nil }
            let body = (c.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return GitHubComment(id: c.id.flatMap { $0.isEmpty ? nil : $0 } ?? "comment-\(i)", kind: .comment,
                                 author: c.author?.login ?? "ghost", body: body, createdAt: at, url: c.url, reviewState: nil)
        }
        comments += (raw.latestReviews ?? []).compactMap { r in
            guard let at = r.submittedAt else { return nil }
            let author = r.author?.login ?? "ghost"
            // `latestReviews` ids are often empty; author + time is stable across polls.
            let id = r.id.flatMap { $0.isEmpty ? nil : $0 } ?? "review-\(author)-\(Int(at.timeIntervalSince1970))"
            return GitHubComment(id: id, kind: .review,
                                 author: author, body: (r.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                 createdAt: at, url: nil, reviewState: r.state)
        }
        comments.sort { $0.createdAt < $1.createdAt }
        return GitHubItemDetails(
            kind: kind,
            number: raw.number,
            title: raw.title,
            state: raw.state.uppercased(),
            isDraft: raw.isDraft ?? false,
            labels: raw.labels ?? [],
            author: raw.author?.login,
            body: raw.body ?? "",
            updatedAt: raw.updatedAt,
            url: raw.url,
            comments: comments,
            reviewDecision: raw.reviewDecision.flatMap { $0.isEmpty ? nil : $0 },
            checks: kind == .pr ? summarizeChecks(raw.statusCheckRollup ?? []) : nil,
            headRefName: raw.headRefName.flatMap { $0.isEmpty ? nil : $0 },
            mergeStateStatus: raw.mergeStateStatus.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func summarizeChecks(_ checks: [RawCheck]) -> GitHubChecks? {
        guard !checks.isEmpty else { return nil }
        var result = GitHubChecks()
        for check in checks {
            let name = check.name ?? check.context ?? "check"
            if check.typename == "StatusContext" || (check.status == nil && check.state != nil) {
                switch (check.state ?? "").uppercased() {
                case "SUCCESS": result.passed += 1
                case "FAILURE", "ERROR": result.failed += 1; result.failedNames.append(name)
                default: result.pending += 1   // PENDING, EXPECTED
                }
                continue
            }
            guard (check.status ?? "").uppercased() == "COMPLETED" else { result.pending += 1; continue }
            switch (check.conclusion ?? "").uppercased() {
            case "SUCCESS": result.passed += 1
            case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE":
                result.failed += 1
                result.failedNames.append(name)
            default: result.skipped += 1   // SKIPPED, NEUTRAL, STALE
            }
        }
        return result
    }

    private struct RawBranchPR: Decodable {
        var number: Int
        var url: String
        var state: String?
    }

    static func decodeBranchPullRequest(_ data: Data) throws -> LinkedWorkItem? {
        let rows = try JSONDecoder().decode([RawBranchPR].self, from: data)
        // gh lists newest first; prefer an open one.
        let pick = rows.first { ($0.state ?? "").uppercased() == "OPEN" } ?? rows.first
        guard let pick, let parsed = LinkedWorkItem.parse(pick.url), parsed.kind == .pr else { return nil }
        return parsed
    }

    // MARK: Changes

    /// What changed between two fetches of the same item, most important first.
    public static func changes(from old: GitHubItemDetails, to new: GitHubItemDetails) -> [GitHubChange] {
        guard new.updatedAt > old.updatedAt || new.checks?.outcome != old.checks?.outcome else { return [] }
        var result: [GitHubChange] = []
        let (was, now) = (old.displayState, new.displayState)
        if now != was {
            switch now {
            case .merged: result.append(.merged)
            case .closed: result.append(.closed)
            case .open, .draft: if was == .closed || was == .merged { result.append(.reopened) }
            }
        }
        if let checks = new.checks, checks.outcome != old.checks?.outcome {
            if checks.outcome == .failed { result.append(.ciFailed) }
            else if checks.outcome == .passed, old.checks != nil { result.append(.ciPassed) }
        }
        if new.reviewDecision != old.reviewDecision {
            if new.reviewDecision == "APPROVED" { result.append(.approved) }
            else if new.reviewDecision == "CHANGES_REQUESTED" { result.append(.changesRequested) }
        }
        let oldIDs = Set(old.comments.map(\.id))
        let added = new.comments.filter { !oldIDs.contains($0.id) && $0.createdAt > old.updatedAt.addingTimeInterval(-1) }
        let reviews = added.filter { $0.kind == .review }
        let comments = added.filter { $0.kind == .comment }
        if let review = reviews.last, !result.contains(.approved), !result.contains(.changesRequested) {
            result.append(.newReview(author: review.author))
        }
        if let last = comments.last { result.append(.newComments(count: comments.count, lastAuthor: last.author)) }
        if result.isEmpty, new.updatedAt > old.updatedAt { result.append(.updated) }
        return result
    }
}
