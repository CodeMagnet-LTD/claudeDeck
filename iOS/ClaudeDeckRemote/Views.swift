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

extension EnvironmentValues {
    /// The window this view is in: sessions started here open here.
    @Entry var sceneID: UUID?
}

/// One window. Each keeps its own selection, so two windows can show two sessions; a regular width
/// shows the list beside the session, a compact one (iPhone, Slide Over) collapses to a stack.
struct RootView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    /// The window's value: the session it was opened for, then whatever it shows.
    @Binding var windowSession: UUID?
    @State private var sceneID = UUID()
    @State private var selection: UUID?

    var body: some View {
        Group {
            if store.pairing == nil {
                NavigationStack { PairingView() }
            } else {
                NavigationSplitView {
                    SessionListView(selection: $selection)
                } detail: {
                    // A new identity per session: another session opened from a notification starts fresh.
                    if let selection {
                        SessionDetailView(sessionID: selection).id(selection)
                    } else {
                        ContentUnavailableView("No Session Selected", systemImage: "terminal")
                    }
                }
            }
        }
        .environment(\.sceneID, sceneID)
        .onAppear {
            store.sceneAppeared(sceneID)
            if selection == nil { selection = windowSession }
        }
        .onDisappear { store.sceneDisappeared(sceneID) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { store.sceneActivated(sceneID) }
        }
        .onChange(of: selection, initial: true) { _, id in
            store.sceneSelected(sceneID, session: id)
            // Not on iPhone: restoring it would reopen the last session on every launch.
            if let id, supportsMultipleWindows { windowSession = id }
        }
        // Initial too: a notification tap that launched the app is waiting for the first window.
        .onChange(of: store.openRequest, initial: true) { _, request in
            guard let request, store.openRequest?.token == request.token,
                  request.scene == nil || request.scene == sceneID else { return }
            store.openRequest = nil
            selection = request.session
        }
        .onChange(of: store.newWindowRequest) { _, request in
            guard let request, store.newWindowRequest?.token == request.token else { return }
            store.newWindowRequest = nil
            openWindow(value: request.session)
        }
    }
}

// MARK: Sessions

struct SessionListView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.sceneID) private var sceneID
    @Binding var selection: UUID?
    @State private var showSettings = false
    @State private var showNewSession = false
    /// The project the New Session sheet starts on (a pinned project's row).
    @State private var newSessionProject: UUID?

    var body: some View {
        let all = store.snapshot?.sessions ?? []
        let sessions = all.filter { $0.state != .notStarted }
        let closed = all.filter { $0.state == .notStarted }
        let waiting = sessions.filter(\.needsAttention)
        let projects = Dictionary(grouping: sessions, by: \.project)
        // Pinned on the Mac: first, and shown even without a running session.
        let pinned = store.projects.filter(\.pinned)
        let pinnedNames = Set(pinned.map(\.name))
        let projectNames = pinned.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            + sessions.map(\.project).reduce(into: [String]()) { if !$0.contains($1), !pinnedNames.contains($1) { $0.append($1) } }
        List(selection: $selection) {
            ConnectionBanner()
            if let usage = store.snapshot?.usage { UsageRow(usage: usage) }
            if !waiting.isEmpty {
                Section("Waiting for you") {
                    ForEach(waiting) { SessionRowLink(session: $0, showProject: true) }
                }
            }
            ForEach(projectNames, id: \.self) { project in
                Section {
                    ForEach(projects[project] ?? []) { SessionRowLink(session: $0, showProject: false) }
                    if projects[project] == nil, let id = pinned.first(where: { $0.name == project })?.id {
                        Button {
                            newSessionProject = id
                            showNewSession = true
                        } label: {
                            Label("New Session", systemImage: "plus")
                        }
                        .disabled(store.connection != .connected)
                    }
                } header: {
                    Group {
                        if pinnedNames.contains(project) {
                            Label(project, systemImage: "pin.fill")
                        } else {
                            Text(project.isEmpty ? String(localized: "Sessions") : project)
                        }
                    }
                    .contextMenu { projectMenu(project, running: projects[project] ?? []) }
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
                                Button("Resume") { store.resumeSession(session.id, from: sceneID) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                            .contextMenu {
                                Button { store.resumeSession(session.id, from: sceneID) } label: {
                                    Label("Resume", systemImage: "play")
                                }
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
        .refreshable { store.reconnect() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { ProjectFilesView() } label: { Image(systemName: "folder") }
                    .disabled(store.connection != .connected || store.projects.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newSessionProject = nil
                    showNewSession = true
                } label: { Image(systemName: "plus") }
                    .disabled(store.connection != .connected || store.projects.isEmpty)
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .sheet(isPresented: $showNewSession) { NavigationStack { NewSessionView(initialProject: newSessionProject) } }
    }
}

extension SessionListView {
    /// The Mac's project menu, as far as the other Mac can be asked to (no pin / rename there yet).
    @ViewBuilder
    func projectMenu(_ name: String, running: [RemoteSession]) -> some View {
        if let project = store.projects.first(where: { $0.name == name }) {
            Button {
                newSessionProject = project.id
                showNewSession = true
            } label: { Label("New Session…", systemImage: "plus") }
            Button { store.startShell(in: project.id, command: "", from: sceneID) } label: {
                Label("New Terminal", systemImage: "apple.terminal")
            }
        }
        let claude = running.filter { $0.state != .shell }
        if !claude.isEmpty {
            Divider()
            Button(role: .destructive) { claude.forEach { store.stopSession($0.id) } } label: {
                Label("End All Sessions (\(claude.count))", systemImage: "power")
            }
        }
    }
}

struct SessionRowLink: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    let session: RemoteSession
    let showProject: Bool
    @State private var confirmStop = false

    var body: some View {
        NavigationLink(value: session.id) {
            SessionRow(session: session, showProject: showProject)
        }
        .contextMenu {
            // Like the Mac's session menu, as far as the other Mac can be asked to.
            if let stamp = session.permissionStamp {
                Button { store.answer(session.id, stamp: stamp, approve: true) } label: { Label("Allow", systemImage: "checkmark") }
                Button(role: .destructive) { store.answer(session.id, stamp: stamp, approve: false) } label: { Label("Deny", systemImage: "xmark") }
                Divider()
            }
            if supportsMultipleWindows {
                Button { openWindow(value: session.id) } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
            }
            if session.state == .running {
                Button { store.interrupt(session.id) } label: { Label("Interrupt (Esc)", systemImage: "stop.circle") }
            }
            if session.unseen {
                Button { store.markSeen(session.id) } label: { Label("Mark as Seen", systemImage: "eye") }
            }
            if session.state != .shell {
                Divider()
                Button(role: .destructive) { confirmStop = true } label: { Label("End Session", systemImage: "power") }
            }
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

/// The plan's usage, like the Mac's sidebar meter.
struct UsageRow: View {
    let usage: RemoteUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value = usage.fiveHour { meter(String(localized: "5 hours"), value, usage.fiveHourResetsAt) }
            if let value = usage.week { meter(String(localized: "Week"), value, usage.weekResetsAt) }
        }
        .padding(.vertical, 2)
    }

    private func meter(_ title: String, _ value: Double, _ reset: Date?) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 60, alignment: .leading)
            ProgressView(value: min(max(value, 0), 100), total: 100)
                .tint(value >= 90 ? .red : value >= 70 ? .orange : .green)
            Text("\(Int(value.rounded()))%").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
            if let reset {
                Text(reset, style: .relative).font(.caption2).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            }
        }
    }
}

/// Start a Claude session (new, or resuming a past conversation) or a terminal in one of the Mac's projects.
struct NewSessionView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.sceneID) private var sceneID
    @Environment(\.dismiss) private var dismiss
    var initialProject: UUID? = nil
    @State private var projectID: UUID?
    @State private var prompt = ""
    @State private var kind = Kind.claude
    @State private var command = ""

    enum Kind { case claude, terminal }

    var body: some View {
        Form {
            Picker("Project", selection: $projectID) {
                ForEach(store.projects) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Type", selection: $kind) {
                Text("Claude").tag(Kind.claude)
                Text("Terminal").tag(Kind.terminal)
            }
            .pickerStyle(.segmented)
            if kind == .claude {
                Section {
                    TextField("What should Claude do? (optional)", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text("Sent once Claude has started on the Mac.")
                }
                if let projectID, let past = store.pastConversations[projectID], let latest = past.first {
                    Section {
                        Button {
                            store.resumeConversation(latest.id, in: projectID, from: sceneID)
                            dismiss()
                        } label: {
                            Label("Continue the latest conversation", systemImage: "arrow.uturn.forward")
                        }
                    }
                    Section("Continue a past conversation") {
                        ForEach(past) { item in
                            Button {
                                store.resumeConversation(item.id, in: projectID, from: sceneID)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).lineLimit(2).foregroundStyle(.primary)
                                    Text(item.modifiedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                Section {
                    TextField("Command (optional), e.g. yarn dev", text: $command)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    Text("Opens a shell in the project folder on the Mac.")
                }
            }
        }
        .onChange(of: projectID, initial: true) { _, id in
            if let id { store.loadPastConversations(id) }
        }
        .navigationTitle("New Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") {
                    if let projectID {
                        if kind == .claude { store.startSession(in: projectID, prompt: prompt, from: sceneID) } else { store.startShell(in: projectID, command: command, from: sceneID) }
                    }
                    dismiss()
                }
                .disabled(projectID == nil || store.connection != .connected)
            }
        }
        .onAppear { if projectID == nil { projectID = initialProject ?? store.projects.first?.id } }
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
            .foregroundStyle(state == .idle || state == .running || state == .starting ? Color.black.opacity(0.8) : .white)
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
