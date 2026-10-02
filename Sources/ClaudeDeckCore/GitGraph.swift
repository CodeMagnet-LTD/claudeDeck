import Foundation

/// One commit of the history graph (`git log --topo-order`).
public struct GitGraphCommit: Sendable, Equatable, Identifiable {
    public var id: String { hash }
    public var hash: String
    public var parents: [String]
    public var author: String
    public var date: Date
    public var subject: String
    /// Decorations: "HEAD -> main", "origin/main", "tag: v1".
    public var refs: [String]

    public init(hash: String, parents: [String], author: String = "", date: Date = Date(timeIntervalSince1970: 0),
                subject: String = "", refs: [String] = []) {
        self.hash = hash
        self.parents = parents
        self.author = author
        self.date = date
        self.subject = subject
        self.refs = refs
    }

    public var shortHash: String { String(hash.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }
}

/// How one graph row is drawn: the commit's dot sits in `column` at the row's middle; each segment
/// is a line in the top half (row top → middle) or the bottom half (middle → row bottom).
public struct GitGraphRow: Sendable, Equatable {
    public enum Half: Sendable, Equatable { case top, bottom }
    public struct Segment: Sendable, Equatable, Hashable {
        public var from: Int
        public var to: Int
        public var half: Half
        /// Palette index of the lane.
        public var color: Int

        public init(from: Int, to: Int, half: Half, color: Int) {
            self.from = from
            self.to = to
            self.half = half
            self.color = color
        }
    }

    public var column: Int
    public var color: Int
    public var segments: [Segment]
    /// Columns in use in this row (for the graph's width).
    public var width: Int
}

/// Lane layout for a topologically ordered commit list. A lane waits for one commit hash; a
/// commit takes the lane waiting for it (the leftmost if several, the others merge into it), its
/// first parent continues that lane (a lane further right already waiting for it merges in; one
/// further left is joined instead), further parents join a lane already waiting for them or get
/// a free one. Free slots are reused, so lanes don't drift right.
public enum GitGraphLayout {
    public static func layout(_ commits: [GitGraphCommit]) -> [GitGraphRow] {
        var lanes: [String?] = []      // hash each lane waits for
        var colors: [Int] = []
        var nextColor = 0
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeSlot() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            colors.append(0)
            return lanes.count - 1
        }

        for commit in commits {
            var segments: [GitGraphRow.Segment] = []
            let waiting = lanes.indices.filter { lanes[$0] == commit.hash }
            let column: Int
            if let first = waiting.first {
                column = first
            } else {   // a branch tip: new lane
                column = freeSlot()
                colors[column] = nextColor
                nextColor += 1
            }
            let color = colors[column]

            // Top half: lanes passing by stay put; lanes waiting for this commit converge on it.
            for (i, hash) in lanes.enumerated() where hash != nil {
                segments.append(.init(from: i, to: hash == commit.hash ? column : i, half: .top, color: colors[i]))
            }
            for i in waiting { lanes[i] = nil }

            // Bottom half: the first parent continues this lane unless a lane already waits for it.
            var parentColumns: [Int] = []
            var merged: [GitGraphRow.Segment] = []
            for (index, parent) in commit.parents.enumerated() {
                if index == 0, let existing = lanes.firstIndex(where: { $0 == parent }), existing > column {
                    // The first parent is awaited further right: pull that lane in here ("|/").
                    merged.append(.init(from: existing, to: column, half: .bottom, color: colors[existing]))
                    lanes[existing] = nil
                    lanes[column] = parent
                    parentColumns.append(column)
                } else if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    parentColumns.append(existing)
                } else if index == 0 {
                    lanes[column] = parent
                    parentColumns.append(column)
                } else {
                    let slot = freeSlot()
                    lanes[slot] = parent
                    colors[slot] = nextColor
                    nextColor += 1
                    parentColumns.append(slot)
                }
            }
            for (i, hash) in lanes.enumerated() where hash != nil && !parentColumns.contains(i) {
                segments.append(.init(from: i, to: i, half: .bottom, color: colors[i]))
            }
            for target in parentColumns {
                segments.append(.init(from: column, to: target, half: .bottom, color: colors[target]))
            }
            segments += merged

            while let last = lanes.last, last == nil { lanes.removeLast(); colors.removeLast() }
            let width = max(column + 1, segments.map { max($0.from, $0.to) + 1 }.max() ?? 1)
            rows.append(GitGraphRow(column: column, color: color, segments: segments, width: width))
        }
        return rows
    }
}

/// A file a commit changed.
public struct GitCommitFile: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var originalPath: String?
    public var state: GitFileState

    public init(path: String, originalPath: String? = nil, state: GitFileState) {
        self.path = path
        self.originalPath = originalPath
        self.state = state
    }
}

extension Git {
    static let graphFormat = ["%H", "%P", "%an", "%at", "%D", "%s"].joined(separator: "%x1f")

    /// The refs the History tab shows: HEAD, its upstream and the default branch (if they exist).
    public static func historyRefs(in repo: URL) -> [String] {
        var refs = ["HEAD"]
        if let up = run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: repo)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !up.isEmpty { refs.append(up) }
        if let def = defaultBranch(in: repo), !refs.contains(def) { refs.append(def) }
        return refs
    }

    /// "origin/main" from origin/HEAD, else a local main or master.
    public static func defaultBranch(in repo: URL) -> String? {
        if let sym = run(["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"], in: repo)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sym.isEmpty { return sym }
        for name in ["main", "master"] where run(["rev-parse", "--verify", "-q", "refs/heads/\(name)"], in: repo) != nil {
            return name
        }
        return nil
    }

    /// Commits reachable from `refs`, newest first in topological order.
    public static func graphLog(refs: [String], limit: Int = 500, in repo: URL) -> [GitGraphCommit] {
        guard let out = run(["log", "--topo-order", "-n", "\(limit)", "--format=\(graphFormat)", "--decorate=short"] + refs + ["--"],
                            in: repo) else { return [] }
        return parseGraphLog(out)
    }

    public static func parseGraphLog(_ output: String) -> [GitGraphCommit] {
        output.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: fieldSeparator)
            guard f.count >= 6, let seconds = TimeInterval(f[3]) else { return nil }
            let refs = f[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return GitGraphCommit(hash: f[0], parents: f[1].split(separator: " ").map(String.init), author: f[2],
                                  date: Date(timeIntervalSince1970: seconds), subject: f[5...].joined(separator: fieldSeparator),
                                  refs: refs)
        }
    }

    /// Diff arguments comparing a commit with its first parent (`--root` for the first commit).
    private static func commitDiffArgs(_ commit: GitGraphCommit) -> [String] {
        commit.parents.isEmpty ? ["diff-tree", "--root", "-r", "--no-commit-id", commit.hash]
            : ["diff", commit.parents[0], commit.hash]
    }

    public static func commitFiles(_ commit: GitGraphCommit, in repo: URL) -> [GitCommitFile] {
        guard let out = run(commitDiffArgs(commit) + ["-M", "--name-status", "-z", "--no-ext-diff"], in: repo) else { return [] }
        return parseNameStatus(out)
    }

    /// `--name-status -z`: "M\0path\0", "R100\0old\0new\0".
    public static func parseNameStatus(_ output: String) -> [GitCommitFile] {
        var result: [GitCommitFile] = []
        var tokens = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let code = tokens.next() {
            guard let letter = code.first, let path = tokens.next() else { break }
            switch letter {
            case "R", "C":
                guard let new = tokens.next() else { break }
                result.append(GitCommitFile(path: String(new), originalPath: String(path), state: .renamed))
            case "A": result.append(GitCommitFile(path: String(path), state: .added))
            case "D": result.append(GitCommitFile(path: String(path), state: .deleted))
            case "U": result.append(GitCommitFile(path: String(path), state: .conflicted))
            default: result.append(GitCommitFile(path: String(path), state: .modified))
            }
        }
        return result
    }

    /// The patch of one file of a commit (against its first parent).
    public static func commitFileDiff(_ commit: GitGraphCommit, file: GitCommitFile, in repo: URL) -> String {
        let paths = [file.originalPath, file.path].compactMap { $0 }
        return run(commitDiffArgs(commit) + ["-p", "-M", "--no-ext-diff", "--"] + paths, in: repo) ?? ""
    }

    /// Full message and author line of a commit.
    public static func commitMessage(_ hash: String, in repo: URL) -> String {
        run(["log", "-1", "--format=%B", hash, "--"], in: repo)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
