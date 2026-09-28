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
