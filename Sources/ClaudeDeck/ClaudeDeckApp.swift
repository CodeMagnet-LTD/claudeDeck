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
        } label: {
            MenuBarLabel()
                .environment(delegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(delegate.model)
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

    /// Dock icon click with the main window closed: bring it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.openMainWindow?() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let id = model.selectedSessionID { model.markSeen(id) }
    }
}
