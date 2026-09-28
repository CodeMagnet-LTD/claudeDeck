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
            Section("Genel") {
                Toggle("Bilgisayar açılınca ClaudeDeck'i başlat", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if SMAppService.mainApp.status == .requiresApproval {
                    Text("Sistem Ayarları › Genel › Giriş Öğeleri'nden onay bekliyor.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !Bundle.main.bundlePath.hasPrefix("/Applications") {
                    Text("Uygulama /Applications dışında çalışıyor (\(Bundle.main.bundlePath)). Kalıcı giriş öğesi için `./build.sh install` ile /Applications'a kur.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Oturumlar") {
                Toggle("Açılışta açık oturumları otomatik devam ettir", isOn: setting(\.resumeOnLaunch))
                Toggle("Devam ettirilen büyük oturumlarda /compact çalıştır", isOn: setting(\.compactOnResume))
                Stepper(value: setting(\.compactThresholdKB), in: 100...20_000, step: 100) {
                    Text("Compact eşiği: \(model.deck.settings.compactThresholdKB) KB transcript")
                }
                .disabled(!model.deck.settings.compactOnResume)
            }
            Section("Uyarılar") {
                Toggle("Bildirim göster (izin / soru / bitti)", isOn: setting(\.notifications))
                Toggle("Dock ikonunu zıplat", isOn: setting(\.bounceDock))
            }
            Section("Claude Code hook'ları") {
                LabeledContent("Durum") {
                    Text(installed ? "Kurulu" : "Kurulu değil")
                        .foregroundStyle(installed ? .green : .red)
                }
                Text("ClaudeDeck, ~/.claude/settings.json dosyasına yalnızca kendi durum hook'unu ekler; diğer hook'lara dokunmaz ve her değişiklikten önce yedek alır. Hook yalnızca ClaudeDeck terminallerinde çalışır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Yeniden kur") { model.installHooks(); installed = model.hooksInstalled }
                    Button("Kaldır", role: .destructive) { model.uninstallHooks(); installed = model.hooksInstalled }
                }
                if let path = model.claudePath {
                    LabeledContent("claude", value: path).font(.caption)
                } else {
                    Text("`claude` login shell'de bulunamadı.").foregroundStyle(.red)
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
