import Foundation

public struct GitCommit: Identifiable, Sendable, Equatable {
    public var id: String { hash }
    public var hash: String
    public var author: String
    public var date: Date
    public var subject: String

    public var shortHash: String { String(hash.prefix(7)) }
}

public enum GitFileState: String, Sendable {
    case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "?", conflicted = "U"
}

/// Read-only git queries for the file browser. Everything runs `/usr/bin/git` synchronously —
/// call from a background task.
public enum Git {
    static let fieldSeparator = "\u{1f}"

    /// Top-level directory of the repository containing `dir`, or nil if it isn't in one.
    public static func root(of dir: URL) -> URL? {
        guard let out = run(["rev-parse", "--show-toplevel"], in: dir) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// Changed files keyed by absolute path. Parent folders of changes are marked modified.
    public static func status(in repo: URL) -> [String: GitFileState] {
        guard let out = run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: repo) else { return [:] }
        return parseStatus(out, repo: repo)
    }

    public static func parseStatus(_ output: String, repo: URL) -> [String: GitFileState] {
        var result: [String: GitFileState] = [:]
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = entries.next() {
            guard entry.count > 3 else { continue }
            let code = entry.prefix(2)
            let path = String(entry.dropFirst(3))
            let state: GitFileState
            if code == "??" { state = .untracked }
            else if code.contains("U") || code == "AA" || code == "DD" { state = .conflicted }
            else if code.contains("R") { state = .renamed; _ = entries.next() } // skip the rename source
            else if code.contains("A") { state = .added }
            else if code.contains("D") { state = .deleted }
            else { state = .modified }
            let url = repo.appending(path: path)
            result[url.path] = state
            var parent = url.deletingLastPathComponent()
            while parent.path.count > repo.path.count, result[parent.path] == nil {
                result[parent.path] = .modified
                parent = parent.deletingLastPathComponent()
            }
        }
        return result
    }

    /// Commits touching `file` (following renames), newest first.
    public static func log(of file: URL, in repo: URL, limit: Int = 100) -> [GitCommit] {
        let format = ["%H", "%an", "%at", "%s"].joined(separator: fieldSeparator)
        guard let out = run(["log", "--follow", "-n", "\(limit)", "--format=\(format)", "--", pathspec(file, in: repo)], in: repo) else { return [] }
        return parseLog(out)
    }

    public static func parseLog(_ output: String) -> [GitCommit] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: fieldSeparator)
            guard parts.count >= 4, let seconds = TimeInterval(parts[2]) else { return nil }
            return GitCommit(hash: parts[0], author: parts[1], date: Date(timeIntervalSince1970: seconds),
                             subject: parts[3...].joined(separator: fieldSeparator))
        }
    }

    /// The change a commit made to `file`.
    public static func diff(of file: URL, at commit: String, in repo: URL) -> String {
        run(["show", "--format=commit %H%nAuthor: %an <%ae>%nDate:   %ad%n%n%B", commit, "--", pathspec(file, in: repo)], in: repo) ?? ""
    }

    /// Uncommitted changes of `file`.
    public static func workingDiff(of file: URL, in repo: URL) -> String {
        run(["diff", "HEAD", "--", pathspec(file, in: repo)], in: repo) ?? ""
    }

    /// Path of `file` relative to the repo (both symlink-resolved: /var vs /private/var).
    static func pathspec(_ file: URL, in repo: URL) -> String {
        FileListing.relativePath(of: file.resolvingSymlinksInPath(), in: repo.resolvingSymlinksInPath())
    }

    static func run(_ args: [String], in dir: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "core.quotepath=off", "-c", "color.ui=false"] + args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"   // never take index.lock from a read-only query
        env["GIT_PAGER"] = "cat"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
