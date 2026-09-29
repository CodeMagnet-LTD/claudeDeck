import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct TerminalLinkTests {
    let project = "/Users/me/app"
    let existing: Set<String> = [
        "/Users/me/app/promo-video/out/babycanvas-promo.mp4",
        "/Users/me/app/Sources/main.swift",
        "/Users/me/app/docs",
        "/Users/me/other/file.txt",
        "/tmp/abs.log",
    ]
    func resolve(_ link: String, dirs: [String]? = nil) -> TerminalLink? {
        TerminalLink.resolve(link, in: dirs ?? [project]) { existing.contains($0) }
    }

    @Test func relativePathResolvesAgainstSessionFolder() {
        #expect(resolve("promo-video/out/babycanvas-promo.mp4")
                == .file(URL(fileURLWithPath: "/Users/me/app/promo-video/out/babycanvas-promo.mp4"), line: nil))
    }

    @Test func dotSlashAndParentPaths() {
        #expect(resolve("./Sources/main.swift") == .file(URL(fileURLWithPath: "/Users/me/app/Sources/main.swift"), line: nil))
        #expect(resolve("../other/file.txt") == .file(URL(fileURLWithPath: "/Users/me/other/file.txt"), line: nil))
    }

    @Test func lineAndColumnSuffix() {
        #expect(resolve("Sources/main.swift:42") == .file(URL(fileURLWithPath: "/Users/me/app/Sources/main.swift"), line: 42))
        #expect(resolve("Sources/main.swift:42:7") == .file(URL(fileURLWithPath: "/Users/me/app/Sources/main.swift"), line: 42))
    }

    @Test func absolutePathAndDirectory() {
        #expect(resolve("/tmp/abs.log") == .file(URL(fileURLWithPath: "/tmp/abs.log"), line: nil))
        #expect(resolve("docs") == .file(URL(fileURLWithPath: "/Users/me/app/docs"), line: nil))
    }

    @Test func firstMatchingDirectoryWins() {
        #expect(resolve("file.txt", dirs: ["/nowhere", "/Users/me/other"])
                == .file(URL(fileURLWithPath: "/Users/me/other/file.txt"), line: nil))
    }

    @Test func urls() {
        #expect(resolve("https://github.com/acme/app/pull/42") == .url(URL(string: "https://github.com/acme/app/pull/42")!))
        #expect(resolve("mailto:a@b.c") == .url(URL(string: "mailto:a@b.c")!))
        #expect(resolve("file:///tmp/abs.log") == .file(URL(string: "file:///tmp/abs.log")!, line: nil))
    }

    @Test func missingFileIsNil() {
        #expect(resolve("nope/missing.mp4") == nil)
        #expect(resolve("   ") == nil)
    }

    @Test func hostURI() {
        #expect(TerminalLink.directory(fromHostURI: "file://mac.local/Users/me/app") == "/Users/me/app")
        #expect(TerminalLink.directory(fromHostURI: "/Users/me/app") == "/Users/me/app")
        #expect(TerminalLink.directory(fromHostURI: nil) == nil)
        #expect(TerminalLink.directory(fromHostURI: "http://x/y") == nil)
    }
}
