import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct FileListingTests {
    @Test func sortsFoldersFirstAndHidesNoise() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "deck-files-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for dir in ["src", "node_modules", ".git", ".claude", "Beta"] {
            try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        for file in ["b.txt", "A.md", ".env", "file10.txt", "file2.txt"] {
            try Data().write(to: root.appending(path: file))
        }
        #expect(FileListing.children(of: root).map(\.name) == [".claude", "Beta", "src", "A.md", "b.txt", "file2.txt", "file10.txt"])
        #expect(FileListing.children(of: root, showHidden: true).map(\.name).contains(".env"))
        #expect(!FileListing.children(of: root, showHidden: true).map(\.name).contains(".git"))
    }

    @Test func relativePaths() {
        let root = URL(fileURLWithPath: "/w/app")
        #expect(FileListing.relativePath(of: URL(fileURLWithPath: "/w/app/src/a.ts"), in: root) == "src/a.ts")
        #expect(FileListing.relativePath(of: URL(fileURLWithPath: "/w/apple/x"), in: root) == "/w/apple/x")
    }
}
