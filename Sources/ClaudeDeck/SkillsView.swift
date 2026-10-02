import AppKit
import ClaudeDeckCore
import Observation
import SwiftUI

/// The Skills tab's list: user, project and plugin skills, reloaded when their folders change.
@MainActor
@Observable
final class SkillsController {
    private(set) var skills: [Skill] = []
    private(set) var loaded = false
    /// Bumped on every reload so the preview re-reads its file.
    private(set) var generation = 0
    private(set) var projectPath: String?
    @ObservationIgnored private var watcher: FSEventsWatcher?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    let home = AppModel.claudeHome

    var userDirectory: URL { SkillCatalog.userSkillsDirectory(home: home) }

    func setProject(_ path: String?) {
        guard path != projectPath || !loaded else { return }
        projectPath = path
        watch()
        reload()
    }

    func reload() {
        loadTask?.cancel()
        let home = home, projectPath = projectPath
        loadTask = Task { [weak self] in
            let skills = await Task.detached { SkillCatalog.load(home: home, projectPath: projectPath) }.value
            guard !Task.isCancelled, let self else { return }
            self.skills = skills
            self.loaded = true
            self.generation += 1
        }
    }

    /// Watches `~/.claude` and the project (or its `.claude`), reloading only for events under a
    /// skills folder or the plugin manifest; folders that don't exist yet are covered by their parent.
    private func watch() {
        watcher?.stop()
        let claude = existingAncestor(home.appending(path: ".claude"))
        var roots = [claude]
        var prefixes = [resolved(userDirectory), resolved(home.appending(path: ".claude/plugins"))]
        if let projectPath {
            let projectClaude = URL(fileURLWithPath: projectPath).appending(path: ".claude")
            roots.append(existingAncestor(projectClaude))
            prefixes.append(resolved(SkillCatalog.projectSkillsDirectory(projectPath)))
        }
        let watched = prefixes
        let watcher = FSEventsWatcher(paths: roots, latency: 0.5) { [weak self] events in
            let relevant = events.contains { event in
                event.mustRescan || watched.contains { event.path == $0 || event.path.hasPrefix($0 + "/") || $0.hasPrefix(event.path + "/") }
            }
            guard relevant else { return }
            MainActor.assumeIsolated { self?.reload() }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// Symlink-resolved path (FSEvents reports real paths), for folders that may not exist yet.
    private func resolved(_ url: URL) -> String {
        var missing: [String] = []
        var base = url
        while !FileManager.default.fileExists(atPath: base.path), base.pathComponents.count > 1 {
            missing.insert(base.lastPathComponent, at: 0)
            base = base.deletingLastPathComponent()
        }
        // realpath, not resolvingSymlinksInPath: that one strips "/private" again (/tmp, /var).
        var real = realpath(base.path, nil).map { p in defer { free(p) }; return URL(fileURLWithPath: String(cString: p)) } ?? base
        for part in missing { real = real.appending(path: part) }
        return real.path
    }

    private func existingAncestor(_ url: URL) -> URL {
        var url = url
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url = url.deletingLastPathComponent() }
        return url
    }

}

struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var controller = SkillsController()
    @State private var selection: String?
    @State private var filter = ""
    @State private var showNewSkill = false

    private var currentProject: Project? {
        model.selectedSessionID.flatMap { model.deck.session($0) }.flatMap { model.deck.project($0.projectID) }
    }

    private var visible: [Skill] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return controller.skills }
        return controller.skills.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q) }
    }

    private var selected: Skill? { selection.flatMap { id in controller.skills.first { $0.id == id } } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 300)
            Divider()
            Group {
                if let skill = selected {
                    SkillDetail(skill: skill, generation: controller.generation) { delete(skill) }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "wand.and.stars").font(.largeTitle).foregroundStyle(.tertiary)
                        Text(controller.loaded && controller.skills.isEmpty ? "No skills yet" : "Select a skill")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { controller.setProject(currentProject?.path) }
        .onChange(of: currentProject?.path) { _, path in controller.setProject(path) }
        .onChange(of: controller.generation) {
            // Keep something selected (the first skill, or a replacement for a deleted one).
            if selected == nil { selection = controller.skills.first?.id }
        }
        .sheet(isPresented: $showNewSkill) {
            NewSkillSheet(userDirectory: controller.userDirectory, project: currentProject) { file in
                controller.reload()
                selection = file.path
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
                Button { showNewSkill = true } label: { Image(systemName: "plus") }
                    .help("New Skill…")
                Button { controller.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
            }
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            List(selection: $selection) {
                section(String(localized: "User"), skills: visible.filter { $0.scope == .user })
                section(currentProject.map { String(localized: "Project — \($0.name)") } ?? String(localized: "Project"),
                        skills: visible.filter { $0.scope == .project })
                section(String(localized: "Plugins"), skills: visible.filter { if case .plugin = $0.scope { true } else { false } })
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder private func section(_ title: String, skills: [Skill]) -> some View {
        if !skills.isEmpty {
            Section(title) {
                ForEach(skills) { skill in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(skill.name).lineLimit(1)
                            Spacer(minLength: 4)
                            ScopeBadge(scope: skill.scope)
                        }
                        if !skill.description.isEmpty {
                            Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(skill.id)
                    .contextMenu { actions(for: skill) }
                }
            }
        }
    }

    @ViewBuilder private func actions(for skill: Skill) -> some View {
        Button("Open in Editor") { model.showFileTab(skill.file, preview: false) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([skill.file]) }
        if skill.isEditable {
            Divider()
            Button("Move to Trash…", role: .destructive) { delete(skill) }
        }
    }

    private func delete(_ skill: Skill) {
        guard skill.isEditable else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Move the skill “\(skill.name)” to the Trash?")
        alert.informativeText = String(localized: "Its whole folder is moved:\n\((skill.folder.path as NSString).abbreviatingWithTildeInPath)")
        alert.addButton(withTitle: String(localized: "Move to Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: skill.folder, resultingItemURL: nil)
            if selection == skill.id { selection = nil }
            controller.reload()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

private struct ScopeBadge: View {
    let scope: Skill.Scope

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch scope {
        case .user: String(localized: "User")
        case .project: String(localized: "Project")
        case .plugin(let name): name
        }
    }

    private var color: Color {
        switch scope {
        case .user: .blue
        case .project: .green
        case .plugin: .purple
        }
    }
}

/// Header with the actions over the rendered SKILL.md.
private struct SkillDetail: View {
    @Environment(AppModel.self) private var model
    let skill: Skill
    let generation: Int
    let onDelete: () -> Void
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(skill.name).font(.title2.weight(.semibold))
                        ScopeBadge(scope: skill.scope)
                    }
                    Text(verbatim: (skill.file.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button("Open in Editor") { model.showFileTab(skill.file, preview: false) }
                Button { NSWorkspace.shared.activateFileViewerSelecting([skill.file]) } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
                if skill.isEditable {
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                        .help("Move to Trash…")
                }
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let text {
                        SkillMarkdownView(markdown: Self.body(of: text))
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: "\(skill.id)#\(generation)") {
            let file = skill.file
            text = await Task.detached {
                guard let handle = try? FileHandle(forReadingFrom: file) else { return String?.none }
                defer { try? handle.close() }
                return String(decoding: (try? handle.read(upToCount: 512 * 1024)) ?? Data(), as: UTF8.self)
            }.value
        }
    }

    /// The markdown after the frontmatter.
    static func body(of text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return normalized }
        let rest = normalized.dropFirst(4)
        guard let end = rest.range(of: "\n---") else { return normalized }
        let after = rest[end.upperBound...]
        return String(after.drop { $0 != "\n" }.dropFirst())
    }
}

/// A small markdown renderer: headings, fenced code, lists, quotes and paragraphs with inline styles.
struct SkillMarkdownView: View {
    let markdown: String

    enum Block: Hashable {
        case heading(Int, String)
        case code(String)
        case bullet(String, String)
        case quote(String)
        case paragraph(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case .code(let code):
            Text(verbatim: code)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        case .bullet(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker).foregroundStyle(.secondary)
                Text(Self.inline(text))
            }
        case .quote(let text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case .paragraph(let text):
            Text(Self.inline(text))
        case .rule:
            Divider()
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.components(separatedBy: "\n") {
            if var lines = code {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(raw)
                    code = lines
                }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "***" { flush(); blocks.append(.rule); continue }
            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"),
               line[hashes] == " ", line.distance(from: line.startIndex, to: hashes) <= 6 {
                flush()
                blocks.append(.heading(line.distance(from: line.startIndex, to: hashes), String(line[hashes...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush()
                let indent = String(repeating: "  ", count: min(4, raw.prefix { $0 == " " }.count / 2))
                blocks.append(.bullet(indent + "•", String(line.dropFirst(2))))
                continue
            }
            if let dot = line.firstIndex(of: "."), dot > line.startIndex, line[..<dot].allSatisfy(\.isNumber),
               line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.bullet(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            if line.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            paragraph.append(line)
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

/// "New Skill…": a name and where it lives; creates the folder with a SKILL.md template and opens it.
private struct NewSkillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let userDirectory: URL
    let project: Project?
    let onCreate: (URL) -> Void
    @State private var name = ""
    @State private var inProject = false
    @State private var error: String?

    private var directory: URL {
        if inProject, let project { SkillCatalog.projectSkillsDirectory(project.path) } else { userDirectory }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Skill").font(.headline)
            TextField("Name", text: $name, prompt: Text(verbatim: "my-skill"))
                .onSubmit(create)
            Text("Lowercase letters, digits and hyphens.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Location", selection: $inProject) {
                Text("User (~/.claude/skills)").tag(false)
                if let project {
                    Text("Project — \(project.name)").tag(true)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func create() {
        do {
            let file = try SkillCatalog.create(name: name.trimmingCharacters(in: .whitespaces), in: directory)
            onCreate(file)
            model.showFileTab(file, preview: false)
            dismiss()
        } catch SkillCatalog.CreateError.invalidName {
            error = String(localized: "Use lowercase letters, digits and hyphens only.")
        } catch SkillCatalog.CreateError.exists {
            error = String(localized: "A skill with this name already exists there.")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
