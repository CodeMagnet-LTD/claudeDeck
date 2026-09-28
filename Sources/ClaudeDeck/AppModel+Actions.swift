import AppKit
import SwiftUI
import ClaudeDeckCore

extension AppModel {
    func setTheme(_ theme: AppTheme) {
        mutate { $0.settings.theme = theme }
        applyTheme()
    }

    /// App-wide appearance; terminals follow through `viewDidChangeEffectiveAppearance`.
    func applyTheme() {
        switch deck.settings.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// ⌘+ / ⌘- / ⌘0 — nil resets to the default size.
    func zoomTerminals(by step: Double?) {
        let current = deck.settings.terminalFontSize
        let next = step.map { current + $0 } ?? DeckSettings.defaultFontSize
        let clamped = min(max(next, DeckSettings.fontSizeRange.lowerBound), DeckSettings.fontSizeRange.upperBound)
        mutate { $0.settings.terminalFontSize = clamped }
        terminals.fontSize = clamped
    }

    /// The sidebar list selects on mouse-down; applying that immediately would swap the focused
    /// pane before a drag even starts. So the selection is applied on mouse-up, and skipped if
    /// the press turned into a drag of this session.
    func selectFromSidebar(_ id: UUID) {
        lastDraggedSessionID = nil
        Task { @MainActor in
            var waited = 0
            while NSEvent.pressedMouseButtons & 1 != 0, waited < 200 {
                try? await Task.sleep(for: .milliseconds(25))
                waited += 1
            }
            if lastDraggedSessionID == id { return }
            selectedSessionID = id
        }
    }

    /// Clicking a project: show its files; if it has a running session, show that session (most
    /// recently active); otherwise leave the terminal view alone, start nothing, just open/close it.
    func openProject(_ id: UUID) {
        guard let project = deck.project(id) else { return }
        browsedProjectID = id
        let running = deck.sessions(in: id).filter { terminals.isRunning($0.id) }
        if let recent = running.max(by: { ($0.lastActivityAt ?? $0.createdAt) < ($1.lastActivityAt ?? $1.createdAt) }) {
            if project.collapsed { mutate { $0.updateProject(id) { $0.collapsed = false } } }
            selectedSessionID = recent.id
        } else if idleExpandedProjects.contains(id) {
            idleExpandedProjects.remove(id)
        } else {
            idleExpandedProjects.insert(id)
        }
        // Keep the highlight on the project that was clicked (selecting the session moved it).
        sidebarSelection = id
        browsedProjectID = id
    }

    /// Projects waiting for the user first, then ones with a running session; otherwise saved order.
    func activeFirst(_ projects: [Project]) -> [Project] {
        func rank(_ p: Project) -> Int {
            let sessions = deck.sessions(in: p.id)
            if sessions.contains(where: { needsAttention($0.id) }) { return 0 }
            if sessions.contains(where: { terminals.isRunning($0.id) }) { return 1 }
            return 2
        }
        return projects.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    func activeFirst(_ groups: [(group: ProjectGroup, projects: [Project])]) -> [(group: ProjectGroup, projects: [Project])] {
        func rank(_ projects: [Project]) -> Int {
            activeFirst(projects).first.map { p in
                let sessions = deck.sessions(in: p.id)
                if sessions.contains(where: { needsAttention($0.id) }) { return 0 }
                return sessions.contains(where: { terminals.isRunning($0.id) }) ? 1 : 2
            } ?? 2
        }
        return groups.enumerated()
            .sorted { (rank($0.element.projects), $0.offset) < (rank($1.element.projects), $1.offset) }
            .map(\.element)
    }

    /// Adds (or picks existing) folders and puts them in the group.
    func presentAddProject(toGroup groupID: UUID) {
        let chosen = presentAddProject()
        mutate { deck in for p in chosen { deck.updateProject(p.id) { $0.groupID = groupID } } }
    }

    @discardableResult
    func presentAddProject() -> [Project] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose the project folder to run Claude sessions in")
        guard panel.runAsSheet() == .OK else { return [] }
        return panel.urls.map { addProject(path: $0.path) }
    }

    var selectedProjectID: UUID? {
        selectedSessionID.flatMap { deck.session($0)?.projectID }
    }

    func newSessionInSelectedProject() {
        if let projectID = selectedProjectID ?? deck.projects.first?.id {
            newSession(in: projectID)
        } else {
            presentAddProject()
        }
    }

    /// `claude --worktree` needs a git repository (`.git` is a file inside worktrees / submodules).
    func isGitRepository(_ project: Project) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: project.path).appending(path: ".git").path)
    }

    /// Unique default name, skipping worktrees Claude already created in `<repo>/.claude/worktrees`.
    func defaultWorktreeName(for project: Project) -> String {
        let dir = URL(fileURLWithPath: project.path).appending(path: ".claude/worktrees").path
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return deck.nextWorktreeName(for: project, existing: Set(existing))
    }

    /// A Claude session in its own git worktree (`claude --worktree <name>`), so parallel sessions
    /// in one project don't edit the same files.
    @discardableResult
    func newWorktreeSession(in projectID: UUID, worktreeName: String) -> UUID? {
        guard DeckData.isValidWorktreeName(worktreeName) else { return nil }
        var created: DeckSession?
        mutate { created = $0.addWorktreeSession(to: projectID, worktreeName: worktreeName) }
        guard let session = created else { return nil }
        launch(session.id, resume: false)
        selectedSessionID = session.id
        return session.id
    }

    /// Asks for a worktree name (prefilled with a unique default) and starts the session.
    func promptWorktreeSession(in project: Project) {
        var initial = defaultWorktreeName(for: project)
        while let name = TextPrompt.ask(title: String(localized: "New Worktree Session — Worktree Name"), placeholder: String(localized: "name (A-Z a-z 0-9 . _ -)"), initial: initial) {
            if DeckData.isValidWorktreeName(name) {
                newWorktreeSession(in: project.id, worktreeName: name)
                return
            }
            NSSound.beep()
            initial = name
        }
    }

    /// Types dropped files into a terminal: `@relative/path` for Claude, a quoted path for shells.
    func insertPaths(_ urls: [URL], into id: UUID) {
        guard let session = deck.session(id), terminals.isRunning(id), !urls.isEmpty else { return }
        let text: String
        let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
        if session.kind == .claude {
            let root = URL(fileURLWithPath: session.workingDirectory ?? deck.project(session.projectID)?.path ?? "/")
            // Images as full paths: Claude attaches dropped image paths as images.
            text = urls.map {
                images.contains($0.pathExtension.lowercased())
                    ? ShellEnvironment.escapedPath($0.path)
                    : "@" + FileListing.relativePath(of: $0, in: root)
            }.joined(separator: " ")
        } else {
            text = urls.map { ShellEnvironment.escapedPath($0.path) }.joined(separator: " ")
        }
        terminals.type(text + " ", into: id)
        selectedSessionID = id
    }

    /// Brings the main window forward and selects a session (notification / menu bar click).
    func reveal(_ id: UUID) {
        selectedSessionID = id
        markSeen(id)
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "ClaudeDeck" || $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

extension NSAlert {
    /// Shows the alert as a sheet on the app's window (not a free-floating panel in the middle of
    /// the screen) while keeping the synchronous call style.
    @MainActor @discardableResult
    func runAsSheet() -> NSApplication.ModalResponse {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            return runModal()
        }
        beginSheetModal(for: window) { NSApp.stopModal(withCode: $0) }
        return NSApp.runModal(for: self.window)
    }
}

extension NSOpenPanel {
    /// Folder picker as a sheet on the app's window.
    @MainActor
    func runAsSheet() -> NSApplication.ModalResponse {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return runModal() }
        beginSheetModal(for: window) { NSApp.stopModal(withCode: $0) }
        return NSApp.runModal(for: self)
    }
}

extension AppTheme {
    /// SwiftUI's own color scheme, set alongside NSApp.appearance so SwiftUI-drawn text
    /// (e.g. the glass sidebar) always matches the chosen theme. nil = follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
