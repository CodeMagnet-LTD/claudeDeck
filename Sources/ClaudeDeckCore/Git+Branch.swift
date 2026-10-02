import Foundation

/// A local or remote-tracking branch (`git for-each-ref`).
public struct GitBranch: Sendable, Hashable, Identifiable {
    public var id: String { (isRemote ? "remote:" : "local:") + name }
    /// Short name: "main", "feature/x" or, for remote branches, "origin/feature/x".
    public var name: String
    public var isRemote: Bool
    /// The checked-out branch.
    public var isCurrent: Bool
    /// "origin/main" for a local branch that tracks one.
    public var upstream: String?
    public var date: Date?

    public init(name: String, isRemote: Bool, isCurrent: Bool = false, upstream: String? = nil, date: Date? = nil) {
        self.name = name
        self.isRemote = isRemote
        self.isCurrent = isCurrent
        self.upstream = upstream
        self.date = date
    }

    /// For a remote branch: the local name a checkout creates ("origin/feature/x" → "feature/x").
    public var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

extension Git {
    /// Checked-out branch of the repository at `dir`; nil when detached or not a repository.
    public static func currentBranch(in dir: URL) -> String? {
        guard let out = run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir) else { return nil }
        let branch = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty || branch == "HEAD" ? nil : branch
    }

    // MARK: Branches

    static let branchFormat = ["%(refname)", "%(HEAD)", "%(upstream:short)", "%(committerdate:unix)", "%(symref)"]
        .joined(separator: "%1f")

    /// Local branches (current first, then by name) followed by remote branches.
    public static func branches(in repo: URL) -> [GitBranch] {
        guard let out = run(["for-each-ref", "--format=\(branchFormat)", "refs/heads", "refs/remotes"], in: repo) else { return [] }
        return parseBranches(out)
    }

    public static func parseBranches(_ output: String) -> [GitBranch] {
        var local: [GitBranch] = [], remote: [GitBranch] = []
        for line in output.split(separator: "\n") {
            let f = line.components(separatedBy: fieldSeparator)
            guard f.count >= 5, f[4].isEmpty else { continue }   // symbolic refs: origin/HEAD
            let date = TimeInterval(f[3]).map { Date(timeIntervalSince1970: $0) }
            if f[0].hasPrefix("refs/heads/") {
                local.append(GitBranch(name: String(f[0].dropFirst("refs/heads/".count)), isRemote: false,
                                       isCurrent: f[1] == "*", upstream: f[2].isEmpty ? nil : f[2], date: date))
            } else if f[0].hasPrefix("refs/remotes/") {
                remote.append(GitBranch(name: String(f[0].dropFirst("refs/remotes/".count)), isRemote: true, date: date))
            }
        }
        local.sort { ($0.isCurrent ? 0 : 1, $0.name) < ($1.isCurrent ? 0 : 1, $1.name) }
        remote.sort { $0.name < $1.name }
        return local + remote
    }

    /// Why `name` can't be a new branch, or nil if it can. Git's own rules (`check-ref-format`).
    public static func branchNameProblem(_ name: String, existing: [GitBranch], in repo: URL) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return String(localized: "Enter a branch name.") }
        if existing.contains(where: { !$0.isRemote && $0.name == trimmed }) {
            return String(localized: "A branch named “\(trimmed)” already exists.")
        }
        if !execute(["check-ref-format", "--branch", trimmed], in: repo, timeout: 10).succeeded || trimmed.hasPrefix("-") {
            return String(localized: "“\(trimmed)” isn’t a valid branch name.")
        }
        return nil
    }

    /// Switches to a local branch, or checks out a remote one as a new tracking branch (reusing a
    /// local branch of the same name if there is one).
    public static func checkout(_ branch: GitBranch, existing: [GitBranch], in repo: URL) -> Result {
        guard branch.isRemote else { return execute(["checkout", branch.name, "--"], in: repo) }
        let local = branch.localName
        if existing.contains(where: { !$0.isRemote && $0.name == local }) {
            return execute(["checkout", local, "--"], in: repo)
        }
        return execute(["checkout", "-b", local, "--track", branch.name, "--"], in: repo)
    }

    /// A new branch at the current HEAD, checked out.
    public static func createBranch(_ name: String, in repo: URL) -> Result {
        execute(["checkout", "-b", name], in: repo)
    }

    /// Stashes all changes (untracked included) under a recognisable message. The stash is kept;
    /// the user applies it when they come back.
    public static func stashAll(message: String, in repo: URL) -> Result {
        execute(["stash", "push", "--include-untracked", "-m", message], in: repo)
    }
}
