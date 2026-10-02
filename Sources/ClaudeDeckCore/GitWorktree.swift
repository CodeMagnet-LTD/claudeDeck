import Foundation

/// One entry of `git worktree list --porcelain`.
public struct GitWorktree: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var head: String?
    /// Short branch name; nil when detached (or bare).
    public var branch: String?
    public var isDetached = false
    public var isBare = false
    /// The repository's main working tree (the first entry); never removed.
    public var isMain = false
    public var lockedReason: String?
    public var isLocked = false
    /// Its directory is gone: `git worktree prune` removes the entry.
    public var prunableReason: String?
    public var isPrunable = false

    public init(path: String) { self.path = path }
}

extension Git {
    public static func worktrees(in repo: URL) -> [GitWorktree] {
        guard let out = run(["worktree", "list", "--porcelain"], in: repo) else { return [] }
        return parseWorktrees(out)
    }

    public static func parseWorktrees(_ output: String) -> [GitWorktree] {
        var result: [GitWorktree] = []
        var current: GitWorktree?
        func flush() {
            if var wt = current {
                wt.isMain = result.isEmpty
                result.append(wt)
            }
            current = nil
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty { flush(); continue }
            let key = line.prefix { $0 != " " }
            let value = line.count > key.count ? String(line.dropFirst(key.count + 1)) : nil
            switch key {
            case "worktree":
                flush()
                current = GitWorktree(path: value ?? "")
            case "HEAD": current?.head = value
            case "branch":
                current?.branch = value.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
            case "detached": current?.isDetached = true
            case "bare": current?.isBare = true
            case "locked":
                current?.isLocked = true
                current?.lockedReason = value
            case "prunable":
                current?.isPrunable = true
                current?.prunableReason = value
            default: break
            }
        }
        flush()
        return result
    }

    /// Uncommitted changes (untracked files included) in a working tree.
    public static func isDirty(worktree path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let out = run(["status", "--porcelain", "-z", "--untracked-files=normal"], in: url) else { return false }
        return !out.isEmpty
    }

    /// Removes a linked worktree. The main working tree is refused; `force` also removes one with
    /// uncommitted changes (git refuses otherwise).
    public static func removeWorktree(_ worktree: GitWorktree, force: Bool, in repo: URL) -> Result {
        if worktree.isMain || worktree.isBare {
            return Result(status: 1, output: "", error: String(localized: "The main working tree can’t be removed."))
        }
        return execute(["worktree", "remove"] + (force ? ["--force"] : []) + [worktree.path], in: repo)
    }

    public static func pruneWorktrees(in repo: URL) -> Result {
        execute(["worktree", "prune", "-v"], in: repo)
    }

    /// Same directory, ignoring symlinks (/var vs /private/var) and trailing slashes.
    public static func samePath(_ a: String, _ b: String) -> Bool {
        let norm = { (p: String) in URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path }
        return norm(a) == norm(b)
    }
}
