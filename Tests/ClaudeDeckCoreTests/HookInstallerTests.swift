import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct HookInstallerTests {
    let command = "/Users/me/.claude/deck/bin/deck-hook.sh"

    /// Works under both `swift test` and Xcode (no Bundle.module there).
    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/settings-existing.json")

    func fixture() throws -> [String: Any] {
        let url = Self.fixtureURL
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func groups(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    @Test func appendsWithoutTouchingExistingHooks() throws {
        let original = try fixture()
        let merged = HookInstaller.installing(command: command, events: HookScript.events, into: original)

        // Existing groups are kept verbatim and in order; ours is appended last.
        for event in ["SessionStart", "PostToolUse", "PreToolUse"] {
            let before = groups(original, event)
            let after = groups(merged, event)
            #expect(after.count == before.count + 1)
            for (a, b) in zip(before, after) {
                #expect(NSDictionary(dictionary: a).isEqual(to: b))
            }
            let ours = try #require(after.last)
            #expect(ours["matcher"] == nil)
            #expect((ours["hooks"] as? [[String: Any]])?.first?["command"] as? String == command)
        }
        // Other settings untouched.
        #expect(merged["model"] as? String == "opus")
        #expect(merged["remoteControlAtStartup"] as? Bool == true)
        #expect(NSDictionary(dictionary: merged["permissions"] as! [String: Any])
            .isEqual(to: original["permissions"] as! [String: Any]))
        #expect(HookInstaller.isInstalled(command: command, events: HookScript.events, in: merged))
        #expect(!HookInstaller.isInstalled(command: command, events: HookScript.events, in: original))
    }

    @Test func secondInstallIsNoOp() throws {
        let once = HookInstaller.installing(command: command, events: HookScript.events, into: try fixture())
        let twice = HookInstaller.installing(command: command, events: HookScript.events, into: once)
        #expect(NSDictionary(dictionary: once).isEqual(to: twice))
    }

    @Test func updatesOutdatedCommandInPlace() throws {
        let old = HookInstaller.installing(command: "/old/home/.claude/deck/bin/deck-hook.sh", events: HookScript.events, into: try fixture())
        let new = HookInstaller.installing(command: command, events: HookScript.events, into: old)
        for event in HookScript.events {
            let all = groups(new, event).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            #expect(all.filter { ($0["command"] as? String)?.contains(HookInstaller.marker) == true }.count == 1)
        }
    }

    @Test func removeRestoresOriginal() throws {
        let original = try fixture()
        let merged = HookInstaller.installing(command: command, events: HookScript.events, into: original)
        let removed = HookInstaller.removing(from: merged)
        #expect(NSDictionary(dictionary: removed).isEqual(to: original))
    }

    @Test func removeFromEmptySettings() {
        let merged = HookInstaller.installing(command: command, events: HookScript.events, into: [:])
        #expect(HookInstaller.removing(from: merged).isEmpty)
    }

    @Test func fileInstallBacksUpAndIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = dir.appending(path: "settings.json")
        try FileManager.default.copyItem(at: Self.fixtureURL, to: settings)

        let installer = HookInstaller(settingsURL: settings, scriptURL: dir.appending(path: ".claude/deck/bin/deck-hook.sh"))
        #expect(try installer.install() == true)
        #expect(installer.isInstalled())
        #expect(try installer.install() == false)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("claudedeck-backup") }
        #expect(backups.count == 1)
        #expect(try installer.uninstall() == true)
        #expect(!installer.isInstalled())
    }

    @Test func refusesToOverwriteInvalidSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = dir.appending(path: "settings.json")
        try Data("{ not json".utf8).write(to: settings)
        let installer = HookInstaller(settingsURL: settings, scriptURL: dir.appending(path: "deck-hook.sh"))
        #expect(throws: HookInstaller.InstallError.self) { try installer.install() }
        #expect(try String(contentsOf: settings, encoding: .utf8) == "{ not json")
    }
}
