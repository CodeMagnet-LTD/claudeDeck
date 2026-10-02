import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct GitHistoryTests {
    typealias Seg = GitGraphRow.Segment

    private func c(_ hash: String, _ parents: String...) -> GitGraphCommit {
        GitGraphCommit(hash: hash, parents: parents)
    }

    // MARK: Lane layout

    @Test func linearHistoryStaysInOneLane() {
        let rows = GitGraphLayout.layout([c("c", "b"), c("b", "a"), c("a")])
        #expect(rows.map(\.column) == [0, 0, 0])
        #expect(rows.allSatisfy { $0.width == 1 })
        #expect(rows[0].segments == [Seg(from: 0, to: 0, half: .bottom, color: 0)])
        #expect(rows[1].segments.contains(Seg(from: 0, to: 0, half: .top, color: 0)))
        #expect(rows[2].segments == [Seg(from: 0, to: 0, half: .top, color: 0)])   // root: nothing below
    }

    @Test func branchAndMerge() {
        // m merges f (feature) into main; both fork from a.
        //   m        col 0
        //   |\
        //   | f      col 1
        //   b |      col 0
        //   |/
        //   a        col 0
        let rows = GitGraphLayout.layout([c("m", "b", "f"), c("f", "a"), c("b", "a"), c("a")])
        #expect(rows.map(\.column) == [0, 1, 0, 0])
        #expect(rows[0].segments.contains(Seg(from: 0, to: 1, half: .bottom, color: rows[1].color)))
        #expect(rows[0].width == 2)
        // f's first parent a: f's lane waits for a.
        #expect(rows[1].segments.contains(Seg(from: 1, to: 1, half: .bottom, color: rows[1].color)))
        // b's first parent a is already awaited in lane 1: that lane bends into b's lane ("|/").
        #expect(rows[2].segments.contains(Seg(from: 1, to: 0, half: .bottom, color: rows[1].color)))
        #expect(rows[2].segments.contains(Seg(from: 0, to: 0, half: .bottom, color: rows[0].color)))
        #expect(rows[3].segments == [Seg(from: 0, to: 0, half: .top, color: rows[0].color)])
        #expect(rows[3].width == 1)
    }

    @Test func firstParentAlreadyInAnotherLaneFreesTheColumn() {
        // Tip t (new lane 1) whose parent b is already awaited in lane 0.
        let rows = GitGraphLayout.layout([c("x", "b"), c("t", "b"), c("b")])
        #expect(rows[1].column == 1)
        #expect(rows[1].segments.contains(Seg(from: 1, to: 0, half: .bottom, color: rows[0].color)))
        #expect(!rows[1].segments.contains { $0.half == .bottom && $0.from == 1 && $0.to == 1 })
        #expect(rows[2].column == 0)
        #expect(rows[2].width == 1)   // lane 1 was freed and trimmed
    }

    @Test func independentRootsGetTheirOwnLanes() {
        let rows = GitGraphLayout.layout([c("b2", "b1"), c("a2", "a1"), c("b1"), c("a1")])
        #expect(rows.map(\.column) == [0, 1, 0, 1])
        #expect(rows[0].color != rows[1].color)
        // After b1 (root) its lane is free; a1 keeps lane 1, drawn straight.
        #expect(rows[2].segments.contains(Seg(from: 1, to: 1, half: .bottom, color: rows[1].color)))
        #expect(rows[3].segments == [Seg(from: 1, to: 1, half: .top, color: rows[1].color)])
    }

    @Test func freedSlotsAreReused() {
        // Two tips in lanes 0 and 1; lane 0 ends at root r; a later tip reuses lane 0.
        let rows = GitGraphLayout.layout([c("p", "r"), c("q", "s"), c("r"), c("n", "s"), c("s")])
        #expect(rows.map(\.column) == [0, 1, 0, 0, 0])
    }

    // MARK: Parsing

    @Test func parsesGraphLog() {
        let sep = "\u{1f}"
        let out = ["aaa", "bbb ccc", "Ann", "1700000000", "HEAD -> main, origin/main, tag: v1", "Merge x"].joined(separator: sep)
            + "\n" + ["bbb", "", "Bob", "1600000000", "", "first \u{1f} odd"].joined(separator: sep) + "\n"
        let commits = Git.parseGraphLog(out)
        #expect(commits.count == 2)
        #expect(commits[0].parents == ["bbb", "ccc"])
        #expect(commits[0].isMerge)
        #expect(commits[0].refs == ["HEAD -> main", "origin/main", "tag: v1"])
        #expect(commits[1].parents.isEmpty)
        #expect(commits[1].refs.isEmpty)
        #expect(commits[1].subject == "first \u{1f} odd")
    }

    @Test func parsesNameStatus() {
        let out = "M\0a.txt\0R087\0old name.txt\0new name.txt\0A\0dir/n.swift\0D\0gone\0"
        let files = Git.parseNameStatus(out)
        #expect(files == [
            GitCommitFile(path: "a.txt", state: .modified),
            GitCommitFile(path: "new name.txt", originalPath: "old name.txt", state: .renamed),
            GitCommitFile(path: "dir/n.swift", state: .added),
            GitCommitFile(path: "gone", state: .deleted),
        ])
    }

    @Test func parsesBranches() {
        let sep = "\u{1f}"
        let lines = [
            ["refs/heads/zeta", " ", "", "1700000000", ""],
            ["refs/heads/main", "*", "origin/main", "1700000001", ""],
            ["refs/remotes/origin/HEAD", " ", "", "1700000001", "refs/remotes/origin/main"],
            ["refs/remotes/origin/main", " ", "", "1700000001", ""],
            ["refs/remotes/origin/feature/x", " ", "", "1700000002", ""],
        ].map { $0.joined(separator: sep) }.joined(separator: "\n")
        let branches = Git.parseBranches(lines)
        #expect(branches.map(\.name) == ["main", "zeta", "origin/feature/x", "origin/main"])
        #expect(branches[0].isCurrent && branches[0].upstream == "origin/main")
        #expect(branches[2].isRemote && branches[2].localName == "feature/x")
    }

    @Test func parsesWorktreePorcelain() {
        let out = """
        worktree /repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /repo/.claude/worktrees/app-2
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/worktree-app-2
        locked busy here

        worktree /tmp/gone
        HEAD 3333333333333333333333333333333333333333
        detached
        prunable gitdir file points to non-existent location

        """
        let wts = Git.parseWorktrees(out)
        #expect(wts.count == 3)
        #expect(wts[0].isMain && wts[0].branch == "main" && !wts[0].isDetached)
        #expect(!wts[1].isMain && wts[1].branch == "worktree-app-2" && wts[1].isLocked && wts[1].lockedReason == "busy here")
        #expect(wts[2].isDetached && wts[2].branch == nil && wts[2].isPrunable)
        #expect(wts[2].prunableReason == "gitdir file points to non-existent location")
    }

    // MARK: Real repositories

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deck-history-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = Git.run(["init", "-q", "-b", "main"], in: dir)
        for (k, v) in [("user.name", "T"), ("user.email", "t@t"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = Git.run(["config", k, v], in: dir)
        }
        return dir
    }

    private func commit(_ text: String, _ name: String, in dir: URL, message: String) throws {
        try Data(text.utf8).write(to: dir.appending(path: name))
        #expect(Git.execute(["add", "-A"], in: dir).succeeded)
        #expect(Git.execute(["commit", "-q", "-m", message], in: dir).succeeded)
    }

    @Test func branchesHistoryAndWorktreesInARealRepo() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try commit("one\n", "a.txt", in: repo, message: "first")
        try commit("two\n", "a.txt", in: repo, message: "second")

        // Branch names
        var branches = Git.branches(in: repo)
        #expect(branches.map(\.name) == ["main"])
        #expect(Git.branchNameProblem("main", existing: branches, in: repo) != nil)
        #expect(Git.branchNameProblem("bad..name", existing: branches, in: repo) != nil)
        #expect(Git.branchNameProblem("-x", existing: branches, in: repo) != nil)
        #expect(Git.branchNameProblem("feature/ok", existing: branches, in: repo) == nil)

        // Create + switch
        #expect(Git.createBranch("feature/ok", in: repo).succeeded)
        #expect(Git.currentBranch(in: repo) == "feature/ok")
        try commit("b\n", "b.txt", in: repo, message: "on feature")
        branches = Git.branches(in: repo)
        let main = try #require(branches.first { $0.name == "main" })
        #expect(Git.checkout(main, existing: branches, in: repo).succeeded)
        #expect(Git.currentBranch(in: repo) == "main")

        // Stash & switch carries untracked files away.
        try Data("wip\n".utf8).write(to: repo.appending(path: "wip.txt"))
        #expect(Git.stashAll(message: "deck test", in: repo).succeeded)
        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: "wip.txt").path))

        // History: HEAD + default branch; commit files and diff.
        let refs = Git.historyRefs(in: repo)
        #expect(refs.first == "HEAD")
        let log = Git.graphLog(refs: refs + ["feature/ok"], in: repo)
        #expect(log.map(\.subject) == ["on feature", "second", "first"])
        let rows = GitGraphLayout.layout(log)
        #expect(rows.count == 3)
        let files = Git.commitFiles(log[0], in: repo)
        #expect(files == [GitCommitFile(path: "b.txt", state: .added)])
        let rootFiles = Git.commitFiles(log[2], in: repo)
        #expect(rootFiles == [GitCommitFile(path: "a.txt", state: .added)])
        let diff = Git.commitFileDiff(log[1], file: GitCommitFile(path: "a.txt", state: .modified), in: repo)
        #expect(diff.contains("-one") && diff.contains("+two"))

        // Worktrees
        let wtDir = repo.appending(path: ".claude/worktrees/w1")
        #expect(Git.execute(["worktree", "add", "-q", "-b", "wt-1", wtDir.path], in: repo).succeeded)
        var wts = Git.worktrees(in: repo)
        #expect(wts.count == 2)
        #expect(wts[0].isMain && Git.samePath(wts[0].path, repo.path))
        #expect(wts[1].branch == "wt-1")
        #expect(!Git.removeWorktree(wts[0], force: true, in: repo).succeeded)
        try Data("x\n".utf8).write(to: wtDir.appending(path: "dirty.txt"))
        #expect(Git.isDirty(worktree: wts[1].path))
        #expect(!Git.removeWorktree(wts[1], force: false, in: repo).succeeded)
        #expect(Git.removeWorktree(wts[1], force: true, in: repo).succeeded)
        wts = Git.worktrees(in: repo)
        #expect(wts.count == 1)
        #expect(Git.pruneWorktrees(in: repo).succeeded)
    }

    @Test func remoteBranchCheckoutCreatesTrackingBranch() throws {
        let origin = try makeRepo()
        defer { try? FileManager.default.removeItem(at: origin) }
        try commit("1\n", "a.txt", in: origin, message: "base")
        #expect(Git.createBranch("topic", in: origin).succeeded)
        try commit("2\n", "t.txt", in: origin, message: "topic work")
        #expect(Git.execute(["checkout", "-q", "main"], in: origin).succeeded)

        let clone = FileManager.default.temporaryDirectory.appending(path: "deck-clone-\(UUID())")
        defer { try? FileManager.default.removeItem(at: clone) }
        #expect(Git.execute(["clone", "-q", origin.path, clone.path], in: origin).succeeded)
        let branches = Git.branches(in: clone)
        let remote = try #require(branches.first { $0.isRemote && $0.name == "origin/main" })
        #expect(Git.checkout(remote, existing: branches, in: clone).succeeded)   // local main exists → plain switch
        let topic = try #require(branches.first { $0.isRemote && $0.name == "origin/topic" })
        let r = Git.checkout(topic, existing: branches, in: clone)
        #expect(r.succeeded)
        let after = Git.branches(in: clone)
        let local = try #require(after.first { !$0.isRemote && $0.name == "topic" })
        #expect(local.isCurrent && local.upstream == "origin/topic")
        #expect(Git.defaultBranch(in: clone) != nil)
    }
}
