import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct SkillCatalogTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "SkillCatalogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func skill(_ text: String, at dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    }

    @Test func parsesPlainQuotedAndBlockScalars() {
        let text = """
        ---
        name: "my-skill"
        description: >
          Folded line one
          continues here.

          Second paragraph.
        other: |
          keep
          lines
        allowed-tools: Read, Grep
        ---
        # Body
        name: not frontmatter
        """
        let meta = SkillCatalog.frontmatter(text)
        #expect(meta["name"] == "my-skill")
        #expect(meta["description"] == "Folded line one continues here.\nSecond paragraph.")
        #expect(meta["other"] == "keep\nlines")
        #expect(meta["allowed-tools"] == "Read, Grep")
    }

    @Test func toleratesMissingOrBrokenFrontmatter() {
        #expect(SkillCatalog.frontmatter("# Just markdown").isEmpty)
        #expect(SkillCatalog.frontmatter("---\nname: x\nno end").isEmpty)
        #expect(SkillCatalog.frontmatter("---\r\nname: 'it''s'\r\n---\r\n")["name"] == "it's")
    }

    @Test func loadsUserProjectAndPluginSkills() throws {
        let home = try makeRoot()
        let project = home.appending(path: "proj")
        try skill("---\nname: beta\ndescription: B\n---\n", at: home.appending(path: ".claude/skills/beta"))
        try skill("no frontmatter", at: home.appending(path: ".claude/skills/alpha-folder"))
        try FileManager.default.createDirectory(at: home.appending(path: ".claude/skills/empty"), withIntermediateDirectories: true)
        try skill("---\nname: proj-skill\ndescription: P\n---\n", at: project.appending(path: ".claude/skills/proj-skill"))
        let pluginPath = home.appending(path: "plugcache/thing/1.0")
        try skill("---\nname: plug\ndescription: From a plugin\n---\n", at: pluginPath.appending(path: "skills/plug"))
        let manifest: [String: Any] = ["version": 2, "plugins": [
            "thing@market": [["installPath": pluginPath.path, "scope": "user"]],
            "gone@market": [["installPath": home.appending(path: "missing").path]],
            "broken@market": "nonsense",
        ]]
        try FileManager.default.createDirectory(at: home.appending(path: ".claude/plugins"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: SkillCatalog.pluginsManifest(home: home))

        let skills = SkillCatalog.load(home: home, projectPath: project.path)
        #expect(skills.map(\.name) == ["alpha-folder", "beta", "proj-skill", "plug"])
        #expect(skills.map(\.scope) == [.user, .user, .project, .plugin("thing")])
        #expect(skills[1].description == "B")
        #expect(skills[3].isEditable == false && skills[0].isEditable)
        #expect(SkillCatalog.load(home: home, projectPath: nil).count == 3)
    }

    @Test func createsFromTemplateAndValidatesNames() throws {
        let dir = try makeRoot().appending(path: ".claude/skills")
        let file = try SkillCatalog.create(name: "new-skill", in: dir)
        #expect(file.lastPathComponent == "SKILL.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(SkillCatalog.frontmatter(text)["name"] == "new-skill")
        #expect(throws: SkillCatalog.CreateError.exists) { try SkillCatalog.create(name: "new-skill", in: dir) }
        #expect(throws: SkillCatalog.CreateError.invalidName) { try SkillCatalog.create(name: "Bad Name", in: dir) }
        #expect(!SkillCatalog.isValidName("-x") && !SkillCatalog.isValidName("") && !SkillCatalog.isValidName("a/b"))
        #expect(SkillCatalog.isValidName("a1-b2"))
    }
}
