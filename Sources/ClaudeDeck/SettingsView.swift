import ClaudeDeckCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var installed = false

    var body: some View {
        Form {
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

    private func setting<T>(_ keyPath: WritableKeyPath<DeckSettings, T>) -> Binding<T> {
        Binding(
            get: { model.deck.settings[keyPath: keyPath] },
            set: { value in model.mutate { $0.settings[keyPath: keyPath] = value } }
        )
    }
}
