import Foundation

/// A Claude Code skill: a folder with a `SKILL.md` (YAML frontmatter `name` / `description`).
public struct Skill: Identifiable, Sendable, Equatable {
    public enum Scope: Sendable, Equatable, Hashable {
        /// `~/.claude/skills`
        case user
        /// `<project>/.claude/skills`
        case project
        /// An installed plugin's `skills` folder (read-only here).
        case plugin(String)
    }

    public var name: String
    public var description: String
    public var scope: Scope
    /// The `SKILL.md` file.
    public var file: URL

    public var id: String { file.path }
    public var folder: URL { file.deletingLastPathComponent() }
    public var isEditable: Bool { if case .plugin = scope { false } else { true } }
}

public enum SkillCatalog {
    public static func userSkillsDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".claude/skills")
    }

    public static func projectSkillsDirectory(_ projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath).appending(path: ".claude/skills")
    }

    public static func pluginsManifest(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".claude/plugins/installed_plugins.json")
    }

    /// User, project and plugin skills, each group sorted by name.
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser, projectPath: String?) -> [Skill] {
        var skills = skills(in: userSkillsDirectory(home: home), scope: .user)
        if let projectPath { skills += Self.skills(in: projectSkillsDirectory(projectPath), scope: .project) }
        for plugin in installedPlugins(manifest: pluginsManifest(home: home)) {
            skills += Self.skills(in: URL(fileURLWithPath: plugin.installPath).appending(path: "skills"), scope: .plugin(plugin.name))
        }
        return skills
    }

    /// `<dir>/*/SKILL.md`.
    public static func skills(in directory: URL, scope: Skill.Scope) -> [Skill] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return folders.compactMap { folder -> Skill? in
            let file = folder.appending(path: "SKILL.md")
            guard fm.fileExists(atPath: file.path) else { return nil }
            let head = (try? FileHandle(forReadingFrom: file)).flatMap { handle in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 64 * 1024)
            } ?? Data()
            let meta = frontmatter(String(decoding: head, as: UTF8.self))
            let name = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
            return Skill(name: name, description: meta["description"] ?? "", scope: scope, file: file)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Plugins

    public struct InstalledPlugin: Sendable, Equatable {
        public var name: String
        public var installPath: String
    }

    /// `installed_plugins.json` (v2: `plugins[name@marketplace] = [{installPath, …}]`; v1: one object).
    public static func installedPlugins(manifest: URL) -> [InstalledPlugin] {
        guard let data = try? Data(contentsOf: manifest),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let plugins = (root["plugins"] as? [String: Any]) ?? root
        var seen = Set<String>()
        var out: [InstalledPlugin] = []
        for key in plugins.keys.sorted() {
            let entries: [[String: Any]] = (plugins[key] as? [[String: Any]]) ?? ((plugins[key] as? [String: Any]).map { [$0] } ?? [])
            let name = key.split(separator: "@").first.map(String.init) ?? key
            for entry in entries {
                guard let path = entry["installPath"] as? String, seen.insert(path).inserted else { continue }
                out.append(InstalledPlugin(name: name, installPath: path))
            }
        }
        return out
    }

    // MARK: Frontmatter

    /// Top-level scalar keys of a `---` YAML frontmatter block: plain, quoted, and `|` / `>` block
    /// scalars (folded ones joined with spaces). Not a full YAML parser.
    public static func frontmatter(_ text: String) -> [String: String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return [:] }
        let body = Array(lines[..<end])
        var result: [String: String] = [:]
        var i = 0
        while i < body.count {
            let line = body[i]
            i += 1
            guard let first = line.first, !first.isWhitespace, first != "#", let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Indented continuation lines (block scalars, or a plain scalar wrapped onto more lines).
            var continuation: [String] = []
            while i < body.count, body[i].isEmpty || body[i].first?.isWhitespace == true {
                continuation.append(body[i].trimmingCharacters(in: .whitespaces))
                i += 1
            }
            while continuation.last?.isEmpty == true { continuation.removeLast() }
            if value.hasPrefix("|") || value.hasPrefix(">") {
                value = value.hasPrefix("|") ? continuation.joined(separator: "\n") : folded(continuation)
            } else {
                if !continuation.isEmpty { value = ([value] + continuation).filter { !$0.isEmpty }.joined(separator: " ") }
                value = unquoted(value)
            }
            result[key] = value
        }
        return result
    }

    private static func folded(_ lines: [String]) -> String {
        var paragraphs: [[String]] = [[]]
        for line in lines {
            if line.isEmpty { paragraphs.append([]) } else { paragraphs[paragraphs.count - 1].append(line) }
        }
        return paragraphs.map { $0.joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q else { return value }
        let inner = String(value.dropFirst().dropLast())
        return q == "'" ? inner.replacingOccurrences(of: "''", with: "'")
            : inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
    }

    // MARK: Creating

    /// Lowercase letters, digits and hyphens, starting with a letter or digit (Claude Code's skill names).
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 64,
              CharacterSet.lowercaseLetters.contains(first) || CharacterSet.decimalDigits.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ($0.isASCII && (CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0))) || $0 == "-" }
    }

    public static func template(name: String) -> String {
        """
        ---
        name: \(name)
        description: Describe what this skill does and when Claude should use it.
        ---

        # \(name)

        ## Instructions

        Step-by-step guidance for Claude.

        """
    }

    public enum CreateError: Error, Equatable {
        case invalidName
        case exists
    }

    /// Creates `<directory>/<name>/SKILL.md` from the template. Returns the file.
    public static func create(name: String, in directory: URL) throws -> URL {
        guard isValidName(name) else { throw CreateError.invalidName }
        let folder = directory.appending(path: name)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { throw CreateError.exists }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "SKILL.md")
        try template(name: name).write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
