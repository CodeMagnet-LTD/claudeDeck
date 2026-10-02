import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct HistorySearchTests {
    // MARK: Synthetic transcript lines

    private static func json(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private static func user(_ text: String, cwd: String = "/p", meta: Bool = false, sidechain: Bool = false) -> String {
        json(["type": "user", "cwd": cwd, "isMeta": meta, "isSidechain": sidechain, "timestamp": "2026-01-02T03:04:05.000Z",
              "message": ["role": "user", "content": text]])
    }

    private static func assistant(_ blocks: [[String: Any]], cwd: String = "/p") -> String {
        json(["type": "assistant", "cwd": cwd, "isSidechain": false, "timestamp": "2026-01-02T03:04:06.000Z",
              "message": ["role": "assistant", "content": blocks]])
    }

    private static func toolResult(_ text: String) -> String {
        json(["type": "user", "cwd": "/p", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": text]]]])
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "HistorySearchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ lines: [String], dir: String, id: String, root: URL) throws -> URL {
        let folder = root.appending(path: dir)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func results(_ query: String, _ files: [URL], max: Int = 200) -> [HistorySearchResult] {
        var out: [HistorySearchResult] = []
        HistorySearch.search(query, in: files, maxResults: max) { out.append($0) }
        return out
    }

    // MARK: Tests

    @Test func findsUserAndAssistantTextCaseInsensitively() throws {
        let root = try makeRoot()
        let file = try write([
            Self.user("Please fix the Login Screen"),
            Self.assistant([["type": "thinking", "thinking": "login screen thoughts"], ["type": "text", "text": "I fixed the login screen."]]),
        ], dir: "-p", id: "abc", root: root)
        let found = results("login SCREEN", [file])
        #expect(found.count == 1)
        #expect(found[0].id == "abc")
        #expect(found[0].matchCount == 2)
        #expect(found[0].cwd == "/p")
        #expect(found[0].snippets.map(\.role) == ["user", "assistant"])
    }

    @Test func skipsToolPayloadsThinkingMetaAndSidechains() throws {
        let root = try makeRoot()
        let file = try write([
            Self.toolResult("needle in a tool result"),
            Self.assistant([["type": "thinking", "thinking": "needle"], ["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": "grep needle"]]]),
            Self.user("needle meta", meta: true),
            Self.user("needle sidechain", sidechain: true),
            Self.user("<command-name>needle</command-name>"),
            #"{"type":"attachment","attachment":{"content":"needle"}}"#,
            "not json needle",
        ], dir: "-p", id: "x", root: root)
        #expect(results("needle", [file]).isEmpty)
    }

    @Test func prefilterAgreesWithEscapedJSON() throws {
        let root = try makeRoot()
        let file = try write([
            Self.user("He said \"Hello World\" then\nleft / via C:\\path"),
        ], dir: "-p", id: "e", root: root)
        #expect(results("\"hello world\"", [file]).count == 1)
        #expect(results("then\nleft", [file]).count == 1)
        #expect(results("left / via", [file]).count == 1)
        #expect(results("c:\\path", [file]).count == 1)
        #expect(results("absent", [file]).isEmpty)
    }

    @Test func nonASCIIQueriesMatch() throws {
        let root = try makeRoot()
        let file = try write([Self.user("Çalışma ağacı oluştur")], dir: "-p", id: "tr", root: root)
        #expect(results("ağacı", [file]).count == 1)
        #expect(results("çalışma", [file]).count == 1)
        #expect(HistorySearch.Matcher.prefilterRun(of: "ağacı") == "ac")
        #expect(HistorySearch.Matcher.prefilterRun(of: "ışığ").isEmpty)
        #expect(results("ışık", [file]).isEmpty)
    }

    @Test func handlesChunkBoundariesAndSkipsHugeLines() throws {
        let root = try makeRoot()
        let huge = Self.user(String(repeating: "x", count: HistorySearch.maxLineBytes + 10) + " needle")
        var lines = [Self.user("first needle"), huge]
        // Enough filler to span several 4 MB chunks.
        let filler = Self.assistant([["type": "text", "text": String(repeating: "filler ", count: 2000)]])
        lines += Array(repeating: filler, count: 1500)
        lines.append(Self.user("last needle"))
        let file = try write(lines, dir: "-p", id: "big", root: root)
        let found = results("needle", [file])
        #expect(found.count == 1)
        #expect(found[0].matchCount == 2)
        #expect(found[0].snippets.count == 2)
    }

    @Test func snippetHighlightsTheMatch() {
        let text = String(repeating: "a ", count: 100) + "The   NEEDLE\nhere" + String(repeating: " b", count: 100)
        let range = text.range(of: "needle", options: .caseInsensitive)!
        let s = HistorySearch.snippet(text, match: range, role: "user", date: nil)
        let chars = Array(s.text)
        #expect(String(chars[s.matchStart..<(s.matchStart + s.matchLength)]) == "NEEDLE")
        #expect(s.text.hasPrefix("…"))
        #expect(s.text.hasSuffix("…"))
        #expect(!s.text.contains("\n"))
        #expect(s.text.contains("The NEEDLE here"))
    }

    @Test func scopeKeepsWorktreesAndAvoidsPrefixCollisions() throws {
        let root = try makeRoot()
        try write([Self.user("hit")], dir: "-a-b", id: "1", root: root)
        try write([Self.user("hit")], dir: "-a-b--claude-worktrees-feature", id: "2", root: root)
        try write([Self.user("hit")], dir: "-a-b-c", id: "3", root: root)
        try FileManager.default.createDirectory(at: root.appending(path: "-a-b/1/subagents"), withIntermediateDirectories: true)
        let scoped = HistorySearch.files(root: root, projectPath: "/a/b").map { $0.deletingPathExtension().lastPathComponent }
        #expect(Set(scoped) == ["1", "2"])
        #expect(HistorySearch.files(root: root, projectPath: nil).count == 3)
    }

    @Test func titleUsesAITitleBeforeFirstPrompt() throws {
        let root = try makeRoot()
        let file = try write([
            Self.user("first prompt needle"),
            Self.json(["type": "ai-title", "aiTitle": "Generated title", "sessionId": "t"]),
        ], dir: "-p", id: "t", root: root)
        #expect(results("needle", [file]).first?.title == "Generated title")
    }

    @Test func capsResultsAndCancels() throws {
        let root = try makeRoot()
        let files = try (0..<5).map { try write([Self.user("hit \($0)")], dir: "-p", id: "f\($0)", root: root) }
        #expect(results("hit", files, max: 2).count == 2)
        var count = 0
        HistorySearch.search("hit", in: files, shouldCancel: { count >= 1 }) { _ in count += 1 }
        #expect(count == 1)
    }
}
