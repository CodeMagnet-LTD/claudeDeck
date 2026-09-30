import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct BareFileNameTests {
    func cells(_ line: String) -> [String] { line.map { String($0) } }

    @Test func tokenUnderClickInClaudeFileLine() {
        let line = "› [file] promo-final-en.mp4 (10.7MB)"
        let col = Array(line).firstIndex(of: "-")!
        #expect(BareFileName.token(inCells: cells(line), column: col) == "promo-final-en.mp4")
        #expect(BareFileName.token(inCells: cells(line), column: 2) == nil)          // "[file]"
        #expect(BareFileName.token(inCells: cells(line), column: 1) == nil)          // space
    }

    @Test func tokenStripsQuotesAndPunctuation() {
        for word in ["`README.md`", "(README.md)", "\"README.md\",", "README.md.", "'README.md':"] {
            let line = "see \(word) now"
            #expect(BareFileName.token(inCells: cells(line), column: 5) == "README.md", "\(word)")
        }
    }

    @Test func ordinaryWordsAreNotFileNames() {
        #expect(BareFileName.fileName(from: "hello") == nil)
        #expect(BareFileName.fileName(from: "done.") == nil)
        #expect(BareFileName.fileName(from: ".") == nil)
        #expect(BareFileName.fileName(from: "https://example.com/a.txt") == nil)
        #expect(BareFileName.fileName(from: "src/app") == "src/app")
        #expect(BareFileName.fileName(from: "main.swift:42") == "main.swift:42")
        #expect(BareFileName.fileName(from: ".env") == nil)
    }

    @Test func wideCharactersAndWrappedCells() {
        // A wide character occupies its cell plus an empty continuation cell.
        var row = ["界", "", " "] + cells("a.png") + [" "]
        #expect(BareFileName.token(inCells: row, column: 4) == "a.png")
        // A name made of wide characters, clicked on a continuation cell.
        row = [" ", "写", "", "真", "", ".", "j", "p", "g", " "]
        #expect(BareFileName.token(inCells: row, column: 2) == "写真.jpg")
        // Wrapped rows are joined by the caller; the token spans the join.
        let wrapped = cells("xx long-na") + cells("me.mp4 yy")
        #expect(BareFileName.token(inCells: wrapped, column: 12) == "long-name.mp4")
    }

    @Test func transcriptPathsFromToolInputsMostRecentFirst() {
        let jsonl = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/p/old/out/clip.mp4","content":"x"}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ffmpeg -i in.mov /p/new dir/final/clip.mp4"}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"SendUserFile","input":{"files":["/p/app/out/final/clip.mp4"]}}]}}
        {"type":"user","message":{"content":"/p/other/clip.mp4.bak and /p/other/myclip.mp4"}}
        """
        let paths = BareFileName.transcriptPaths(named: "clip.mp4", in: jsonl)
        #expect(paths.first == "/p/app/out/final/clip.mp4")
        #expect(paths.contains("/p/old/out/clip.mp4"))
        #expect(paths.contains("/p/new dir/final/clip.mp4"))
        #expect(!paths.contains { $0.hasSuffix(".bak") || $0.hasSuffix("myclip.mp4") })
        #expect(paths.firstIndex(of: "/p/new dir/final/clip.mp4")! < paths.firstIndex(of: "/p/old/out/clip.mp4")!)
    }

    @Test func transcriptPathsUnescapeJSON() {
        let jsonl = #"{"input":{"file_path":"/p/a \"q\"/c.txt"}}"#
        #expect(BareFileName.transcriptPaths(named: "c.txt", in: jsonl).first == "/p/a \"q\"/c.txt")
        #expect(BareFileName.transcriptPaths(named: "c.txt", in: #"{"text":"saved\n/p/b/c.txt"}"#) == ["/p/b/c.txt"])
    }

    @Test func folderMatchesAndNewestWins() {
        let listing = ["a/clip.mp4", "clip.mp4", "b/myclip.mp4", "c/d/clip.mp4"]
        #expect(BareFileName.matches(named: "clip.mp4", in: listing) == ["a/clip.mp4", "clip.mp4", "c/d/clip.mp4"])
        #expect(BareFileName.matches(named: "d/clip.mp4", in: listing) == ["c/d/clip.mp4"])
        let dates: [String: Date] = ["a": Date(timeIntervalSince1970: 10), "b": Date(timeIntervalSince1970: 30),
                                     "c": Date(timeIntervalSince1970: 30)]
        #expect(BareFileName.newest(["a", "b", "c", "missing"]) { dates[$0] } == "b")
        #expect(BareFileName.newest(["missing"]) { dates[$0] } == nil)
    }

    @Test func locateSearchesTranscriptThenFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BareFileName-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "out/final"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "node_modules/x"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "README.md"))
        try Data().write(to: root.appending(path: "out/final/clip.mp4"))
        try Data().write(to: root.appending(path: "node_modules/x/dep.js"))
        let outside = root.appending(path: "elsewhere/clip.mov")
        try fm.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: outside)
        let transcript = root.appending(path: "t.jsonl")
        try Data(#"{"input":{"files":["\#(outside.path)"]}}"#.utf8).write(to: transcript)

        let dirs = [root.path]
        func locate(_ name: String) -> String? {
            BareFileName.locate(name, directories: dirs, sessionFolder: root.path, transcriptPath: transcript.path)?.path
        }
        #expect(locate("README.md") == root.appending(path: "README.md").path)
        #expect(locate("clip.mov") == outside.path)
        #expect(locate("clip.mp4") == root.appending(path: "out/final/clip.mp4").path)
        #expect(locate("dep.js") == nil)
        #expect(locate("nothing.txt") == nil)
    }
}
