import ClaudeDeckCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var installed = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("General") {
                Picker("Theme", selection: Binding(
                    get: { model.deck.settings.theme },
                    set: { model.setTheme($0) }
                )) {
                    ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Ask before quitting (⌘Q while terminals are open)", isOn: setting(\.confirmQuit))
                Toggle("Hide from the Dock when the window is closed (menu bar only)", isOn: setting(\.hideDockWhenClosed))
                Text("Closing the window (X) doesn't stop any session; the app keeps running in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Launch ClaudeDeck at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if SMAppService.mainApp.status == .requiresApproval {
                    Text("Waiting for approval in System Settings › General › Login Items.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !Bundle.main.bundlePath.hasPrefix("/Applications") {
                    Text("The app is running outside /Applications (\(Bundle.main.bundlePath)). Move it to /Applications for a lasting login item.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Sessions") {
                Toggle("Resume open sessions at launch", isOn: setting(\.resumeOnLaunch))
                Toggle("Run /compact on large resumed sessions", isOn: setting(\.compactOnResume))
                Stepper(value: setting(\.compactThresholdTokens), in: 50_000...1_000_000, step: 25_000) {
                    Text("Compact threshold: context above \(model.deck.settings.compactThresholdTokens / 1000)K tokens")
                }
                .disabled(!model.deck.settings.compactOnResume)
                Toggle("Send a “continue” message to resumed sessions", isOn: setting(\.continueAfterResume))
                Group {
                    Toggle("Only sessions that were working when the app quit", isOn: setting(\.continueOnlyIfBusy))
                    TextField("Message", text: setting(\.continueMessage), prompt: Text("Continue where you left off."))
                }
                .disabled(!model.deck.settings.continueAfterResume)
            }
            Section("Editor") {
                Toggle("Open text files in the built-in editor (double-click in the Files panel)", isOn: setting(\.openFilesInBuiltInEditor))
                Stepper(value: setting(\.editorFontSize), in: DeckSettings.fontSizeRange, step: 1) {
                    Text("Font size: \(Int(model.deck.settings.editorFontSize)) pt")
                }
                Toggle("Wrap Lines", isOn: setting(\.editorWrapLines))
            }
            Section("Alerts") {
                Toggle("Show notifications (permission / question / done)", isOn: setting(\.notifications))
                Toggle("Bounce the Dock icon", isOn: setting(\.bounceDock))
            }
            Section("iCloud") {
                Toggle("Sync projects and groups with iCloud Drive", isOn: Binding(
                    get: { model.deck.settings.iCloudSync },
                    set: { on in
                        model.mutate { $0.settings.iCloudSync = on }
                        model.sync.refresh()
                    }
                ))
                .disabled(!DeckSyncController.isAvailable && !model.deck.settings.iCloudSync)
                if DeckSyncController.isAvailable {
                    Text("The project list and groups (name, color, pinning, group membership) are merged with your other Macs through iCloud Drive › ClaudeDeck › projects.json. Sessions, panes, selection and settings are not synced. Deletions don't propagate to other Macs.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("iCloud Drive is off on this Mac (~/Library/Mobile Documents/com~apple~CloudDocs is missing). Turn it on in System Settings › Apple Account › iCloud › iCloud Drive.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.deck.settings.iCloudSync {
                    if let error = model.sync.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    } else if let at = model.sync.lastSyncAt {
                        Text("Last sync: \(at.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            PencilSettingsSection()
            Section("Claude Code Hooks") {
                LabeledContent("Status") {
                    (installed ? Text("Installed") : Text("Not Installed"))
                        .foregroundStyle(installed ? .green : .red)
                }
                Text("ClaudeDeck adds only its own status hook to ~/.claude/settings.json; it leaves other hooks alone and makes a backup before every change. The hook only runs in ClaudeDeck terminals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reinstall") { model.installHooks(); installed = model.hooksInstalled }
                    Button("Uninstall", role: .destructive) { model.uninstallHooks(); installed = model.hooksInstalled }
                }
                if let path = model.claudePath {
                    LabeledContent("claude", value: path).font(.caption)
                } else {
                    Text("`claude` was not found in your login shell.").foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { installed = model.hooksInstalled }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setting<T>(_ keyPath: WritableKeyPath<DeckSettings, T>) -> Binding<T> {
        Binding(
            get: { model.deck.settings[keyPath: keyPath] },
            set: { value in model.mutate { $0.settings[keyPath: keyPath] = value } }
        )
    }
}
