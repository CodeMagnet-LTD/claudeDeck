import SwiftUI
import VisionKit

/// Labels and colors, the same as the Mac's sidebar.
enum SessionStyle {
    static func label(_ state: RemoteSession.State) -> String {
        switch state {
        case .notStarted, .ended: String(localized: "Stopped")
        case .starting: String(localized: "Starting")
        case .shell: String(localized: "Terminal")
        case .running: String(localized: "Running")
        case .needsPermission: String(localized: "Needs permission")
        case .needsAnswer: String(localized: "Asking a question")
        case .idle: String(localized: "Your turn")
        }
    }

    static func color(_ state: RemoteSession.State) -> Color {
        switch state {
        case .running: .green
        case .needsPermission, .needsAnswer: .red
        case .idle: .yellow
        case .starting: .green.opacity(0.5)
        case .shell: .blue
        case .notStarted, .ended: .secondary.opacity(0.5)
        }
    }
}

struct RootView: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        @Bindable var store = store
        if store.pairing == nil {
            NavigationStack { PairingView() }
        } else {
            NavigationStack(path: $store.path) { SessionListView() }
        }
    }
}

// MARK: Sessions

struct SessionListView: View {
    @Environment(RemoteStore.self) private var store
    @State private var showSettings = false
    @State private var showNewSession = false

    var body: some View {
        let all = store.snapshot?.sessions ?? []
        let sessions = all.filter { $0.state != .notStarted }
        let closed = all.filter { $0.state == .notStarted }
        let waiting = sessions.filter(\.needsAttention)
        let projects = Dictionary(grouping: sessions, by: \.project)
        let projectNames = sessions.map(\.project).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        List {
            ConnectionBanner()
            if !waiting.isEmpty {
                Section("Waiting for you") {
                    ForEach(waiting) { SessionRowLink(session: $0, showProject: true) }
                }
            }
            ForEach(projectNames, id: \.self) { project in
                Section(project.isEmpty ? String(localized: "Sessions") : project) {
                    ForEach(projects[project] ?? []) { SessionRowLink(session: $0, showProject: false) }
                }
            }
            if store.connection == .connected, sessions.isEmpty {
                Text("No running sessions").foregroundStyle(.secondary)
            }
            if !closed.isEmpty {
                Section {
                    DisclosureGroup("Closed sessions (\(closed.count))") {
                        ForEach(closed) { session in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.name).lineLimit(1)
                                    if !session.project.isEmpty, !session.name.hasPrefix(session.project) {
                                        Text(session.project).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Resume") { store.resumeSession(session.id) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
            if let error = store.answerError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
        }
        .navigationTitle(store.snapshot?.hostName ?? store.pairing?.hostName ?? "ClaudeDeck")
        // A new identity per session: another session opened from a notification starts fresh.
        .navigationDestination(for: UUID.self) { SessionDetailView(sessionID: $0).id($0) }
        .refreshable { store.reconnect() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewSession = true } label: { Image(systemName: "plus") }
                    .disabled(store.connection != .connected || store.projects.isEmpty)
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .sheet(isPresented: $showNewSession) { NavigationStack { NewSessionView() } }
    }
}

struct SessionRowLink: View {
    @Environment(RemoteStore.self) private var store
    let session: RemoteSession
    let showProject: Bool
    @State private var confirmStop = false

    var body: some View {
        NavigationLink(value: session.id) {
            SessionRow(session: session, showProject: showProject)
        }
        .swipeActions(edge: .trailing) {
            if session.state != .shell {
                Button("Stop", role: .destructive) { confirmStop = true }
            }
        }
        .confirmationDialog("Stop \(session.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop Session", role: .destructive) { store.stopSession(session.id) }
        } message: {
            Text("Claude stops on the Mac. You can resume the conversation later.")
        }
    }
}

/// Start a Claude session in one of the Mac's projects, optionally with a first message.
struct NewSessionView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var prompt = ""

    var body: some View {
        Form {
            Picker("Project", selection: $projectID) {
                ForEach(store.projects) { Text($0.name).tag(Optional($0.id)) }
            }
            Section {
                TextField("What should Claude do? (optional)", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
            } footer: {
                Text("Sent once Claude has started on the Mac.")
            }
        }
        .navigationTitle("New Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") {
                    if let projectID { store.startSession(in: projectID, prompt: prompt) }
                    dismiss()
                }
                .disabled(projectID == nil || store.connection != .connected)
            }
        }
        .onAppear { if projectID == nil { projectID = store.projects.first?.id } }
    }
}

struct SessionRow: View {
    @Environment(RemoteStore.self) private var store
    let session: RemoteSession
    let showProject: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(SessionStyle.color(session.state)).frame(width: 9, height: 9)
                Text(session.name).font(.body.weight(.medium)).lineLimit(1)
                if showProject, !session.project.isEmpty, !session.name.hasPrefix(session.project) {
                    Text(session.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let date = session.updatedAt {
                    Text(date, style: .relative).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            if !(session.state == .idle && !session.unseen) || session.detail != nil {
                HStack(spacing: 6) {
                    StatusPill(state: session.state)
                    if let detail = session.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            PermissionButtons(session: session)
        }
        .padding(.vertical, 2)
    }
}

struct StatusPill: View {
    let state: RemoteSession.State

    var body: some View {
        Text(SessionStyle.label(state))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(state == .idle ? Color.black.opacity(0.8) : .white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(SessionStyle.color(state), in: Capsule())
    }
}

struct PermissionButtons: View {
    @Environment(RemoteStore.self) private var store
    let session: RemoteSession

    var body: some View {
        if let stamp = session.permissionStamp {
            let busy = store.answering.contains(session.id)
            HStack(spacing: 10) {
                Button("Allow") { store.answer(session.id, stamp: stamp, approve: true) }
                    .buttonStyle(.borderedProminent)
                Button("Deny", role: .destructive) { store.answer(session.id, stamp: stamp, approve: false) }
                    .buttonStyle(.bordered)
                if busy { ProgressView() }
            }
            .controlSize(.small)
            .disabled(busy)
        }
    }
}

struct ConnectionBanner: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        switch store.connection {
        case .connected, .unpaired:
            EmptyView()
        case .paused, .connecting:
            Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
        case .retrying(let reason, let at):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(at.timeIntervalSince(context.date).rounded()))
                Label("Retrying in \(seconds) s — \(reason)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("Is Tailscale connected on this iPhone?").font(.footnote).foregroundStyle(.secondary)
        case .refused(let reason):
            Label(reason, systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.red)
        }
    }
}

// MARK: Pairing

struct PairingView: View {
    @Environment(RemoteStore.self) private var store
    @State private var host = ""
    @State private var password = ""
    @State private var link = ""
    @State private var linkFailed = false
    @State private var scanning = false
    @State private var chosenLAN: DiscoveredHost?
    @State private var lanPassword = ""

    var body: some View {
        Form {
            Section {
                Text("See and answer the Claude sessions running on your Mac. Both devices need Tailscale, signed in to the same account.")
                    .font(.callout)
            }
            Section {
                if store.lanHosts.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking for Macs on this network…").foregroundStyle(.secondary)
                    }
                }
                ForEach(store.lanHosts) { host in
                    Button {
                        chosenLAN = host
                        lanPassword = ""
                    } label: {
                        Label(host.name, systemImage: "desktopcomputer")
                    }
                }
            } header: {
                Text("On this network")
            } footer: {
                Text("Shown when the Mac has \"Also reachable on the local network\" on in Settings › Remote (Tailscale).")
            }
            if DataScannerViewController.isSupported {
                Section {
                    Button { scanning = true } label: { Label("Scan the QR Code", systemImage: "qrcode.viewfinder") }
                } footer: {
                    Text("On the Mac: Settings › Remote (Tailscale) › Other ways to pair › Show Pairing Code.")
                }
            }
            Section {
                TextField("Mac's Tailscale name (e.g. home-mac)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Password", text: $password)
                Button("Connect") { store.pair(host: host, password: password) }
                    .disabled(host.isEmpty || password.count < RemoteHandshake.minimumPasswordLength)
            } header: {
                Text("With the password")
            } footer: {
                Text("The password you set on the Mac in Settings › Remote (Tailscale).")
            }
            Section("With a pairing link") {
                TextField("claudedeck://pair?…", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Pair") { linkFailed = !store.pair(link: link) }.disabled(link.isEmpty)
                if linkFailed {
                    Text("That isn't a ClaudeDeck pairing link.").font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Pair with Your Mac")
        .onAppear { store.startLANDiscovery() }
        .alert(chosenLAN?.name ?? "", isPresented: Binding(get: { chosenLAN != nil }, set: { if !$0 { chosenLAN = nil } })) {
            SecureField("Password", text: $lanPassword)
            Button("Connect") {
                if let host = chosenLAN { store.pair(lanHost: host, password: lanPassword) }
                chosenLAN = nil
            }
            .disabled(lanPassword.count < RemoteHandshake.minimumPasswordLength)
            Button("Cancel", role: .cancel) { chosenLAN = nil }
        } message: {
            Text("The password you set on the Mac in Settings › Remote (Tailscale).")
        }
        .sheet(isPresented: $scanning) {
            QRScanner { code in
                scanning = false
                linkFailed = !store.pair(link: code)
            }
            .ignoresSafeArea()
        }
    }
}

/// Camera QR scanner (VisionKit); hands back the first claudedeck:// code.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let text = code.payloadStringValue, text.hasPrefix("claudedeck://pair") else { continue }
                done = true
                scanner.stopScanning()
                onCode(text)
            }
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let pairing = store.pairing {
                Section("Mac") {
                    LabeledContent("Name", value: store.snapshot?.hostName ?? pairing.hostName)
                    LabeledContent("Address", value: pairing.addresses.first ?? "")
                    LabeledContent("Connection", value: connectionText)
                }
                Section {
                    Button("Forget This Mac", role: .destructive) {
                        store.forget()
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private var connectionText: String {
        switch store.connection {
        case .connected: String(localized: "Connected")
        case .refused(let reason): reason
        case .retrying(let reason, _): reason
        default: String(localized: "Connecting…")
        }
    }
}
