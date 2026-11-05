import AppKit
import ClaudeDeckCore
import SwiftUI

/// Settings › Kod Checker. The webhook secret and the API token stay in the Keychain.
struct KodBridgeSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var authorization = ""
    @State private var confirmRegenerate = false

    var body: some View {
        let bridge = model.kodBridge
        Section("Kod Checker") {
            Toggle("Enable the kod checker bridge", isOn: Binding(
                get: { model.deck.settings.kodBridgeEnabled },
                set: { on in
                    model.mutate { $0.settings.kodBridgeEnabled = on }
                    model.kodBridge.apply()
                }
            ))
            Text("When a Claude session finishes a turn, or is waiting on a permission or a question, ClaudeDeck POSTs an event to the webhook. kod checker talks only to ClaudeDeck, and the exchange shows up here and in the session. Off until you turn this on.")
                .font(.caption).foregroundStyle(.secondary)
            if model.deck.settings.kodBridgeEnabled {
                TextField("Webhook URL", text: Binding(
                    get: { model.deck.settings.kodWebhookURL },
                    set: { value in model.mutate { $0.settings.kodWebhookURL = value } }
                ), prompt: Text("https://example.com/hooks/kod"))
                .textFieldStyle(.roundedBorder)
                if !model.deck.settings.kodWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   KodBridge.webhookURL(model.deck.settings.kodWebhookURL) == nil {
                    Text("The webhook URL needs to start with http:// or https://.")
                        .font(.caption).foregroundStyle(.red)
                } else if model.deck.settings.kodWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Events are sent only when a webhook URL is set. The local API still accepts messages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SecureField("Authorization", text: $authorization, prompt: Text("Bearer …"))
                    .textFieldStyle(.roundedBorder)
                Text("The full Authorization header value, for example “Bearer secret”. It is stored in the Keychain, not in settings.")
                    .font(.caption).foregroundStyle(.secondary)
                if authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No Authorization header is sent until this is set.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Port") {
                    Stepper(value: Binding(
                        get: { model.deck.settings.kodBridgePort },
                        set: { value in
                            model.mutate { $0.settings.kodBridgePort = value }
                            model.kodBridge.apply()
                        }
                    ), in: 1024...65535) {
                        Text(verbatim: String(model.deck.settings.kodBridgePort))
                            .monospacedDigit()
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                }
                if let error = bridge.listenError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if bridge.listening {
                    Text("Listening at \(listeningAddress)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The local API is stopped.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("API token") {
                    if bridge.token.isEmpty {
                        Text("A token is created when you turn the bridge on.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(bridge.token)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                }
                HStack {
                    Button("Copy") { copy(bridge.token) }
                        .disabled(bridge.token.isEmpty)
                    Button("Regenerate…") { confirmRegenerate = true }
                        .disabled(bridge.token.isEmpty)
                    Spacer()
                    Button("Send Test Event") { bridge.sendTest() }
                    Button("Activity Log…") { bridge.showLog = true }
                }
                if let note = bridge.lastDeliveryNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { authorization = KodBridgeKeychain.authorization() ?? "" }
        .onChange(of: authorization) { _, new in KodBridgeKeychain.setAuthorization(new) }
        .confirmationDialog("Regenerate the API token?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) { model.kodBridge.regenerateToken() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("kod checker will need the new token. The old one stops working immediately.")
        }
    }

    private var listeningAddress: String { "127.0.0.1:\(model.kodBridge.boundPort)" }

    private func copy(_ token: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }
}

struct KodCheckerBadge: View {
    var body: some View {
        Text(ChatEntry.kodCheckerSource)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .help("This session has a message from kod checker")
    }
}

/// Recent messages kod checker typed into this session, above the terminal.
struct KodCheckerStrip: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID

    var body: some View {
        let notes = model.kodBridge.notes(for: sessionID)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    KodCheckerBadge()
                    Spacer(minLength: 4)
                    Button("Activity Log") { model.kodBridge.showLog = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                ForEach(notes) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(note.text).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(note.at.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
        }
    }
}

struct KodActivityLogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Kod Checker Activity").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            if model.kodBridge.log.isEmpty {
                Spacer()
                Text("Nothing yet. Finished turns and messages from kod checker show up here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            } else {
                List(Array(model.kodBridge.log.reversed())) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.direction == .outbound ? "Outbound" : "Inbound")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(entry.ok ? Color.secondary : Color.red)
                            Text(entry.title).font(.callout).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(entry.at.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 560, height: 420)
    }
}
