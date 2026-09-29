import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct ExplorerTests {
    private func tempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deck-\(tag)-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL, _ text: String = "") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: gitignore

    @Test func gitIgnoredChildrenAreMarkedAndHidden() throws {
        let dir = try tempDir("ignore")
        defer { try? FileManager.default.removeItem(at: dir) }
        func git(_ args: String...) { _ = Git.run(["-c", "user.name=T", "-c", "user.email=t@t"] + args, in: dir) }
        git("init", "-q")
        try touch(dir.appending(path: ".gitignore"), "build/\n*.log\n")
        try touch(dir.appending(path: "src/build/out.o"))
        try touch(dir.appending(path: "src/a.log"))
        try touch(dir.appending(path: "src/keep.log"))
        try touch(dir.appending(path: "src/main.swift"))
        try touch(dir.appending(path: "src/odd name 'x'.txt"))
        git("add", "-f", "src/keep.log")   // tracked files are never reported as ignored

        let src = dir.appending(path: "src")
        let names = FileListing.allChildren(of: src).map(\.name)
        let ignored = Git.ignoredNames(in: src, names: names)
        #expect(ignored == ["build", "a.log"])
        #expect(FileListing.children(of: src, gitIgnored: ignored).map(\.name) == ["keep.log", "main.swift", "odd name 'x'.txt"])
        let all = FileListing.children(of: src, showIgnored: true, gitIgnored: ignored)
        #expect(all.map(\.name) == ["build", "a.log", "keep.log", "main.swift", "odd name 'x'.txt"])
        #expect(all.filter(\.isIgnored).map(\.name) == ["build", "a.log"])
    }

    @Test func ignoreOutsideRepositoryFallsBackToNames() throws {
        let dir = try tempDir("noignore")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "node_modules"), withIntermediateDirectories: true)
        try touch(dir.appending(path: "a.log"))
        // /tmp is not inside a repository: nothing is git-ignored.
        #expect(Git.ignoredNames(in: dir, names: ["a.log", "node_modules"]).isEmpty)
        #expect(FileListing.children(of: dir).map(\.name) == ["a.log"])
        let shown = FileListing.children(of: dir, showIgnored: true)
        #expect(shown.map(\.name) == ["node_modules", "a.log"])
        #expect(shown[0].isIgnored)
    }

    @Test func listsAndGrepsRepositoryFiles() throws {
        let dir = try tempDir("grep")
        defer { try? FileManager.default.removeItem(at: dir) }
        func git(_ args: String...) { _ = Git.run(["-c", "user.name=T", "-c", "user.email=t@t"] + args, in: dir) }
        git("init", "-q")
        try touch(dir.appending(path: ".gitignore"), "*.log\n")
        try touch(dir.appending(path: "a.swift"), "let x = 1\nlet Hello = 2\n")
        try touch(dir.appending(path: "sub/b.txt"), "hello world\n")
        try touch(dir.appending(path: "c.log"), "hello\n")
        git("add", "a.swift")

        #expect(Set(Git.listFiles(in: dir) ?? []) == [".gitignore", "a.swift", "sub/b.txt"])
        #expect(Git.listFiles(in: dir.appending(path: "sub")) == ["b.txt"])

        let hits = Git.grep("hello", in: dir, inRepo: true)
        #expect(Set(hits.map(\.id)) == ["a.swift:2", "sub/b.txt:1"])
        #expect(Git.grep("hello", in: dir, caseSensitive: true, inRepo: true).map(\.id) == ["sub/b.txt:1"])
        #expect(Git.grep("nothing-here", in: dir, inRepo: true).isEmpty)
        #expect(Git.grep("hello", in: dir.appending(path: "sub"), inRepo: true).map(\.path) == ["b.txt"])
    }

    @Test func parsesGrepOutput() {
        let out = "a.swift\u{0}12\u{0}  let x = 1\nsrc/b c.ts\u{0}3\u{0}x:y\u{0}z\nbroken\n"
        let hits = Git.parseGrep(out)
        #expect(hits == [SearchMatch(path: "a.swift", line: 12, text: "let x = 1"),
                         SearchMatch(path: "src/b c.ts", line: 3, text: "x:y\u{0}z")])
        #expect(Git.parseGrep(out, limit: 1).count == 1)
    }

    @Test func gitMetadataChanges() {
        #expect(Git.isMetadataName("index"))
        #expect(Git.isMetadataName("HEAD"))
        #expect(Git.isMetadataName("refs/heads/main"))
        #expect(Git.isMetadataName("worktrees/feature/HEAD"))
        #expect(!Git.isMetadataName("index.lock"))
        #expect(!Git.isMetadataName("objects/ab/cdef"))
        #expect(!Git.isMetadataName("worktrees/feature"))
        #expect(!Git.isMetadataName("COMMIT_EDITMSG"))
    }

    // MARK: file operations

    @Test func copyNames() {
        let dir = URL(fileURLWithPath: "/d")
        var existing: Set<String> = ["/d/a.txt"]
        let exists: (URL) -> Bool = { existing.contains($0.path) }
        #expect(FileListing.availableCopyURL(for: "b.txt", in: dir, exists: exists).path == "/d/b.txt")
        #expect(FileListing.availableCopyURL(for: "a.txt", in: dir, exists: exists).path == "/d/a copy.txt")
        existing.insert("/d/a copy.txt")
        #expect(FileListing.availableCopyURL(for: "a.txt", in: dir, exists: { existing.contains($0.path) }).path == "/d/a copy 2.txt")
        #expect(FileListing.availableCopyURL(for: "a copy.txt", in: dir, exists: { existing.contains($0.path) }).path == "/d/a copy 2.txt")
        existing = ["/d/.env", "/d/src", "/d/x.tar.gz"]
        #expect(FileListing.availableCopyURL(for: ".env", in: dir, exists: { existing.contains($0.path) }).path == "/d/.env copy")
        #expect(FileListing.availableCopyURL(for: "src", in: dir, exists: { existing.contains($0.path) }).path == "/d/src copy")
        #expect(FileListing.availableCopyURL(for: "x.tar.gz", in: dir, exists: { existing.contains($0.path) }).path == "/d/x.tar copy.gz")
    }

    @Test func nestedPaths() {
        let dir = URL(fileURLWithPath: "/p")
        #expect(FileListing.intermediateDirectories(of: "a/b/c.swift", in: dir).map(\.path) == ["/p/a", "/p/a/b"])
        #expect(FileListing.intermediateDirectories(of: "c.swift", in: dir).isEmpty)
        #expect(FileListing.isSameOrDescendant(URL(fileURLWithPath: "/p/a/b"), of: URL(fileURLWithPath: "/p/a")))
        #expect(FileListing.isSameOrDescendant(URL(fileURLWithPath: "/p/a"), of: URL(fileURLWithPath: "/p/a")))
        #expect(!FileListing.isSameOrDescendant(URL(fileURLWithPath: "/p/ab"), of: URL(fileURLWithPath: "/p/a")))
    }

    @Test func boundedWalkSkipsVendorDirectories() throws {
        let dir = try tempDir("walk")
        defer { try? FileManager.default.removeItem(at: dir) }
        for path in ["a.swift", "src/b.swift", "node_modules/x/y.js", ".hidden/z", ".github/w.yml", "vendor/v.rb"] {
            try touch(dir.appending(path: path))
        }
        #expect(Set(FileListing.walk(dir)) == ["a.swift", "src/b.swift", ".github/w.yml"])
        #expect(FileListing.walk(dir, limit: 1).count == 1)
    }

    // MARK: fuzzy

    @Test func fuzzyRequiresOrderedSubsequence() {
        #expect(FuzzyMatch.score("fb", in: "src/FileBrowser.swift") != nil)
        #expect(FuzzyMatch.score("tfs", in: "src/FileBrowser.swift") == nil)
        #expect(FuzzyMatch.score("", in: "x")?.score == 0)
        #expect(FuzzyMatch.score("FILE", in: "file.txt")?.positions == [0, 1, 2, 3])
    }

    @Test func fuzzyRanksFileNameAndWordStartsFirst() {
        let paths = ["Sources/ClaudeDeck/FileBrowser.swift", "Sources/ClaudeDeckCore/FileListing.swift",
                     "docs/fabric/brown.md", "Tests/ClaudeDeckCoreTests/FileListingTests.swift"]
        #expect(FuzzyMatch.rank("filebrow", paths: paths).first?.path == "Sources/ClaudeDeck/FileBrowser.swift")
        #expect(FuzzyMatch.rank("fl", paths: paths).first?.path == "Sources/ClaudeDeckCore/FileListing.swift")
        #expect(FuzzyMatch.rank("listing", paths: paths).map(\.path)
                == ["Sources/ClaudeDeckCore/FileListing.swift", "Tests/ClaudeDeckCoreTests/FileListingTests.swift"])
        // Contiguous beats scattered.
        let a = FuzzyMatch.score("main", in: "src/main.swift")!.score
        let b = FuzzyMatch.score("main", in: "src/m_a_i_n.swift")!.score
        #expect(a > b)
    }

    // MARK: FSEvents

    @Test func fsEventsReportsFileChanges() async throws {
        let dir = try tempDir("fsevents").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = PathBox()
        let watcher = FSEventsWatcher(paths: [dir], latency: 0.05, queue: DispatchQueue(label: "test")) { events in
            seen.add(events.map(\.path))
        }
        #expect(watcher.start())
        try await Task.sleep(for: .milliseconds(300))
        try touch(dir.appending(path: "deep/er/file.txt"), "x")
        var found = false
        for _ in 0..<50 where !found {
            try await Task.sleep(for: .milliseconds(100))
            found = seen.paths.contains { $0.hasSuffix("deep/er/file.txt") }
        }
        #expect(found)
        watcher.stop()
    }
}

private final class PathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    var paths: [String] { lock.withLock { _paths } }
    func add(_ p: [String]) { lock.withLock { _paths += p } }
}
