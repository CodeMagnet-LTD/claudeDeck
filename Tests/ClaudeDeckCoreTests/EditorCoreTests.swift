import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct TextFileIOTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deck-editor-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func roundTripsCRLFAndTrailingNewline() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.txt")
        try Data("one\r\ntwo\r\n".utf8).write(to: url)
        var file = try TextFileIO.read(url)
        #expect(file.text == "one\ntwo\n")
        #expect(file.lineEnding == .crlf)
        file.text += "three"
        try TextFileIO.write(file, to: url)
        #expect(try Data(contentsOf: url) == Data("one\r\ntwo\r\nthree".utf8))
    }

    @Test func keepsLFAndNoTrailingNewline() throws {
        let data = Data("a\nb".utf8)
        let file = try TextFileContents.decode(data)
        #expect(file.lineEnding == .lf)
        #expect(file.encoded() == data)
    }

    @Test func keepsBOM() throws {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("x\n".utf8))
        let file = try TextFileContents.decode(data)
        #expect(file.hasBOM && file.text == "x\n")
        #expect(file.encoded() == data)
    }

    @Test func refusesBinaryNonUTF8AndHuge() throws {
        #expect(throws: TextFileError.binary) { try TextFileContents.decode(Data([0x61, 0x00, 0x62])) }
        #expect(throws: TextFileError.notUTF8) { try TextFileContents.decode(Data([0x61, 0xFF, 0xFE])) }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appending(path: "big.txt")
        try Data(repeating: 0x61, count: TextFileIO.maxBytes + 1).write(to: big)
        #expect(throws: TextFileError.tooLarge(bytes: TextFileIO.maxBytes + 1)) { try TextFileIO.read(big) }
        #expect(!TextFileIO.looksEditable(big))
        let bin = dir.appending(path: "x.bin")
        try Data([1, 0, 2]).write(to: bin)
        #expect(!TextFileIO.looksEditable(bin))
        let text = dir.appending(path: "x.swift")
        try Data("let ü = 1\n".utf8).write(to: text)
        #expect(TextFileIO.looksEditable(text))
        #expect(throws: TextFileError.notAFile) { try TextFileIO.read(dir) }
    }

    @Test func atomicSaveKeepsPermissionsAndFollowsSymlinks() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let target = dir.appending(path: "script.sh")
        try Data("echo hi\n".utf8).write(to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let link = dir.appending(path: "link.sh")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let written = try TextFileIO.write(TextFileContents(text: "echo bye\n"), to: link)
        #expect(written.path == target.resolvingSymlinksInPath().path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "echo bye\n")
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target.path)
        let perms = try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(perms == 0o755)
        // No temporary files left behind.
        #expect(try fm.contentsOfDirectory(atPath: dir.path).sorted() == ["link.sh", "script.sh"])
    }

    @Test func detectsIndentation() {
        #expect(Indentation.detect("a\n\tb\n\t\tc\n") == Indentation(usesTabs: true, width: 4))
        #expect(Indentation.detect("a:\n  b:\n    c: 1\n  d: 2\n") == Indentation(usesTabs: false, width: 2))
        #expect(Indentation.detect("func a() {\n    b()\n}\n") == Indentation(usesTabs: false, width: 4))
        #expect(Indentation.detect("") == Indentation())
    }

    @Test func oldSettingsDecodeWithEditorDefaults() throws {
        let json = #"{"settings":{"resumeOnLaunch":false,"theme":"dark"}}"#
        let deck = try JSONDecoder().decode(DeckData.self, from: Data(json.utf8))
        #expect(deck.settings.resumeOnLaunch == false)
        #expect(deck.settings.openFilesInBuiltInEditor == true)
        #expect(deck.settings.editorFontSize == DeckSettings.defaultFontSize)
        #expect(deck.settings.editorWrapLines == true)
    }
}

@Suite struct SyntaxTokenizerTests {
    private func kinds(_ language: SyntaxLanguage, _ line: String, from state: SyntaxLineState = .normal) -> [(SyntaxTokenKind, String)] {
        let units = Array(line.utf16)
        return SyntaxTokenizer(language: language).tokenize(line, from: state).tokens.map {
            ($0.kind, String(decoding: units[$0.range], as: UTF16.self))
        }
    }

    private func same(_ a: [(SyntaxTokenKind, String)], _ b: [(SyntaxTokenKind, String)]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    @Test func languageDetection() {
        #expect(SyntaxLanguage.detect(fileName: "App.swift") == .swift)
        #expect(SyntaxLanguage.detect(fileName: "index.TSX") == .typescript)
        #expect(SyntaxLanguage.detect(fileName: "Dockerfile") == .shell)
        #expect(SyntaxLanguage.detect(fileName: "ci.yml") == .yaml)
        #expect(SyntaxLanguage.detect(fileName: "notes.txt") == .plain)
    }

    @Test func swiftLine() {
        let got = kinds(.swift, #"@MainActor let x: Int = 0x1F + 2.5 // done "q""#)
        #expect(same(got, [(.attribute, "@MainActor"), (.keyword, "let"), (.type, "Int"), (.number, "0x1F"), (.number, "2.5"), (.comment, #"// done "q""#)]))
    }

    @Test func stringsHideCommentsAndEscapes() {
        let got = kinds(.javascript, #"const u = "http://x \" y"; // c"#)
        #expect(same(got, [(.keyword, "const"), (.string, #""http://x \" y""#), (.comment, "// c")]))
    }

    @Test func blockCommentSpansLines() {
        let t = SyntaxTokenizer(language: .go)
        let a = t.tokenize("x := 1 /* start", from: .normal)
        #expect(a.end == .blockComment)
        let b = t.tokenize("still */ return", from: a.end)
        #expect(b.end == .normal)
        #expect(b.tokens.map(\.kind) == [.comment, .keyword])
        #expect(b.tokens[0].range == 0..<8)
    }

    @Test func pythonTripleQuotedString() {
        let t = SyntaxTokenizer(language: .python)
        let a = t.tokenize(#"def f(): s = """doc"#, from: .normal)
        #expect(a.end == .string(close: #"""""#))
        let b = t.tokenize(#"end""" # c"#, from: a.end)
        #expect(b.end == .normal)
        #expect(b.tokens.map(\.kind) == [.string, .comment])
    }

    @Test func rustLifetimeIsNotAString() {
        let got = kinds(.rust, "fn f<'a>(c: char) -> &'a str { 'x' }")
        #expect(got.contains { $0.0 == .string && $0.1 == "'x'" })
        #expect(!got.contains { $0.0 == .string && $0.1.hasPrefix("'a") })
    }

    @Test func jsonKeysAndLiterals() {
        let got = kinds(.json, #"  "name": "deck", "ok": true, "n": -1.5e3"#)
        #expect(same(got, [(.attribute, #""name""#), (.string, #""deck""#), (.attribute, #""ok""#), (.keyword, "true"), (.attribute, #""n""#), (.number, "1.5e3")]))
    }

    @Test func yamlAndShell() {
        #expect(same(kinds(.yaml, "  - name: build # step"), [(.attribute, "name"), (.comment, "# step")]))
        #expect(same(kinds(.shell, #"echo "$HOME" a#b $1 # c"#), [(.keyword, "echo"), (.string, #""$HOME""#), (.variable, "$1"), (.comment, "# c")]))
    }

    @Test func markdownHeadingsFencesAndInlineCode() {
        let t = SyntaxTokenizer(language: .markdown)
        #expect(t.tokenize("## Title").tokens.map(\.kind) == [.heading])
        #expect(t.tokenize("#hashtag").tokens.isEmpty)
        let fence = t.tokenize("```swift")
        #expect(fence.end == .string(close: "```"))
        #expect(t.tokenize("# not a heading", from: fence.end).tokens.map(\.kind) == [.string])
        #expect(t.tokenize("```", from: fence.end).end == .normal)
        #expect(same(kinds(.markdown, "use `x` here"), [(.string, "`x`")]))
    }

    @Test func htmlAndCSS() {
        let got = kinds(.html, #"<a href="/x">hi</a> <!-- c -->"#)
        #expect(same(got, [(.tag, "<a"), (.attribute, "href"), (.string, #""/x""#), (.tag, "</a"), (.comment, "<!-- c -->")]))
        let css = kinds(.css, "  color: #fff; margin: 4px /* c */")
        #expect(same(css, [(.attribute, "color"), (.number, "#fff"), (.attribute, "margin"), (.number, "4px"), (.comment, "/* c */")]))
    }

    @Test func plainTextHasNoTokens() {
        #expect(SyntaxTokenizer(language: .plain).tokenize("let x = 1 // y").tokens.isEmpty)
    }
}

@Suite struct SyntaxLineCacheTests {
    @Test func lineIndex() {
        let index = LineIndex("ab\n\ncd" as NSString)
        #expect(index.starts == [0, 3, 4])
        #expect(index.line(containing: 0) == 0)
        #expect(index.line(containing: 3) == 1)
        #expect(index.line(containing: 5) == 2)
        #expect(index.range(ofLine: 0) == NSRange(location: 0, length: 2))
        #expect(index.range(ofLine: 2) == NSRange(location: 4, length: 2))
    }

    @Test func incrementalUpdateMatchesFullRebuild() {
        var lines = (0..<2000).map { "let v\($0) = \($0) // line" }
        var text = lines.joined(separator: "\n")
        var cache = SyntaxLineCache(language: .swift)
        cache.rebuild(text as NSString)

        // Open a block comment at line 10: everything after becomes comment.
        let insertAt = (text as NSString).range(of: "let v10").location
        text = (text as NSString).replacingCharacters(in: NSRange(location: insertAt, length: 0), with: "/*\n")
        let touched = cache.update(text as NSString, editedRange: NSRange(location: insertAt, length: 3), delta: 3)
        var full = SyntaxLineCache(language: .swift)
        full.rebuild(text as NSString)
        #expect(cache.states == full.states)
        #expect(touched.upperBound == cache.lines.count)
        #expect(cache.states.last == .blockComment)

        // Ordinary typing on one line only touches that line.
        lines = text.components(separatedBy: "\n")
        let at = (text as NSString).range(of: "let v1500").location
        text = (text as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: "x")
        let small = cache.update(text as NSString, editedRange: NSRange(location: at, length: 1), delta: 1)
        full.rebuild(text as NSString)
        #expect(cache.states == full.states)
        #expect(small.count <= 2)
    }
}
