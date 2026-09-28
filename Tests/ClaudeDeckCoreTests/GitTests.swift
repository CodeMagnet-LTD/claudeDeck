import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct GitTests {
    @Test func parsesPorcelainStatus() {
        let repo = URL(fileURLWithPath: "/r")
        let out = " M src/a.swift\0?? new.txt\0A  src/lib/b.swift\0R  c.swift\0old-c.swift\0 D gone.md\0UU conflict.txt\0"
        let s = Git.parseStatus(out, repo: repo)
        #expect(s["/r/src/a.swift"] == .modified)
        #expect(s["/r/new.txt"] == .untracked)
        #expect(s["/r/src/lib/b.swift"] == .added)
        #expect(s["/r/c.swift"] == .renamed)
        #expect(s["/r/old-c.swift"] == nil)
        #expect(s["/r/gone.md"] == .deleted)
        #expect(s["/r/conflict.txt"] == .conflicted)
        #expect(s["/r/src"] == .modified)       // parents of changes are marked
        #expect(s["/r/src/lib"] == .modified)
    }

    @Test func parsesLog() {
        let sep = Git.fieldSeparator
        let out = "abc123\(sep)Ada\(sep)1700000000\(sep)Fix: a\(sep)b\ndef456\(sep)Bob\(sep)1600000000\(sep)Init\n"
        let log = Git.parseLog(out)
        #expect(log.count == 2)
        #expect(log[0].subject == "Fix: a\(sep)b")
        #expect(log[0].shortHash == "abc123")
        #expect(log[1].date == Date(timeIntervalSince1970: 1600000000))
    }

    @Test func realRepository() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deck-git-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func git(_ args: String...) { _ = Git.run(["-c", "user.name=T", "-c", "user.email=t@t"] + args, in: dir) }
        git("init", "-q")
        let file = dir.appending(path: "a.txt")
        try Data("1".utf8).write(to: file)
        git("add", "a.txt"); git("commit", "-qm", "first")
        try Data("2".utf8).write(to: file)
        git("commit", "-qam", "second")
        try Data("3".utf8).write(to: file)

        let root = try #require(Git.root(of: dir))
        #expect(root.resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path)
        let log = Git.log(of: file, in: root)
        #expect(log.map(\.subject) == ["second", "first"])
        #expect(Git.diff(of: file, at: log[0].hash, in: root).contains("+2"))
        #expect(Git.workingDiff(of: file, in: root).contains("+3"))
        #expect(Git.status(in: root).values.contains(.modified))
        #expect(Git.root(of: FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID())")) == nil)
    }
}
