import Foundation

// Inbox (open issues / pull requests of a project's repository) and CI check repair.
// Ideas adapted from MonoCode (MIT): github tasks list, failed-check repair with `--log-failed`.

/// One row of the Inbox list: an open issue or pull request (lightweight `gh … list` fields).
public struct GitHubListItem: Sendable, Equatable, Identifiable, Hashable {
    public var kind: LinkedWorkItem.Kind
    public var repo: String
    public var number: Int
    public var title: String
    public var author: String?
    public var labels: [GitHubLabel]
    public var createdAt: Date
    public var updatedAt: Date
    public var url: String
    public var isDraft: Bool

    public var id: String { "\(kind.rawValue):\(repo.lowercased())#\(number)" }
    public var workItem: LinkedWorkItem { LinkedWorkItem(kind: kind, repo: repo, number: number, url: url) }

    public init(kind: LinkedWorkItem.Kind, repo: String, number: Int, title: String, author: String? = nil,
                labels: [GitHubLabel] = [], createdAt: Date, updatedAt: Date? = nil, url: String? = nil, isDraft: Bool = false) {
        self.kind = kind
        self.repo = repo
        self.number = number
        self.title = title
        self.author = author
        self.labels = labels
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.url = url ?? LinkedWorkItem.url(repo: repo, kind: kind, number: number)
        self.isDraft = isDraft
    }

    /// The short prompt typed into a session ("Start Work", event automations).
    public var workPrompt: String {
        Self.workPrompt(kind: kind, number: number, title: title, url: url)
    }

    public static func workPrompt(kind: LinkedWorkItem.Kind, number: Int, title: String?, url: String) -> String {
        let what = kind == .pr ? "pull request" : "issue"
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "Work on this GitHub \(what): #\(number)\(title.isEmpty ? "" : " \(title)")\n\(url)"
    }
}

/// Which open items the Inbox lists.
public enum GitHubInboxFilter: String, Sendable, CaseIterable, Codable {
    case all, assignedToMe, reviewRequested
}

/// A failed check of a pull request, with its GitHub Actions run / job when it is one.
public struct GitHubFailedCheck: Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    public var workflowName: String?
    public var detailsURL: String?
    public var runID: Int64?
    public var jobID: Int64?

    public init(name: String, workflowName: String? = nil, detailsURL: String? = nil) {
        self.name = name
        self.workflowName = workflowName
        self.detailsURL = detailsURL
        let ids: (run: Int64?, job: Int64?) = detailsURL.map(Self.actionsIDs) ?? (nil, nil)
        runID = ids.run
        jobID = ids.job
    }

    public var id: String { jobID.map { "job-\($0)" } ?? runID.map { "run-\($0)-\(name)" } ?? "check-\(name)" }
    /// Logs can be fetched (a GitHub Actions run); external status checks can't.
    public var canRepair: Bool { runID != nil }
    /// "Workflow / job".
    public var displayName: String {
        guard let workflowName, workflowName != name else { return name }
        return "\(workflowName) / \(name)"
    }

    private nonisolated(unsafe) static let actionsPattern = /\/actions\/runs\/(\d+)(?:\/job\/(\d+))?/

    /// `https://github.com/o/r/actions/runs/123/job/456` → (123, 456).
    public static func actionsIDs(_ url: String) -> (run: Int64?, job: Int64?) {
        guard let m = url.firstMatch(of: actionsPattern) else { return (nil, nil) }
        return (Int64(m.1), m.2.flatMap { Int64($0) })
    }
}

/// A "Fix with Claude" request for one failed check run, so the button isn't offered twice.
public struct CIRepairRequest: Codable, Sendable, Equatable {
    /// `CIRepair.key(…)`.
    public var key: String
    public var requestedAt: Date
    public var sessionID: UUID?

    public init(key: String, requestedAt: Date = Date(), sessionID: UUID? = nil) {
        self.key = key
        self.requestedAt = requestedAt
        self.sessionID = sessionID
    }
}

public enum CIRepair {
    /// Characters of failing log sent to Claude (the tail: errors are usually at the end).
    public static let maxLogCharacters = 8_000
    public static let maxRequests = 200

    /// One check run of one PR. A re-run gets a new job id, so a new failure is offered again.
    public static func key(repo: String, number: Int, check: GitHubFailedCheck) -> String {
        "\(repo.lowercased())#\(number):\(check.id)"
    }

    /// `gh run view --log-failed` prints "job\tstep\t2024-01-01T00:00:00.0000000Z text": keeps the
    /// text (and an ANSI-free line), drops empty lines, and keeps the last `maxCharacters`.
    public static func trimLog(_ log: String, maxCharacters: Int = maxLogCharacters) -> String {
        let lines = log.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var text = String(line)
            let parts = text.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 { text = String(parts[2]) }
            if let m = text.firstMatch(of: /^\uFEFF?\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ?/) { text = String(text[m.range.upperBound...]) }
            text = text.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")
            return text
        }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var kept: [String] = []
        var count = 0
        for line in lines.reversed() {
            let cost = line.count + 1
            if count + cost > maxCharacters {
                if kept.isEmpty { kept.append(String(line.suffix(maxCharacters))) }
                break
            }
            kept.append(line)
            count += cost
        }
        let body = kept.reversed().joined(separator: "\n")
        return kept.count < lines.count ? "…(earlier log lines omitted)\n" + body : body
    }

    /// The message typed into the session.
    public static func prompt(repo: String, number: Int, branch: String?, check: GitHubFailedCheck, log: String) -> String {
        var text = "The CI check \"\(check.displayName)\" failed on pull request #\(number) (\(repo))"
        if let branch { text += ", branch \(branch)" }
        text += ".\n"
        if let url = check.detailsURL { text += "Run: \(url)\n" }
        text += "Find the cause and fix it, run the relevant checks locally if possible, and commit the fix. "
        text += "Failing log (tail):\n```\n\(log.isEmpty ? "(no failing log output — open the run for details: gh run view \(check.runID.map(String.init) ?? "") --log-failed)" : log)\n```"
        return text
    }
}

extension DeckData {
    public func ciRepairRequest(_ key: String) -> CIRepairRequest? {
        ciRepairRequests.last { $0.key == key }
    }

    /// Records a repair request (newest `CIRepair.maxRequests` kept).
    public mutating func recordCIRepair(_ request: CIRepairRequest) {
        ciRepairRequests.removeAll { $0.key == request.key }
        ciRepairRequests.append(request)
        if ciRepairRequests.count > CIRepair.maxRequests {
            ciRepairRequests.removeFirst(ciRepairRequests.count - CIRepair.maxRequests)
        }
    }
}

extension GitHub {
    static let listFields = "number,title,author,labels,createdAt,updatedAt,url"

    /// "owner/name" of the repository at `dir` (gh's default remote).
    public static func repository(in dir: URL) -> Result<String, GitHubError> {
        run(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], in: dir).flatMap { out in
            let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.contains("/") ? .success(name) : .failure(GitHubError("Not a GitHub repository."))
        }
    }

    /// Open issues or pull requests of `repo`, newest first.
    public static func list(_ kind: LinkedWorkItem.Kind, repo: String, filter: GitHubInboxFilter = .all, limit: Int = 50) -> Result<[GitHubListItem], GitHubError> {
        var args = [kind.rawValue, "list", "--repo", repo, "--state", "open", "--limit", "\(limit)",
                    "--json", kind == .pr ? listFields + ",isDraft" : listFields]
        switch filter {
        case .all: break
        case .assignedToMe: args += ["--assignee", "@me"]
        case .reviewRequested:
            guard kind == .pr else { return .success([]) }
            args += ["--search", "review-requested:@me"]
        }
        return run(args).flatMap { json in
            do { return .success(try decodeList(Data(json.utf8), kind: kind, repo: repo)) }
            catch { return .failure(GitHubError("Unexpected gh output: \(error.localizedDescription)")) }
        }
    }

    /// The failing steps' log of one Actions job (or the whole run), trimmed for a prompt.
    public static func failedLog(repo: String, check: GitHubFailedCheck) -> Result<String, GitHubError> {
        guard let runID = check.runID else { return .failure(GitHubError("Not a GitHub Actions check.")) }
        var args = ["run", "view", "--repo", repo, "--log-failed"]
        if let jobID = check.jobID { args += ["--job", "\(jobID)"] } else { args.insert("\(runID)", at: 2) }
        return run(args, timeout: 90).map { CIRepair.trimLog($0) }
    }

    private struct RawListAuthor: Decodable { var login: String? }
    private struct RawListItem: Decodable {
        var number: Int
        var title: String
        var author: RawListAuthor?
        var labels: [GitHubLabel]?
        var createdAt: Date
        var updatedAt: Date?
        var url: String?
        var isDraft: Bool?
    }

    public static func decodeList(_ data: Data, kind: LinkedWorkItem.Kind, repo: String) throws -> [GitHubListItem] {
        try jsonDecoder().decode([RawListItem].self, from: data).map {
            GitHubListItem(kind: kind, repo: repo, number: $0.number, title: $0.title, author: $0.author?.login,
                           labels: $0.labels ?? [], createdAt: $0.createdAt, updatedAt: $0.updatedAt, url: $0.url,
                           isDraft: $0.isDraft ?? false)
        }
    }
}
