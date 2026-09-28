import Foundation

/// Installs / removes ClaudeDeck's hook in Claude Code's user settings without
/// touching anybody else's hooks. Every write is preceded by a timestamped backup.
public struct HookInstaller: Sendable {
    public let settingsURL: URL
    public let scriptURL: URL

    /// Substring that identifies our hook entries in settings.json.
    public static let marker = "/.claude/deck/bin/deck-hook"

    public init(settingsURL: URL, scriptURL: URL) {
        self.settingsURL = settingsURL
        self.scriptURL = scriptURL
    }

    public static func `default`(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> HookInstaller {
        HookInstaller(
            settingsURL: home.appending(path: ".claude/settings.json"),
            scriptURL: home.appending(path: ".claude/deck/bin/deck-hook.sh")
        )
    }

    public var command: String { scriptURL.path }

    // MARK: Pure merge logic (unit tested)

    /// Returns `settings` with our hook group appended to every event that lacks it.
    /// Existing groups are never modified; an outdated command of ours is rewritten in place.
    public static func installing(command: String, events: [String], into settings: [String: Any]) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var found = false
            for (gi, group) in groups.enumerated() {
                guard var entries = group["hooks"] as? [[String: Any]] else { continue }
                for (ei, entry) in entries.enumerated() where isOurs(entry) {
                    found = true
                    if entry["command"] as? String != command {
                        entries[ei]["command"] = command
                    }
                }
                var updated = group
                updated["hooks"] = entries
                groups[gi] = updated
            }
            if !found {
                groups.append(["hooks": [["type": "command", "command": command, "timeout": 10]]])
            }
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Returns `settings` with every hook entry of ours removed (and groups/events left empty by that).
    public static func removing(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else { kept.append(group); continue }
                let remaining = entries.filter { !isOurs($0) }
                if remaining.count == entries.count { kept.append(group); continue }
                if remaining.isEmpty { continue }
                var updated = group
                updated["hooks"] = remaining
                kept.append(updated)
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    public static func isInstalled(command: String, events: [String], in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { event in
            let groups = hooks[event] as? [[String: Any]] ?? []
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
        }
    }

    static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(marker) == true
    }

    // MARK: File system

    public enum InstallError: Error, LocalizedError {
        case unreadableSettings(String)
        case unexpectedShape(String)
        public var errorDescription: String? {
            switch self {
            case .unreadableSettings(let why): String(localized: "Couldn’t read ~/.claude/settings.json: \(why)")
            case .unexpectedShape(let key): String(localized: "\"\(key)\" in ~/.claude/settings.json has an unexpected format; left untouched.")
            }
        }
    }

    /// Refuses to merge into `hooks` values we don't understand instead of replacing them.
    static func validateShape(_ settings: [String: Any], events: [String]) throws {
        guard let raw = settings["hooks"] else { return }
        guard let hooks = raw as? [String: Any] else { throw InstallError.unexpectedShape("hooks") }
        for event in events {
            if let value = hooks[event], !(value is [[String: Any]]) {
                throw InstallError.unexpectedShape("hooks.\(event)")
            }
        }
    }

    /// Writes the hook script (if changed) and merges the settings (if changed).
    /// Returns true when settings.json was modified.
    @discardableResult
    public func install() throws -> Bool {
        try writeScript()
        let current = try readSettings()
        try Self.validateShape(current, events: HookScript.events)
        let next = Self.installing(command: command, events: HookScript.events, into: current)
        return try writeIfChanged(current: current, next: next)
    }

    @discardableResult
    public func uninstall() throws -> Bool {
        let current = try readSettings()
        return try writeIfChanged(current: current, next: Self.removing(from: current))
    }

    public func isInstalled() -> Bool {
        guard let settings = try? readSettings() else { return false }
        return Self.isInstalled(command: command, events: HookScript.events, in: settings)
            && FileManager.default.isExecutableFile(atPath: scriptURL.path)
    }

    func writeScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(HookScript.source.utf8)
        if (try? Data(contentsOf: scriptURL)) != data {
            try data.write(to: scriptURL, options: .atomic)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.unreadableSettings(String(localized: "the root value is not a JSON object"))
            }
            return object
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.unreadableSettings(error.localizedDescription)
        }
    }

    func writeIfChanged(current: [String: Any], next: [String: Any]) throws -> Bool {
        if NSDictionary(dictionary: current).isEqual(to: next) { return false }
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let stamp = ISO8601DateFormatter.backupStamp.string(from: Date())
            let backup = settingsURL.deletingLastPathComponent()
                .appending(path: "settings.json.claudedeck-backup-\(stamp)")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL.resolvingSymlinksInPath(), to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: next,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        // Write through a symlinked settings.json (dotfile managers) instead of replacing the link.
        try data.write(to: settingsURL.resolvingSymlinksInPath(), options: .atomic)
        return true
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let backupStamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        return f
    }()
}
