import AppKit
import ClaudeDeckCore
import SwiftUI

@main
struct ClaudeDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("ClaudeDeck", id: "main") {
            ContentView()
                .environment(delegate.model)
                .preferredColorScheme(delegate.model.deck.settings.theme.colorScheme)
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Project…") { delegate.model.presentAddProject() }
                    .keyboardShortcut("o")
                Button("New Claude Session") { delegate.model.newSessionInSelectedProject() }
                    .keyboardShortcut("t")
                Button("New Terminal") { delegate.model.newShellInSelectedProject() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                OpenAutomationsButton(model: delegate.model) // Automations tab
                OpenHistorySearchButton(model: delegate.model) // Search and Skills tabs
            }
            CommandGroup(after: .newItem) {
                Divider()
                RestartCommands(model: delegate.model)
            }
            ExplorerCommands(model: delegate.model)
            UpdateCommands(updater: AppUpdater.shared)
            TabCommands(model: delegate.model)
            // No help book: frees ⌘? (on Turkish keyboards the "+" key area produces it) for zoom.
            CommandGroup(replacing: .help) {}
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { delegate.model.zoomTerminals(by: 1) }
                    .keyboardShortcut("+")
                Button("Zoom Out") { delegate.model.zoomTerminals(by: -1) }
                    .keyboardShortcut("-")
                Button("Actual Size") { delegate.model.zoomTerminals(by: nil) }
                    .keyboardShortcut("0")
                Divider()
                Picker("Theme", selection: Binding(
                    get: { delegate.model.deck.settings.theme },
                    set: { delegate.model.setTheme($0) }
                )) {
                    ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Divider()
            }
        }

        // Built-in editor: one window per file (tabbed together); reopening a file focuses its window.
        WindowGroup("Editor", id: "editor", for: URL.self) { $url in
            EditorWindowView(url: url)
                .environment(delegate.model)
                .preferredColorScheme(delegate.model.deck.settings.theme.colorScheme)
        }
        .defaultSize(width: 900, height: 700)
        .commands { EditorCommands() }

        MenuBarExtra {
            MenuBarContent()
                .environment(delegate.model)
                .preferredColorScheme(delegate.model.deck.settings.theme.colorScheme)
        } label: {
            MenuBarLabel()
                .environment(delegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(delegate.model)
                .preferredColorScheme(delegate.model.deck.settings.theme.colorScheme)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var attention: AttentionCenter?
    private lazy var widget = WidgetBridge(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        attention = AttentionCenter(model: model)
        widget.attach()
        model.applyTheme()
        observeWindowsAndPower()
        installZoomKeys()
        model.start()
        // Demo mode polls only with tools/demo.sh's stand-in gh (fixture PRs and issues).
        if !AppModel.isDemo || ProcessInfo.processInfo.environment["CLAUDEDECK_GH_PATH"] != nil {
            GitHubMonitor.shared.start(model: model)
        }
        DebugSnapshot.startIfRequested(model: model)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.prepareForQuit()
        widget.publishQuit()
    }

    /// `claudedeck://session/<uuid>` from the desktop widget.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { WidgetBridge.handle(url, model: model) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Terminal zoom keys

    private var zoomMonitor: Any?

    /// Zoom shortcuts by character, whatever the keyboard layout: ⌘+ ⌘= ⌘* ⌘? and keypad + zoom in,
    /// ⌘- and keypad - zoom out, ⌘0 resets.
    private func installZoomKeys() {
        zoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            guard mods == .command else { return event }
            let keys = [event.charactersIgnoringModifiers ?? "", event.characters ?? ""]
            let step: Double??
            if keys.contains(where: { ["+", "=", "*", "?"].contains($0) }) || event.keyCode == 69 {
                step = .some(1)
            } else if keys.contains("-") || event.keyCode == 78 {
                step = .some(-1)
            } else if keys.contains("0") {
                step = .some(nil)
            } else {
                return event
            }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let step else { return false }
                let editorTab = NSApp.keyWindow != nil && NSApp.keyWindow === self.model.tabs.mainWindow && self.model.tabs.selected.fileURL != nil
                if editorTab || EditorRegistry.isEditorWindow(NSApp.keyWindow) { EditorRegistry.zoom(by: step, model: self.model); return true }
                self.model.zoomTerminals(by: step)
                return true
            }
            return handled ? nil : event
        }
    }

    // MARK: Quit confirmation / background mode

    /// Set when macOS is logging out / shutting down: never block that with a question.
    private var systemIsPoweringOff = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard systemIsPoweringOff || EditorRegistry.confirmQuit() else { return .terminateCancel }
        let running = model.deck.sessions.filter { model.terminals.isRunning($0.id) }
        guard model.deck.settings.confirmQuit, !systemIsPoweringOff, !running.isEmpty else { return .terminateNow }
        let working = running.filter { model.status(of: $0.id).display.isRunning || model.status(of: $0.id).display.isBlocked }.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit ClaudeDeck?")
        var detail = String(localized: "Open terminals: \(running.count)")
        if working > 0 { detail += String(localized: ", Claude sessions working right now: \(working)") }
        detail += String(localized: ". Quitting closes them all (Claude sessions resume where they left off next launch). Keep running in the background to close the window while everything keeps working.")
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "Keep Running in Background"))
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[1].hasDestructiveAction = true
        switch alert.runAsSheet() {
        case .alertFirstButtonReturn:
            sendToBackground()
            return .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// Closes the window; terminals keep running (menu bar item stays).
    func sendToBackground() {
        // Editor windows with unsaved changes stay open (close() would skip the save question).
        for window in NSApp.windows where window.isVisible && window.canBecomeMain && !window.isDocumentEdited { window.close() }
        updateDockVisibility()
    }

    /// Menu-bar-only while no main window is visible (if enabled); back in the Dock when shown.
    func updateDockVisibility() {
        let windowVisible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        let wanted: NSApplication.ActivationPolicy =
            model.deck.settings.hideDockWhenClosed && !windowVisible ? .accessory : .regular
        if NSApp.activationPolicy() != wanted {
            NSApp.setActivationPolicy(wanted)
            if wanted == .regular { NSApp.activate() }
        }
    }

    private func observeWindowsAndPower() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            // The closing window is still "visible" during willClose; check on the next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateDockVisibility() } }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDockVisibility() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemIsPoweringOff = true }
        }
    }

    /// Dock icon click with the main window closed: bring it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.openMainWindow?() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let id = model.selectedSessionID { model.markSeen(id) }
    }
}
