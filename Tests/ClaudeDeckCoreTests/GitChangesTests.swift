import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct GitChangesTests {
    @Test func parsesStatusV2() {
        let out = [
            "# branch.oid 1234567890abcdef",
            "# branch.head feature/x",
            "# branch.upstream origin/feature/x",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaa aaa src/a.swift",
            "1 MM N... 100644 100644 100644 aaa bbb both.txt",
            "1 A. N... 000000 100644 100644 000 ccc new file.txt",
            "2 R. N... 100644 100644 100644 ddd ddd R100 renamed.swift",
            "old.swift",
            "u UU N... 100644 100644 100644 100644 e1 e2 e3 conflict.txt",
            "? untracked dir/u.txt",
            "1 .D N... 100644 100644 000000 fff fff gone.md",
        ].joined(separator: "\0") + "\0"
        let s = Git.parseStatusV2(out)
        #expect(s.branch == "feature/x")
        #expect(!s.isUnborn)
        #expect(s.upstream == "origin/feature/x")
        #expect(s.ahead == 2 && s.behind == 1)
        #expect(s.staged.map(\.path) == ["both.txt", "new file.txt", "renamed.swift"])
        #expect(s.staged[1].state == .added)
        #expect(s.staged[2].state == .renamed && s.staged[2].originalPath == "old.swift")
        #expect(s.unstaged.map(\.path) == ["src/a.swift", "both.txt", "conflict.txt", "untracked dir/u.txt", "gone.md"])
        #expect(s.unstaged[2].area == .conflicted)
        #expect(s.unstaged[3].area == .untracked)
        #expect(s.unstaged[4].state == .deleted)
    }

    @Test func parsesUnbornAndDetachedHeaders() {
        let unborn = Git.parseStatusV2("# branch.oid (initial)\0# branch.head main\0")
        #expect(unborn.isUnborn && unborn.branch == "main" && unborn.upstream == nil)
        let detached = Git.parseStatusV2("# branch.oid abc\0# branch.head (detached)\0")
        #expect(detached.branch == nil && !detached.isUnborn)
    }

    @Test func parsesNumstat() {
        let out = "3\t1\ta.txt\0-\t-\timg.png\0" + "2\t0\t\0old name.txt\0new name.txt\0"
        let n = Git.parseNumstat(out)
        #expect(n["a.txt"]?.0 == 3 && n["a.txt"]?.1 == 1)
        #expect(n["img.png"] != nil && n["img.png"]?.0 == nil)
        #expect(n["new name.txt"]?.0 == 2)
        #expect(n["old name.txt"] == nil)
    }

    @Test func parsesUnifiedDiff() throws {
        let text = """
        diff --git a/f.txt b/f.txt
        index 111..222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@ header context
         one
        -two
        +TWO
         three
        @@ -10 +10,2 @@
        -last
        \\ No newline at end of file
        +last
        +more
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..333
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hello
        diff --git a/bin.png b/bin.png
        index 1..2 100644
        Binary files a/bin.png and b/bin.png differ

        """
        let files = UnifiedDiff.parse(text)
        #expect(files.count == 3)
        let f = files[0]
        #expect(f.path == "f.txt" && f.oldPath == "f.txt")
        #expect(f.header.count == 4)
        #expect(f.hunks.count == 2)
        let h0 = f.hunks[0]
        #expect(h0.oldStart == 1 && h0.oldCount == 3 && h0.newStart == 1 && h0.newCount == 3)
        #expect(h0.lines.map(\.kind) == [.context, .removed, .added, .context])
        #expect(h0.lines[1].oldLine == 2 && h0.lines[1].newLine == nil && h0.lines[1].displayLine == 2)
        #expect(h0.lines[2].newLine == 2 && h0.lines[2].text == "TWO")
        #expect(h0.lines[3].oldLine == 3 && h0.lines[3].newLine == 3)
        let h1 = f.hunks[1]
        #expect(h1.oldStart == 10 && h1.oldCount == 1 && h1.newCount == 2)
        #expect(h1.lines.map(\.kind) == [.removed, .noNewline, .added, .added])
        #expect(h1.lines[3].newLine == 11)
        #expect(h1.raw.count == 5)

        #expect(files[1].oldPath == nil && files[1].newPath == "new.txt")
        #expect(files[1].hunks.first?.lines.first?.newLine == 1)
        #expect(files[2].isBinary && files[2].path == "bin.png" && files[2].hunks.isEmpty)

        let patch = UnifiedDiff.patch(f, hunks: [1])
        #expect(patch.hasPrefix("diff --git a/f.txt b/f.txt\n"))
        #expect(patch.contains("\\ No newline at end of file\n+last\n+more\n"))
        #expect(!patch.contains("TWO"))
    }

    // MARK: Real repositories

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deck-changes-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = Git.run(["init", "-q"], in: dir)
        for (k, v) in [("user.name", "T"), ("user.email", "t@t"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = Git.run(["config", k, v], in: dir)
        }
        return dir
    }

    private func write(_ text: String, _ name: String, in dir: URL) throws {
        let url = dir.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func unbornRepository() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a\nb\n", "a.txt", in: dir)
        var s = try #require(Git.repoStatus(in: dir))
        #expect(s.isUnborn && s.branch != nil)
        #expect(s.unstaged.first?.area == .untracked && s.unstaged.first?.additions == 2)
        #expect(Git.changeDiff(s.unstaged[0], in: dir).contains("+b"))

        #expect(Git.stageAll(in: dir).succeeded)
        s = try #require(Git.repoStatus(in: dir))
        #expect(s.staged.map(\.path) == ["a.txt"] && s.staged[0].additions == 2)
        #expect(Git.unstage(s.staged, in: dir).succeeded)
        s = try #require(Git.repoStatus(in: dir))
        #expect(s.staged.isEmpty && s.unstaged.count == 1)

        _ = Git.stageAll(in: dir)
        let commit = Git.commit(message: "first\n\nbody line", amend: false, in: dir)
        #expect(commit.succeeded, "\(commit.message)")
        s = try #require(Git.repoStatus(in: dir))
        #expect(!s.isUnborn && !s.hasChanges)
        #expect(Git.lastCommitMessage(in: dir) == "first\n\nbody line")
        #expect(Git.commit(message: "amended", amend: true, in: dir).succeeded)
        #expect(Git.lastCommitMessage(in: dir) == "amended")
        #expect(!Git.commit(message: "nothing", amend: false, in: dir).succeeded)
        #expect(!Git.watchedDirectories(of: dir).isEmpty)
    }

    @Test func hunkStagingAndDiscard() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = (1...30).map { "line \($0)" }
        try write(original.joined(separator: "\n") + "\n", "f.txt", in: dir)
        _ = Git.stageAll(in: dir)
        #expect(Git.commit(message: "init", amend: false, in: dir).succeeded)

        var edited = original
        edited[1] = "EARLY"
        edited[27] = "LATE"
        try write(edited.joined(separator: "\n") + "\n", "f.txt", in: dir)

        var s = try #require(Git.repoStatus(in: dir))
        let change = try #require(s.unstaged.first)
        #expect(change.additions == 2 && change.deletions == 2)
        let file = try #require(UnifiedDiff.parse(Git.changeDiff(change, in: dir)).first)
        #expect(file.hunks.count == 2)

        // Stage only the first hunk.
        let staged = Git.applyToIndex(UnifiedDiff.patch(file, hunks: [0]), reverse: false, in: dir)
        #expect(staged.succeeded, "\(staged.message)")
        let cached = Git.run(["diff", "--cached"], in: dir) ?? ""
        #expect(cached.contains("+EARLY") && !cached.contains("+LATE"))
        s = try #require(Git.repoStatus(in: dir))
        #expect(s.staged.count == 1 && s.unstaged.count == 1)

        // Unstage it again through the staged diff.
        let stagedFile = try #require(UnifiedDiff.parse(Git.changeDiff(s.staged[0], in: dir)).first)
        #expect(Git.applyToIndex(UnifiedDiff.patch(stagedFile, hunks: [0]), reverse: true, in: dir).succeeded)
        #expect((Git.run(["diff", "--cached"], in: dir) ?? "x").isEmpty)

        // Discard the working tree change (untracked files would go to the Trash; not exercised
        // here so tests don't litter the user's Trash).
        s = try #require(Git.repoStatus(in: dir))
        #expect(s.unstaged.count == 1)
        #expect(Git.discard(s.unstaged, in: dir).succeeded)
        s = try #require(Git.repoStatus(in: dir))
        #expect(!s.hasChanges)
        #expect(try String(contentsOf: dir.appending(path: "f.txt"), encoding: .utf8) == original.joined(separator: "\n") + "\n")
    }

    @Test func pushWithoutRemoteReportsError() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("x\n", "x.txt", in: dir)
        _ = Git.stageAll(in: dir)
        _ = Git.commit(message: "x", amend: false, in: dir)
        let result = Git.push(in: dir, hasUpstream: false)
        #expect(!result.succeeded && !result.message.isEmpty)
    }
}
