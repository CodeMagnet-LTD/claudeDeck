import AppKit
import ClaudeDeckCore

extension AppModel {
    func presentAddProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ekle"
        panel.message = "Claude oturumu açılacak proje klasörünü seç"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addProject(path: url.path) }
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

    /// Types dropped files into a terminal: `@relative/path` for Claude, a quoted path for shells.
    func insertPaths(_ urls: [URL], into id: UUID) {
        guard let session = deck.session(id), terminals.isRunning(id), !urls.isEmpty else { return }
        let text: String
        if session.kind == .claude {
            let root = URL(fileURLWithPath: deck.project(session.projectID)?.path ?? "/")
            text = urls.map { "@" + FileListing.relativePath(of: $0, in: root) }.joined(separator: " ")
        } else {
            text = urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
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
