import AppKit
import ClaudeDeckCore
import CoreImage.CIFilterBuiltins
import SwiftUI
import UserNotifications

// MARK: Settings

/// Settings › Remote: host this Mac's sessions, or show another Mac's.
struct RemoteSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var showCode = false
    @State private var pasted = ""
    @State private var pasteFailed = false
    @State private var password = ""
    @State private var editingPassword = false
    @State private var showOtherWays = false

    var body: some View {
        let remote = model.remote
        Section("Remote (Tailscale)") {
            Toggle("Let my other Macs see and answer this Mac's sessions", isOn: Binding(
                get: { model.deck.settings.remoteHost },
                set: { on in
                    model.mutate { $0.settings.remoteHost = on }
                    remote.refresh()
                }
            ))
            Toggle("Show another Mac's sessions in the sidebar", isOn: Binding(
                get: { model.deck.settings.remoteClient },
                set: { on in
                    model.mutate { $0.settings.remoteClient = on }
                    remote.refresh()
                }
            ))
            if model.deck.settings.remoteHost || model.deck.settings.remoteClient {
                passwordRow(remote)
                if model.deck.settings.remoteHost { hostStatus(remote) }
                if model.deck.settings.remoteClient { clientStatus(remote) }
                RemoteRequirementsView()
                DisclosureGroup("Other ways to pair (QR code, link, iCloud Drive)", isExpanded: $showOtherWays) {
                    otherWays(remote)
                }
            }
            Text("Both Macs need Tailscale, signed in to the same account. The connection stays inside your tailnet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func passwordRow(_ remote: RemoteController) -> some View {
        if remote.hasPassword, !editingPassword {
            LabeledContent("Password") {
                HStack {
                    Label("Set", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Change…") { editingPassword = true }
                    Button("Remove", role: .destructive) { remote.removePassword() }
                }
            }
        } else {
            HStack {
                SecureField("Password — the same on both Macs", text: $password)
                    .onSubmit(savePassword)
                Button("Save", action: savePassword)
                    .disabled(password.count < RemoteHandshake.minimumPasswordLength)
                if editingPassword {
                    Button("Cancel") { editingPassword = false; password = "" }
                }
            }
            Text("At least \(RemoteHandshake.minimumPasswordLength) characters. Type the same password on both Macs: the other Mac is then found through Tailscale, without iCloud Drive.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func savePassword() {
        guard password.count >= RemoteHandshake.minimumPasswordLength else { return }
        model.remote.setPassword(password)
        password = ""
        editingPassword = false
    }

    @ViewBuilder
    private func hostStatus(_ remote: RemoteController) -> some View {
        LabeledContent("Status") {
            switch remote.hostState {
            case .listening(let port):
                Text(remote.connectedRemotes.isEmpty
                     ? String(localized: "Waiting on port \(String(port))")
                     : String(localized: "Connected: \(remote.connectedRemotes.joined(separator: ", "))"))
                    .foregroundStyle(remote.connectedRemotes.isEmpty ? Color.secondary : Color.green)
            case .failed(let error): Text(error).foregroundStyle(.red)
            case .stopped: Text("Starting…").foregroundStyle(.secondary)
            }
        }
        if let first = remote.hostAddresses.first {
            LabeledContent("Address", value: first).textSelection(.enabled)
        }
        if let error = remote.hostError {
            Text(error).font(.caption).foregroundStyle(.orange)
        }
    }

    /// QR code / link / iCloud Drive pairing, for Macs without a password set.
    @ViewBuilder
    private func otherWays(_ remote: RemoteController) -> some View {
        if model.deck.settings.remoteHost {
            HStack {
                Button(showCode ? "Hide Pairing Code" : "Show Pairing Code") { showCode.toggle() }
                    .disabled(remote.hostPairing == nil)
                Button("Refresh Address") { remote.refreshAddresses() }
                Spacer()
                if !remote.local.hostUsesPassword {
                    Button("New Key…", role: .destructive) {
                        if Confirm.ask(
                            String(localized: "Create a new pairing key?"),
                            detail: String(localized: "Connected Macs are disconnected. Macs using iCloud Drive pick up the new key on their own; others have to pair again."),
                            action: String(localized: "New Key")
                        ) { remote.regenerateHostKey() }
                    }
                }
            }
            if showCode, let link = try? remote.hostPairing?.link() {
                PairingCodeView(link: link)
            }
        }
        if model.deck.settings.remoteClient {
            HStack {
                TextField("Paste a pairing link (claudedeck://pair?…)", text: $pasted)
                    .onSubmit(pair)
                Button("Pair", action: pair).disabled(pasted.isEmpty)
            }
            if pasteFailed {
                Text("That isn't a ClaudeDeck pairing link. Copy it from Settings › Remote on the other Mac.")
                    .font(.caption).foregroundStyle(.red)
            }
            if remote.local.manualPairing != nil {
                Button("Forget Pasted Pairing") { remote.forgetPairing() }
            }
        }
        Text(RemoteController.pairingFolder == nil
             ? String(localized: "iCloud Drive is off on this Mac, so nothing is shared through it.")
             : String(localized: "With iCloud Drive on, the hosting Mac also leaves its pairing in iCloud Drive › ClaudeDeck › Remote and the other Mac picks it up."))
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func clientStatus(_ remote: RemoteController) -> some View {
        LabeledContent("Connection") { RemoteConnectionLabel() }
        if remote.availableHosts.count > 1, remote.local.manualPairing == nil {
            Picker("Mac", selection: Binding(
                get: { remote.pairing?.id },
                set: { if let id = $0 { remote.choose(host: id) } }
            )) {
                ForEach(remote.availableHosts) { Text($0.hostName).tag(Optional($0.id)) }
            }
        } else if let pairing = remote.pairing {
            LabeledContent("Mac", value: pairing.hostName)
        }
    }

    private func pair() {
        pasteFailed = !model.remote.pair(link: pasted)
        if !pasteFailed { pasted = "" }
    }
}

/// QR code and copyable link for pairing without iCloud Drive.
struct PairingCodeView: View {
    let link: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let image = Self.qrImage(link) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 140, height: 140)
                    .padding(6)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("On the other Mac: Settings › Remote › paste this link. Or scan the code with a phone and send the link over.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(copied ? "Copied" : "Copy Pairing Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    copied = true
                }
                Text("The link contains the key: share it only with your own Macs.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// "Connected", "Connecting…", "Retrying in 8 s — reason"…
struct RemoteConnectionLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let remote = model.remote
        switch remote.connection {
        case .off: Text("Off").foregroundStyle(.secondary)
        case .noHost: Text("No Mac found yet — turn on hosting on the other Mac, or paste its link").foregroundStyle(.secondary)
        case .connecting: Text("Connecting…").foregroundStyle(.secondary)
        case .connected: Text("Connected").foregroundStyle(.green)
        case .retrying(let reason, let at):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(at.timeIntervalSince(context.date).rounded()))
                Text("Retrying in \(seconds) s — \(reason)").foregroundStyle(.orange).lineLimit(2)
            }
        case .refused(let reason): Text(reason).foregroundStyle(.red).lineLimit(3)
        }
    }
}

// MARK: Sidebar

/// The paired Mac's sessions, as a sidebar section (shown while remote mode is on).
struct RemoteSidebarSection: View {
    @Environment(AppModel.self) private var model
    let filter: SidebarFilter
    @AppStorage("sidebar.remoteExpanded", store: .windowState) private var expanded = true

    var body: some View {
        let remote = model.remote
        let sessions = (remote.snapshot?.sessions ?? []).filter { session in
            switch filter {
            case .all: true
            case .waiting: session.needsAttention
            case .working: session.state == .running
            }
        }
        Section(isExpanded: $expanded) {
            if remote.connection == .connected {
                ForEach(sessions) { RemoteSessionRow(session: $0).selectionDisabled() }
                if sessions.isEmpty {
                    Text(filter == .all ? "No running sessions" : "Nothing here")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            } else {
                RemoteConnectionLabel().font(.caption)
            }
            if let error = remote.answerError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            HStack(spacing: 4) {
                Image(systemName: "desktopcomputer")
                Text(remote.snapshot?.hostName ?? remote.pairing?.hostName ?? String(localized: "Other Mac"))
                if remote.connection == .connected {
                    Text("\(sessions.count)").foregroundStyle(.tertiary)
                }
                Spacer()
                Circle()
                    .fill(remote.connection == .connected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .help(remote.connection == .connected ? "Connected" : "Not connected")
            }
        }
    }
}

struct RemoteSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: RemoteSession

    var body: some View {
        let display = session.state.display
        HStack(alignment: .top, spacing: 8) {
            StatusDot(display: display, unseen: session.unseen)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if session.state == .shell {
                        Image(systemName: "apple.terminal").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(session.name).lineLimit(1)
                    if !session.project.isEmpty, !session.name.hasPrefix(session.project) {
                        Text(session.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    RowTime(date: session.updatedAt)
                }
                let quiet = display.isIdle && !session.unseen
                if !quiet || session.detail != nil {
                    HStack(spacing: 6) {
                        if !quiet { StatusPill(display: display, unseen: session.unseen) }
                        if let detail = session.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                if let stamp = session.permissionStamp {
                    let busy = model.remote.answering.contains(session.id)
                    HStack(spacing: 6) {
                        Button("Allow") { model.remote.answer(session.id, stamp: stamp, approve: true) }
                            .buttonStyle(.borderedProminent)
                        Button("Deny", role: .destructive) { model.remote.answer(session.id, stamp: stamp, approve: false) }
                            .buttonStyle(.bordered)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .controlSize(.small)
                    .disabled(busy)
                }
            }
        }
        .padding(.vertical, 3)
        .flashOnStateChange(display)
        .contentShape(Rectangle())
        .onTapGesture { model.openRemoteTerminal(session.id) }
        .help("Open the live terminal")
    }
}

// MARK: Requirements

/// What remote mode needs on this Mac, checked by the app (Tailscale, iCloud Drive, notifications,
/// firewall), each with a button that opens the place to fix it. Re-checked while Settings is open.
struct RemoteRequirementsView: View {
    @Environment(AppModel.self) private var model
    @State private var checks: [RemoteCheck] = []

    var body: some View {
        let host = model.deck.settings.remoteHost
        let client = model.deck.settings.remoteClient
        VStack(alignment: .leading, spacing: 6) {
            if checks.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking this Mac…").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(check.ok ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title)
                        if let detail = check.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !check.ok, let fix = check.fix {
                        Button(fix.title) { fix.action() }.controlSize(.small)
                    }
                }
            }
        }
        .task(id: "\(host)\(client)") {
            while !Task.isCancelled {
                checks = await RemoteCheck.run(host: host, client: client, remote: model.remote)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

struct RemoteCheck: Identifiable {
    struct Fix {
        var title: String
        var action: @MainActor () -> Void
    }

    var id: String
    var title: String
    var ok: Bool
    var detail: String?
    var fix: Fix?

    @MainActor
    static func run(host: Bool, client: Bool, remote: RemoteController) async -> [RemoteCheck] {
        let appPath = Bundle.main.bundlePath
        let (tailscale, firewall) = await Task.detached {
            (Tailscale.status(), host ? Firewall.status(appPath: appPath) : nil)
        }.value
        var checks: [RemoteCheck] = []

        // Tailscale
        if !Tailscale.isInstalled {
            checks.append(RemoteCheck(
                id: "tailscale", title: String(localized: "Tailscale is not installed"), ok: false,
                detail: String(localized: "Install it on both Macs and sign in with the same account."),
                fix: Fix(title: String(localized: "Download…")) { open("https://tailscale.com/download/mac") }
            ))
        } else if let tailscale, tailscale.isRunning {
            checks.append(RemoteCheck(id: "tailscale", title: String(localized: "Tailscale is connected"), ok: true, detail: tailscale.dnsName))
        } else {
            checks.append(RemoteCheck(
                id: "tailscale", title: String(localized: "Tailscale is not connected"), ok: false,
                detail: tailscale?.backendState == "NeedsLogin"
                    ? String(localized: "Sign in to Tailscale.")
                    : String(localized: "Open Tailscale and connect (or run `tailscale up`)."),
                fix: openTailscaleFix()
            ))
        }

        // Pairing: a password on both Macs, or iCloud Drive (the link is the last resort).
        if remote.hasPassword {
            checks.append(RemoteCheck(id: "pairing", title: String(localized: "A password is set"), ok: true,
                                      detail: String(localized: "Use the same password on the other Mac.")))
        } else if RemoteController.pairingFolder != nil || AppModel.isDemo {
            checks.append(RemoteCheck(id: "icloud", title: String(localized: "iCloud Drive is on"), ok: true,
                                      detail: String(localized: "The pairing is shared automatically.")))
        } else {
            checks.append(RemoteCheck(
                id: "icloud", title: String(localized: "No password set"), ok: false,
                detail: String(localized: "iCloud Drive is off on this Mac: set a password above, the same on both Macs.")
            ))
        }

        // Notifications (the remote side's alerts; the host's own as well)
        if Bundle.main.bundleIdentifier != nil {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                let quiet = settings.alertSetting == .disabled
                checks.append(RemoteCheck(
                    id: "notifications",
                    title: quiet ? String(localized: "Notification banners are off") : String(localized: "Notifications are allowed"),
                    ok: !quiet,
                    detail: quiet ? String(localized: "Allow / Deny on a notification needs banners or alerts.") : nil,
                    fix: Fix(title: String(localized: "Open Notification Settings…")) { openNotificationSettings() }
                ))
            case .notDetermined:
                checks.append(RemoteCheck(
                    id: "notifications", title: String(localized: "Notifications aren't allowed yet"), ok: false,
                    fix: Fix(title: String(localized: "Allow…")) {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
                    }
                ))
            default:
                checks.append(RemoteCheck(
                    id: "notifications", title: String(localized: "Notifications are turned off for ClaudeDeck"), ok: false,
                    detail: String(localized: "You won't hear about prompts on the other Mac."),
                    fix: Fix(title: String(localized: "Open Notification Settings…")) { openNotificationSettings() }
                ))
            }
        }

        // Host: the firewall must let the other Mac in.
        if host, let firewall {
            checks.append(RemoteCheck(
                id: "firewall",
                title: firewall.allowsIncoming ? String(localized: "The firewall lets connections in") : String(localized: "The firewall blocks incoming connections"),
                ok: firewall.allowsIncoming,
                detail: firewall.allowsIncoming ? nil : String(localized: "Allow ClaudeDeck in System Settings › Network › Firewall › Options."),
                fix: Fix(title: String(localized: "Open Firewall Settings…")) { open("x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall") }
            ))
        }

        // Remote: a host to connect to, and is it online in the tailnet?
        if client {
            if let pairing = remote.pairing {
                let online = pairing.addresses.lazy.compactMap { tailscale?.peers[$0] }.first
                checks.append(RemoteCheck(
                    id: "peer",
                    title: online == false
                        ? String(localized: "\(pairing.hostName) is offline in Tailscale")
                        : String(localized: "Paired with \(pairing.hostName)"),
                    ok: online != false,
                    detail: online == false ? String(localized: "Wake that Mac and make sure Tailscale is connected there.") : nil
                ))
            } else {
                checks.append(RemoteCheck(
                    id: "peer", title: String(localized: "No Mac to connect to yet"), ok: false,
                    detail: String(localized: "On the home Mac, turn on \"Let my other Macs see and answer this Mac's sessions\" and set the same password there.")
                ))
            }
        }
        return checks
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    private static func openNotificationSettings() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
    }

    private static func openTailscaleFix() -> Fix? {
        let ids = ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"]
        if let app = ids.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            return Fix(title: String(localized: "Open Tailscale")) { NSWorkspace.shared.open(app) }
        }
        return nil
    }
}
