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
                Stepper(value: setting(\.compactThresholdTokens), in: 50_000...1_000_000, step: 25_000) {
                    Text("Compact eşiği: context \(model.deck.settings.compactThresholdTokens / 1000) bin token üstü")
                }
                .disabled(!model.deck.settings.compactOnResume)
            }
            Section("Uyarılar") {
                Toggle("Bildirim göster (izin / soru / bitti)", isOn: setting(\.notifications))
                Toggle("Dock ikonunu zıplat", isOn: setting(\.bounceDock))
            }
            Section("iCloud") {
                Toggle("Projeleri ve grupları iCloud Drive ile eşitle", isOn: Binding(
                    get: { model.deck.settings.iCloudSync },
                    set: { on in
                        model.mutate { $0.settings.iCloudSync = on }
                        model.sync.refresh()
                    }
                ))
                .disabled(!DeckSyncController.isAvailable && !model.deck.settings.iCloudSync)
                if DeckSyncController.isAvailable {
                    Text("Proje listesi ve gruplar (ad, renk, sabitleme, grup ataması) iCloud Drive › ClaudeDeck › projects.json üzerinden diğer Mac'lerinle birleştirilir. Oturumlar, bölmeler, seçim ve ayarlar eşitlenmez. Silme işlemleri diğer Mac'lere yansımaz.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("iCloud Drive bu Mac'te açık değil (~/Library/Mobile Documents/com~apple~CloudDocs yok). Sistem Ayarları › Apple Hesabı › iCloud › iCloud Drive'ı aç.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.deck.settings.iCloudSync {
                    if let error = model.sync.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    } else if let at = model.sync.lastSyncAt {
                        Text("Son eşitleme: \(at.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
