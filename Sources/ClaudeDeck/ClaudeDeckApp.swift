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
                Button("Proje Ekle…") { delegate.model.presentAddProject() }
                    .keyboardShortcut("o")
                Button("Yeni Claude Oturumu") { delegate.model.newSessionInSelectedProject() }
                    .keyboardShortcut("t")
                Button("Yeni Terminal") { delegate.model.newShellInSelectedProject() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
            }
            CommandGroup(after: .toolbar) {
                Button("Terminali Büyüt") { delegate.model.zoomTerminals(by: 1) }
                    .keyboardShortcut("+")
                Button("Terminali Küçült") { delegate.model.zoomTerminals(by: -1) }
                    .keyboardShortcut("-")
                Button("Gerçek Boyut") { delegate.model.zoomTerminals(by: nil) }
                    .keyboardShortcut("0")
                Divider()
                Picker("Tema", selection: Binding(
                    get: { delegate.model.deck.settings.theme },
                    set: { delegate.model.setTheme($0) }
                )) {
                    ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Divider()
            }
        }

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
        model.start()
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

    // MARK: Quit confirmation / background mode

    /// Set when macOS is logging out / shutting down: never block that with a question.
    private var systemIsPoweringOff = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = model.deck.sessions.filter { model.terminals.isRunning($0.id) }
        guard model.deck.settings.confirmQuit, !systemIsPoweringOff, !running.isEmpty else { return .terminateNow }
        let working = running.filter { model.status(of: $0.id).display.isRunning || model.status(of: $0.id).display.isBlocked }.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ClaudeDeck'ten çıkılsın mı?"
        var detail = "\(running.count) terminal açık"
        if working > 0 { detail += ", \(working) Claude oturumu şu an çalışıyor" }
        detail += ". Çıkarsan hepsi kapanır (Claude oturumları sonraki açılışta kaldığı yerden devam eder). Arka planda bırakırsan pencere kapanır, her şey çalışmaya devam eder."
        alert.informativeText = detail
        alert.addButton(withTitle: "Arka planda çalışsın")
        alert.addButton(withTitle: "Çık")
        alert.addButton(withTitle: "Vazgeç")
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
        for window in NSApp.windows where window.isVisible && window.canBecomeMain { window.close() }
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
