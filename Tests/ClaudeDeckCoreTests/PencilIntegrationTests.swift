import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct PencilIntegrationTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pencil-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A fake Pen.app containing the given MCP binaries.
    func fakeApp(binaries: [String], executable: Bool = true) throws -> URL {
        let app = try tempDir().appending(path: "Pen With Space.app")
        let out = app.appending(path: "Contents/Resources/app.asar.unpacked/out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for name in binaries {
            let path = out.appending(path: name).path
            FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: executable ? 0o755 : 0o644])
        }
        return app
    }

    // MARK: Settings

    @Test func oldDeckWithoutPencilSettingDecodes() throws {
        let json = #"{"settings":{"resumeOnLaunch":false,"iCloudSync":true}}"#
        let deck = try JSONDecoder().decode(DeckData.self, from: Data(json.utf8))
        #expect(deck.settings.pencilMCP == true)
        #expect(deck.settings.resumeOnLaunch == false)
        #expect(deck.settings.iCloudSync == true)
    }

    @Test func pencilSettingRoundTrips() throws {
        var deck = DeckData()
        deck.settings.pencilMCP = false
        let decoded = try JSONDecoder().decode(DeckData.self, from: JSONEncoder().encode(deck))
        #expect(decoded.settings.pencilMCP == false)
    }

    // MARK: Binary lookup

    @Test func findsBundledBinary() throws {
        let app = try fakeApp(binaries: ["mcp-server-darwin-arm64"])
        #expect(PencilIntegration.mcpBinary(inApp: app)?.lastPathComponent == "mcp-server-darwin-arm64")
    }

    @Test func toleratesX64Binary() throws {
        let app = try fakeApp(binaries: ["mcp-server-darwin-x64"])
        #expect(PencilIntegration.mcpBinary(inApp: app)?.lastPathComponent == "mcp-server-darwin-x64")
    }

    @Test func prefersCurrentArchitecture() throws {
        let app = try fakeApp(binaries: ["mcp-server-darwin-arm64", "mcp-server-darwin-x64"])
        #expect(PencilIntegration.mcpBinary(inApp: app)?.lastPathComponent == PencilIntegration.binaryNames[0])
    }

    @Test func missingOrNonExecutableBinaryIsNil() throws {
        #expect(PencilIntegration.mcpBinary(inApp: try fakeApp(binaries: [])) == nil)
        #expect(PencilIntegration.mcpBinary(inApp: try fakeApp(binaries: ["mcp-server-darwin-arm64"], executable: false)) == nil)
        #expect(PencilIntegration.mcpBinary(inApp: URL(fileURLWithPath: "/nonexistent/Pen.app")) == nil)
    }

    // MARK: Registration

    @Test func registeredNeedsAppFileAndSocket() throws {
        let home = try tempDir()
        #expect(!PencilIntegration.isRegistered(home: home))
        let pencil = home.appending(path: ".pencil")
        try FileManager.default.createDirectory(at: pencil.appending(path: "apps"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: pencil.appending(path: "apps/desktop").path, contents: Data("61752".utf8))
        #expect(!PencilIntegration.isRegistered(home: home))
        try FileManager.default.createDirectory(at: pencil.appending(path: "socket"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: pencil.appending(path: "socket/pencil-desktop.sock").path, contents: nil)
        #expect(PencilIntegration.isRegistered(home: home))
    }

    // MARK: Config

    @Test func configShape() throws {
        let binary = URL(fileURLWithPath: "/Applications/Pen With Space.app/Contents/Resources/app.asar.unpacked/out/mcp-server-darwin-arm64")
        let object = try JSONSerialization.jsonObject(with: PencilIntegration.mcpConfig(binary: binary)) as? [String: Any]
        let servers = object?["mcpServers"] as? [String: Any]
        #expect(servers?.keys.sorted() == ["pencil-desktop"])
        let server = servers?["pencil-desktop"] as? [String: Any]
        #expect(server?["type"] as? String == "stdio")
        #expect(server?["command"] as? String == binary.path)
        #expect(server?["args"] as? [String] == ["--app", "desktop", "--agent", "claudeCodeCLI"])
    }

    @Test func writeConfigCreatesDirectoryAndIsStable() throws {
        let dir = try tempDir().appending(path: "Application Support/ClaudeDeck")
        let binary = URL(fileURLWithPath: "/Applications/Pen.app/x")
        let url = try PencilIntegration.writeConfig(binary: binary, directory: dir)
        #expect(url.lastPathComponent == PencilIntegration.configFileName)
        #expect(try Data(contentsOf: url) == PencilIntegration.mcpConfig(binary: binary))
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        Thread.sleep(forTimeInterval: 0.02)
        try PencilIntegration.writeConfig(binary: binary, directory: dir)
        #expect(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    }

    @Test func launchArgsComeAsAPair() {
        let url = URL(fileURLWithPath: "/tmp/a b/pencil-mcp.json")
        #expect(PencilIntegration.launchArgs(configURL: url) == ["--mcp-config", "/tmp/a b/pencil-mcp.json"])
    }
}
