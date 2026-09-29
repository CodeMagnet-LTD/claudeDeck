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

/// Git queries for the file browser and the Changes view (write operations live in
/// GitChanges.swift). Everything runs git synchronously — call from a background task.
public enum Git {
    static let fieldSeparator = "\u{1f}"

    /// A real git binary, or nil (git features stay off). `/usr/bin/git` is only a shim on a Mac
    /// without the Command Line Tools: running it pops the "install developer tools" dialog,
    /// so it is used only when `xcode-select -p` (which never prompts) names an installed toolchain.
    static let executable: URL? = {
        var candidates: [String] = []
        if let dev = developerDirectory() { candidates.append(dev + "/usr/bin/git") }
        candidates += ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }()

    private static func developerDirectory() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

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
        guard let executable else { return nil }
        let p = Process()
        p.executableURL = executable
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

    /// Outcome of a git command run by `execute`; write operations report their error text.
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
        public var error: String

        public var succeeded: Bool { status == 0 }
        /// The most useful text to show the user when the command failed.
        public var message: String {
            let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : text
        }
    }

    /// Runs git capturing stdout, stderr and the exit code. Unlike `run` it may take locks
    /// (stage, commit, …). Credential prompts are disabled and the process is killed after
    /// `timeout`, so a remote waiting for input can't hang the caller.
    @discardableResult
    static func execute(_ args: [String], in dir: URL, input: Data? = nil, timeout: TimeInterval = 120) -> Result {
        guard let executable else { return Result(status: -1, output: "", error: "git isn’t installed") }
        let p = Process()
        p.executableURL = executable
        p.arguments = ["-c", "core.quotepath=off", "-c", "color.ui=false"] + args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        if env["GIT_SSH_COMMAND"] == nil { env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = input == nil ? nil : Pipe()
        if let inPipe { p.standardInput = inPipe } else { p.standardInput = FileHandle.nullDevice }
        do { try p.run() } catch { return Result(status: -1, output: "", error: error.localizedDescription) }
        if let inPipe, let input {
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        // Drain both pipes concurrently so a large diff can't fill one and deadlock.
        let collector = PipeCollector()
        let group = DispatchGroup()
        for (index, pipe) in [out, err].enumerated() {
            group.enter()
            DispatchQueue.global().async {
                collector.set(index, pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            // A child (ssh) may still hold the pipes open; don't wait on it forever.
            _ = group.wait(timeout: .now() + 5)
            return Result(status: -1, output: collector.string(0), error: "git \(args.first ?? "") timed out")
        }
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: collector.string(0), error: collector.string(1))
    }
}

/// Thread-safe holder for data read from several pipes at once.
final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Int: Data] = [:]

    func set(_ index: Int, _ value: Data) { lock.lock(); data[index] = value; lock.unlock() }

    func string(_ index: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data[index] ?? Data(), as: UTF8.self)
    }
}
