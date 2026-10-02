import AppKit
import ClaudeDeckCore
import Observation
import SwiftUI

/// The main window's tabs (Sessions, files, diffs, Automations) and the editor documents of the
/// open file tabs. UI state: persisted in UserDefaults, not in deck.json (no sync, no widget).
@MainActor
@Observable
final class WorkspaceTabs {
    private(set) var list: WorkspaceTabList
    /// One document per open file tab. The text lives in its (kept alive) text view.
    private(set) var documents: [URL: EditorDocument] = [:]
    /// The main window, set by `MainWindowGlue`.
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private var keyMonitor: Any?

    /// Demo mode runs under the real bundle id: keep its tabs apart from the user's.
    private static let defaultsKey = AppModel.isDemo ? "workspaceTabs.demo" : "workspaceTabs"

    init() {
        let saved = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(WorkspaceTabList.self, from: $0) } ?? WorkspaceTabList()
        list = saved.restored { FileManager.default.fileExists(atPath: $0.path) }
        syncDocuments()
    }

    var tabs: [WorkspaceTab] { list.tabs }
    var selected: WorkspaceTab { list.selected }
    var isSessionsSelected: Bool { list.isSessionsSelected }

    func document(for url: URL) -> EditorDocument? { documents[url] }

    // MARK: Opening & selecting

    func open(_ tab: WorkspaceTab, preview: Bool = false) {
        list.open(tab, preview: preview)
        changed()
    }

    func openFile(_ url: URL, preview: Bool) {
        open(.file(url.standardizedFileURL), preview: preview)
    }

    func select(_ tab: WorkspaceTab) {
        guard list.selected != tab else { return }
        list.select(tab)
        changed()
    }

    func selectSessions() { select(.sessions) }

    func select(commandNumber: Int) {
        if let tab = list.tab(forCommandNumber: commandNumber) { select(tab) }
    }

    func selectNeighbour(forward: Bool) {
        list.selectNeighbour(forward: forward)
        changed()
    }

    func pin(_ tab: WorkspaceTab) {
        guard list.preview == tab else { return }
        list.pin(tab)
        changed()
    }

    func move(_ tab: WorkspaceTab, to target: WorkspaceTab) {
        list.move(tab, to: target)
        changed()
    }

    // MARK: Closing

    /// Closes tabs, asking about unsaved editor changes first. False if the user cancelled.
    @discardableResult
    func close(_ tabs: [WorkspaceTab]) -> Bool {
        let dirty = tabs.compactMap { $0.fileURL.flatMap { documents[$0] } }.filter(\.isDirty)
        if !dirty.isEmpty {
            guard dirty.count == 1 ? confirmClosing(dirty[0]) : EditorRegistry.confirmSaving(dirty) else { return false }
            dirty.forEach { $0.discardForClose() }
        }
        for tab in tabs { list.close(tab) }
        changed()
        return true
    }

    @discardableResult
    func close(_ tab: WorkspaceTab) -> Bool { close([tab]) }

    /// Save / Don't Save / Cancel for one file tab.
    private func confirmClosing(_ document: EditorDocument) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Save changes to “\(document.url.lastPathComponent)”?")
        alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Don’t Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[1].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return document.saveNow()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    /// "Open in Separate Window": saves first so the new window (which reads the disk) has the edits.
    func moveToWindow(_ url: URL, openWindow: OpenWindowAction) {
        if let document = documents[url], document.isDirty, !document.saveNow() { return }
        close(.file(url))
        EditorOpener.openInWindow(url, openWindow: openWindow)
    }

    // MARK: Main window

    var dirtyDocuments: [EditorDocument] { documents.values.filter(\.isDirty) }

    /// The main window is about to close: its text views go away with it. False = keep it open.
    func confirmCloseWindow() -> Bool {
        EditorRegistry.confirmSaving(dirtyDocuments)
    }

    /// The main window closed: fresh documents (read from disk again) for when it comes back.
    func windowDidClose() {
        for (url, document) in documents {
            document.discardForClose()
            documents[url] = EditorDocument(url: url)
        }
    }

    // MARK: Keys

    /// ⌘W closes the selected tab (other than Sessions) instead of the window; ⌘2…⌘9 select tabs.
    /// A key monitor, not menu items: the system Close owns ⌘W in the File menu, and nine
    /// "Show Tab n" items would crowd the Window menu. Only while the main window is key.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods == .command else { return event }
            let number = Self.digitKeyCodes.firstIndex(of: event.keyCode).map { $0 + 1 }
                ?? event.charactersIgnoringModifiers.flatMap(Int.init).flatMap { (1...9).contains($0) ? $0 : nil }
            let isClose = event.charactersIgnoringModifiers?.lowercased() == "w"
            guard number != nil || isClose else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.mainWindow, event.window === window, window.attachedSheet == nil else { return false }
                if let number {
                    self.select(commandNumber: number)
                    return true
                }
                guard !self.isSessionsSelected else { return false }
                self.close(self.selected)
                return true
            }
            return handled ? nil : event
        }
    }

    /// Key codes of the 1…9 keys on the main keyboard (layout independent).
    private static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    // MARK: Private

    private func changed() {
        syncDocuments()
        save()
    }

    /// A document for every file tab; closed tabs' documents stop watching and go away.
    private func syncDocuments() {
        let urls = Set(list.tabs.compactMap(\.fileURL))
        for (url, document) in documents where !urls.contains(url) {
            document.close()
            documents[url] = nil
        }
        for url in urls where documents[url] == nil { documents[url] = EditorDocument(url: url) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(list.persistable) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

extension AppModel {
    /// Brings the main window forward (opening it if it was closed).
    func showMainWindow() {
        if let window = tabs.mainWindow, window.isVisible {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
            NSApp.activate()
        }
    }

    /// A file in a main-window editor tab.
    func showFileTab(_ url: URL, preview: Bool) {
        tabs.openFile(url, preview: preview)
        showMainWindow()
    }

    /// The Automations tab ("Automations…" menu item, sidebar, menu bar).
    func showAutomations() {
        tabs.open(.automations)
        showMainWindow()
    }

    /// The Inbox tab (GitHub issues and pull requests).
    func showInbox() {
        tabs.open(.inbox)
        showMainWindow()
    }
}

extension UserDefaults {
    /// Window UI state (`@AppStorage`: inspector, sidebar sections). Demo mode runs under the real
    /// bundle id: it keeps its own copy so it never flips the user's panels.
    /// UserDefaults is thread-safe (documented), just not marked Sendable.
    nonisolated(unsafe) static let windowState: UserDefaults = ProcessInfo.processInfo.environment["CLAUDEDECK_DEMO"] == nil
        ? .standard : UserDefaults(suiteName: "ClaudeDeck.demo") ?? .standard
}
