import Foundation

/// One changed file in one area of the Changes view. A file modified both in the index and in
/// the working tree (`MM`) appears twice, once per area.
public struct GitChange: Sendable, Hashable, Identifiable {
    public enum Area: String, Sendable { case staged, unstaged, untracked, conflicted }

    public var id: String { "\(area.rawValue):\(path)" }
    /// Repo-relative path (the new path for renames).
    public var path: String
    /// Source path of a rename or copy.
    public var originalPath: String?
    public var area: Area
    public var state: GitFileState
    /// nil for binary files (or when unknown).
    public var additions: Int?
    public var deletions: Int?

    public init(path: String, originalPath: String? = nil, area: Area, state: GitFileState,
                additions: Int? = nil, deletions: Int? = nil) {
        self.path = path
        self.originalPath = originalPath
        self.area = area
        self.state = state
        self.additions = additions
        self.deletions = deletions
    }

    public var isStaged: Bool { area == .staged }
}

/// Branch, upstream and the changed files of a repository (`git status --porcelain=v2`).
public struct GitRepoStatus: Sendable, Equatable {
    /// nil when HEAD is detached.
    public var branch: String?
    /// No commit yet (`git init` without a first commit).
    public var isUnborn = false
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var staged: [GitChange] = []
    /// Working tree changes, untracked and conflicted files.
    public var unstaged: [GitChange] = []

    public init() {}

    public var hasChanges: Bool { !staged.isEmpty || !unstaged.isEmpty }
}

extension Git {
    // MARK: Status

    public static func repoStatus(in repo: URL) -> GitRepoStatus? {
        guard let out = run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: repo) else { return nil }
        var status = parseStatusV2(out)
        if status.hasChanges {
            let unstagedCounts = parseNumstat(run(["diff", "--numstat", "-z", "--no-ext-diff"], in: repo) ?? "")
            let stagedCounts = parseNumstat(run(["diff", "--cached", "--numstat", "-z", "--no-ext-diff", "-M"], in: repo) ?? "")
            for i in status.staged.indices {
                let c = stagedCounts[status.staged[i].path]
                status.staged[i].additions = c?.0
                status.staged[i].deletions = c?.1
            }
            for i in status.unstaged.indices {
                switch status.unstaged[i].area {
                case .untracked:
                    status.unstaged[i].additions = lineCount(of: repo.appending(path: status.unstaged[i].path))
                    status.unstaged[i].deletions = status.unstaged[i].additions == nil ? nil : 0
                default:
                    let c = unstagedCounts[status.unstaged[i].path]
                    status.unstaged[i].additions = c?.0
                    status.unstaged[i].deletions = c?.1
                }
            }
        }
        return status
    }

    public static func parseStatusV2(_ output: String) -> GitRepoStatus {
        var status = GitRepoStatus()
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = entries.next() {
            if entry.hasPrefix("# ") {
                let parts = entry.split(separator: " ", maxSplits: 2)
                guard parts.count == 3 else { continue }
                let value = String(parts[2])
                switch parts[1] {
                case "branch.oid": status.isUnborn = value == "(initial)"
                case "branch.head": status.branch = value == "(detached)" ? nil : value
                case "branch.upstream": status.upstream = value
                case "branch.ab":
                    let ab = value.split(separator: " ")
                    if ab.count == 2 {
                        status.ahead = Int(ab[0].dropFirst()) ?? 0
                        status.behind = Int(ab[1].dropFirst()) ?? 0
                    }
                default: break
                }
                continue
            }
            switch entry.first {
            case "1", "2":
                let isRename = entry.first == "2"
                // "1 XY sub mH mI mW hH hI path"; renames add a score field and the source path follows.
                let fields = entry.split(separator: " ", maxSplits: isRename ? 9 : 8, omittingEmptySubsequences: false)
                guard fields.count == (isRename ? 10 : 9), fields[1].count == 2 else { continue }
                let path = String(fields[isRename ? 9 : 8])
                let original = isRename ? entries.next().map(String.init) : nil
                let x = fields[1].first!, y = fields[1].last!
                if x != ".", let state = fileState(x) {
                    status.staged.append(GitChange(path: path, originalPath: original, area: .staged, state: state))
                }
                if y != ".", let state = fileState(y) {
                    status.unstaged.append(GitChange(path: path, area: .unstaged, state: state))
                }
            case "u":
                let fields = entry.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                status.unstaged.append(GitChange(path: String(fields[10]), area: .conflicted, state: .conflicted))
            case "?":
                status.unstaged.append(GitChange(path: String(entry.dropFirst(2)), area: .untracked, state: .untracked))
            default:
                continue
            }
        }
        return status
    }

    private static func fileState(_ code: Character) -> GitFileState? {
        switch code {
        case "M", "T": .modified
        case "A": .added
        case "D": .deleted
        case "R", "C": .renamed
        case "U": .conflicted
        default: nil
        }
    }

    /// `diff --numstat -z` → path: (additions, deletions); binary files have nil counts.
    public static func parseNumstat(_ output: String) -> [String: (Int?, Int?)] {
        var result: [String: (Int?, Int?)] = [:]
        var tokens = output.split(separator: "\0", omittingEmptySubsequences: false).makeIterator()
        while let token = tokens.next() {
            let fields = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let counts = (Int(fields[0]), Int(fields[1]))
            var path = String(fields[2])
            if path.isEmpty {   // rename: "a\td\t\0old\0new"
                _ = tokens.next()
                path = tokens.next().map(String.init) ?? ""
            }
            if !path.isEmpty { result[path] = counts }
        }
        return result
    }

    /// Lines of a new text file, nil for binary or very large files.
    static func lineCount(of file: URL) -> Int? {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 4_000_000,
              let data = try? Data(contentsOf: file) else { return nil }
        if data.prefix(8000).contains(0) { return nil }
        if data.isEmpty { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return data.last == 0x0A ? newlines : newlines + 1
    }

    // MARK: Diffs

    /// The diff of one change as the Changes view shows it: index vs HEAD for staged files,
    /// working tree vs index otherwise; untracked files diff against /dev/null.
    public static func changeDiff(_ change: GitChange, in repo: URL) -> String {
        switch change.area {
        case .staged:
            let paths = [change.originalPath, change.path].compactMap { $0 }
            return run(["diff", "--cached", "--no-ext-diff", "-M", "--"] + paths, in: repo) ?? ""
        case .unstaged, .conflicted:
            return run(["diff", "--no-ext-diff", "--", change.path], in: repo) ?? ""
        case .untracked:
            // --no-index exits 1 when the files differ, so read the output regardless of status.
            return execute(["diff", "--no-index", "--no-ext-diff", "--", "/dev/null", change.path], in: repo, timeout: 30).output
        }
    }

    /// Staged changes (or, if nothing is staged, the unstaged ones) for writing a commit message.
    public static func commitContext(in repo: URL) -> (stat: String, patch: String) {
        let stat = run(["diff", "--cached", "--stat", "--no-ext-diff"], in: repo) ?? ""
        if !stat.isEmpty {
            return (stat, run(["diff", "--cached", "--no-ext-diff", "-M"], in: repo) ?? "")
        }
        return (run(["diff", "--stat", "--no-ext-diff"], in: repo) ?? "", run(["diff", "--no-ext-diff"], in: repo) ?? "")
    }

    // MARK: Index operations

    public static func stage(_ paths: [String], in repo: URL) -> Result {
        execute(["add", "-A", "--"] + paths, in: repo)
    }

    public static func stageAll(in repo: URL) -> Result {
        execute(["add", "-A"], in: repo)
    }

    public static func unstage(_ changes: [GitChange], in repo: URL) -> Result {
        let paths = Array(Set(changes.flatMap { [$0.originalPath, $0.path].compactMap { $0 } })).sorted()
        guard !paths.isEmpty else { return Result(status: 0, output: "", error: "") }
        if isUnborn(repo) {
            return execute(["rm", "--cached", "-r", "-q", "--ignore-unmatch", "--"] + paths, in: repo)
        }
        return execute(["reset", "-q", "--"] + paths, in: repo)
    }

    public static func unstageAll(in repo: URL) -> Result {
        if isUnborn(repo) { return execute(["rm", "--cached", "-r", "-q", "--ignore-unmatch", "--", "."], in: repo) }
        return execute(["reset", "-q"], in: repo)
    }

    /// Throws away working tree changes. Tracked files are restored from the index (staged changes
    /// survive); untracked files are moved to the Trash, never deleted.
    public static func discard(_ changes: [GitChange], in repo: URL) -> Result {
        let tracked = changes.filter { $0.area == .unstaged }.map(\.path)
        if !tracked.isEmpty {
            let result = execute(["checkout", "--"] + tracked, in: repo)
            guard result.succeeded else { return result }
        }
        for change in changes where change.area == .untracked {
            do {
                try FileManager.default.trashItem(at: repo.appending(path: change.path), resultingItemURL: nil)
            } catch {
                return Result(status: 1, output: "", error: error.localizedDescription)
            }
        }
        return Result(status: 0, output: "", error: "")
    }

    /// Applies a patch to the index only (`reverse` unstages it). Used for hunk staging.
    public static func applyToIndex(_ patch: String, reverse: Bool, in repo: URL) -> Result {
        execute(["apply", "--cached", "--whitespace=nowarn"] + (reverse ? ["-R"] : []) + ["-"],
                in: repo, input: Data(patch.utf8))
    }

    // MARK: Commit & sync

    public static func commit(message: String, amend: Bool, in repo: URL) -> Result {
        execute(["commit", "-F", "-"] + (amend ? ["--amend"] : []), in: repo, input: Data(message.utf8))
    }

    /// Pushes the current branch; sets `origin` as upstream on the first push.
    public static func push(in repo: URL, hasUpstream: Bool) -> Result {
        execute(hasUpstream ? ["push"] : ["push", "-u", "origin", "HEAD"], in: repo)
    }

    public static func pull(in repo: URL) -> Result {
        execute(["pull", "--ff-only"], in: repo)
    }

    /// Message of the last commit (to prefill an amend).
    public static func lastCommitMessage(in repo: URL) -> String? {
        run(["log", "-1", "--format=%B"], in: repo)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isUnborn(_ repo: URL) -> Bool {
        run(["rev-parse", "--verify", "-q", "HEAD"], in: repo) == nil
    }

    /// Directories whose changes mean the status may have changed: the git dir (HEAD, index)
    /// and the shared refs of the common dir (linked worktrees have a `.git` file, not a folder).
    public static func watchedDirectories(of repo: URL) -> [URL] {
        guard let out = run(["rev-parse", "--git-dir", "--git-common-dir"], in: repo) else { return [] }
        let dirs = out.split(separator: "\n").map { line -> URL in
            let path = String(line)
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.appending(path: path)
        }
        guard let gitDir = dirs.first else { return [] }
        let common = dirs.count > 1 ? dirs[1] : gitDir
        var result = [gitDir, common, common.appending(path: "refs/heads"), common.appending(path: "refs/remotes")]
        result = result.map { $0.standardizedFileURL }
        var seen = Set<String>()
        return result.filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
    }
}
