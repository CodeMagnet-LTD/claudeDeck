import Foundation

/// One text search hit.
public struct SearchMatch: Identifiable, Hashable, Sendable {
    public var id: String { "\(path):\(line)" }
    /// Relative to the searched directory.
    public var path: String
    public var line: Int
    public var text: String

    public init(path: String, line: Int, text: String) {
        self.path = path
        self.line = line
        self.text = text
    }
}

/// Explorer queries: ignore rules, file lists and text search. Synchronous — call off the main actor.
extension Git {
    /// Which of `names` (children of `dir`) git ignores. Empty outside a repository or without git.
    public static func ignoredNames(in dir: URL, names: [String]) -> Set<String> {
        guard !names.isEmpty else { return [] }
        let input = Data(names.joined(separator: "\0").utf8) + Data([0])
        // Exit 1 = nothing ignored, 128 = not a repository: both mean "none".
        guard let out = runWithInput(["check-ignore", "--stdin", "-z"], input: input, in: dir) else { return [] }
        return Set(out.split(separator: "\0").map(String.init))
    }

    /// Tracked + untracked-but-not-ignored files below `dir`, relative to it. Nil outside a repository.
    public static func listFiles(in dir: URL) -> [String]? {
        guard let out = run(["ls-files", "-co", "--exclude-standard", "-z"], in: dir) else { return nil }
        var seen = Set<String>()   // unmerged paths are listed once per stage
        return out.split(separator: "\0").map(String.init).filter { seen.insert($0).inserted }
    }

    /// `git grep` below `dir`, including untracked files (`--no-index` outside a repository).
    public static func grep(_ query: String, in dir: URL, caseSensitive: Bool = false, regex: Bool = false,
                            inRepo: Bool, limit: Int = 2000) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        var args = ["grep", "-n", "-z", "-I"]
        args += inRepo ? ["--untracked"] : ["--no-index", "--exclude-standard"]
        if !caseSensitive { args.append("-i") }
        args.append(regex ? "-E" : "-F")
        args += ["-e", query]
        // Exit 1 = no matches.
        guard let out = run(args, in: dir) else { return [] }
        return parseGrep(out, limit: limit)
    }

    /// `path\0line\0text\n` records (git grep -n -z); paths relative to the searched directory.
    public static func parseGrep(_ output: String, limit: Int = 2000) -> [SearchMatch] {
        var result: [SearchMatch] = []
        for record in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = record.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let line = Int(parts[1]) else { continue }
            let text = String(parts[2].prefix(400)).trimmingCharacters(in: .whitespaces)
            result.append(SearchMatch(path: String(parts[0]), line: line, text: text))
            if result.count >= limit { break }
        }
        return result
    }

    /// The git directory and the common git directory (they differ for linked worktrees).
    public static func gitDirectories(of dir: URL) -> [URL] {
        guard let out = run(["rev-parse", "--absolute-git-dir", "--git-common-dir"], in: dir) else { return [] }
        return out.split(separator: "\n").map(String.init)
            .map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : dir.appending(path: $0) }
            .map(\.standardizedFileURL)
    }

    /// `rel` is a path inside a git directory ("index", "refs/heads/main", "worktrees/x/HEAD").
    /// True when a change there can affect `git status` — not for lock files or objects.
    public static func isMetadataName(_ rel: String) -> Bool {
        if rel.hasSuffix(".lock") || rel.hasPrefix("objects/") || rel == "objects" { return false }
        var rel = rel
        if rel.hasPrefix("worktrees/") {   // worktrees/<name>/HEAD …
            let parts = rel.split(separator: "/", maxSplits: 2)
            guard parts.count == 3 else { return false }
            rel = String(parts[2])
        }
        return ["index", "HEAD", "ORIG_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "packed-refs", "logs/HEAD"].contains(rel)
            || rel.hasPrefix("refs/")
    }

    /// Like `run`, feeding `input` on stdin. The input goes through a temporary file: no pipe to
    /// deadlock on, and no SIGPIPE if git exits before reading it.
    static func runWithInput(_ args: [String], input: Data, in dir: URL) -> String? {
        guard let executable else { return nil }
        let inputURL = FileManager.default.temporaryDirectory.appending(path: "claudedeck-git-\(UUID().uuidString)")
        guard (try? input.write(to: inputURL)) != nil, let inputHandle = try? FileHandle(forReadingFrom: inputURL) else { return nil }
        defer {
            try? inputHandle.close()
            try? FileManager.default.removeItem(at: inputURL)
        }
        let p = Process()
        p.executableURL = executable
        p.arguments = ["-c", "core.quotepath=off", "-c", "color.ui=false"] + args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = inputHandle
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
