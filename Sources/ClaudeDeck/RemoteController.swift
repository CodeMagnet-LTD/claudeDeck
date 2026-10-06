import AppKit
import ClaudeDeckCore
import Foundation
import Network
import Observation
import SystemConfiguration

/// Remote mode (RemoteProtocol.swift). Host side: listens on Tailscale, sends the sessions'
/// state and answers permission prompts with the same keystrokes as the local buttons. Remote
/// side: connects to the paired Mac, shows its sessions in the sidebar and notifies.
///
/// Pairing records go to iCloud Drive (`ClaudeDeck/Remote/<host id>.json`); a
/// `claudedeck://pair?…` link (QR code / copy) is the fallback. Demo mode uses only
/// `CLAUDEDECK_PAIRING_DIR` and never iCloud.
@MainActor
@Observable
final class RemoteController {
    // MARK: Host state
    private(set) var hostState: RemoteServer.State = .stopped
    /// Names of the connected remotes.
    private(set) var connectedRemotes: [String] = []
    /// Addresses remotes are told to use (MagicDNS first); empty while Tailscale isn't up.
    private(set) var hostAddresses: [String] = []
    private(set) var hostError: String?
    /// Last answer a remote sent (diagnostics, DebugSnapshot).
    @ObservationIgnored private(set) var lastRemoteAnswer: String?
    var lastRejectedPeer: String? { server?.lastRejectedPeer }

    // MARK: Remote state
    enum Connection: Equatable {
        case off
        case noHost
        case connecting
        case connected
        case retrying(String, at: Date)
        case refused(String)
    }
    private(set) var connection: Connection = .off
    private(set) var snapshot: RemoteSnapshot?
    /// Hosts found in the pairing folder (excluding this Mac).
    private(set) var availableHosts: [RemotePairing] = []
    /// Online Macs in the tailnet (password mode tries each).
    private(set) var discoveredMacs: [String] = []
    /// The address the current connection uses (diagnostics).
    var connectedVia: String? { hostConnection?.connectedAddress }
    /// Hosts advertising on the local network (Bonjour), this Mac excluded.
    private(set) var lanHosts: [DiscoveredHost] = []
    @ObservationIgnored private var lanDiscovery: RemoteDiscovery?
    /// Prompts answered from here, waiting for the host's result.
    private(set) var answering: Set<UUID> = []
    /// Last failed answer (the prompt changed on the host meanwhile).
    private(set) var answerError: String?

    private(set) var local: RemoteLocalState

    // MARK: Live terminals
    enum TerminalState: Equatable { case waiting, live, ended }
    /// Remote side: state of each open remote terminal tab.
    private(set) var terminalStates: [UUID: TerminalState] = [:]
    /// Remote side: last known names of the other Mac's sessions (tab titles while disconnected).
    private(set) var terminalNames: [UUID: String] = [:]
    @ObservationIgnored private var sinks: [UUID: RemoteTerminalSink] = [:]
    /// Host side: sessions some remote watches, their unsent output, pending resizes.
    @ObservationIgnored private var watched: Set<UUID> = []
    @ObservationIgnored private var outputBuffers: [UUID: Data] = [:]
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var resizeTasks: [UUID: Task<Void, Never>] = [:]
    /// Host side: terminals sized by a remote viewer.
    @ObservationIgnored private var fitted: Set<UUID> = []
    /// Held while a remote watches a terminal: App Nap would otherwise delay the output timer by
    /// seconds when ClaudeDeck is in the background. Doesn't keep the Mac awake.
    @ObservationIgnored private var streamingActivity: NSObjectProtocol?
    /// Last push result (Settings).
    private(set) var pushStatus: String?
    @ObservationIgnored private var apnsToken: (value: String, issuedAt: Date)?
    /// Byte / event counters (DebugSnapshot's remote.txt).
    @ObservationIgnored private(set) var counters: [String: Int] = [:]

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var server: RemoteServer?
    @ObservationIgnored private var hostConnection: RemoteHostConnection?
    @ObservationIgnored private var connectedPairing: RemotePairing?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: TimeInterval = 2
    @ObservationIgnored private var folderWatcher: DirectoryWatcher?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var snapshotTimer: Timer?
    @ObservationIgnored private var addressTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private let localURL: URL
    /// Called with sessions that newly need the user (notifications).
    @ObservationIgnored var onAttention: ((RemoteSession, String) -> Void)?
    /// Called with sessions that no longer need the user (answered, seen): drop their notifications.
    @ObservationIgnored var onAttentionCleared: (([UUID]) -> Void)?

    private static let env = ProcessInfo.processInfo.environment
    /// Demo testing: two demo copies talk over 127.0.0.1.
    private static let allowLoopback = env["CLAUDEDECK_REMOTE_ALLOW_LOOPBACK"] != nil
    static let port: UInt16 = env["CLAUDEDECK_REMOTE_PORT"].flatMap(UInt16.init) ?? RemotePairing.defaultPort
    /// Port of a host found with the password (demo testing: the other copy's port).
    static let connectPort: UInt16 = env["CLAUDEDECK_REMOTE_CONNECT_PORT"].flatMap(UInt16.init) ?? RemotePairing.defaultPort
    /// Id of the host found through Tailscale with the password (one at a time).
    static let passwordHostID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!

    static let pairingFolder: URL? = {
        if let dir = env["CLAUDEDECK_PAIRING_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return AppModel.isDemo ? nil : RemotePairingFolder.defaultFolder()
    }()

    /// The computer name from System Settings › General › Sharing (not the Bonjour name, which
    /// gets a " (2)" suffix after a name clash on the network).
    static var hostName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    init() {
        localURL = DeckDataStore.default().url.deletingLastPathComponent().appending(path: "remote.json")
        local = RemoteLocalState.load(from: localURL)
    }

    func start(model: AppModel) {
        self.model = model
        Self.current = self
        let previous = model.onCountsChanged
        model.onCountsChanged = { [weak self] in
            previous?()
            self?.publishSnapshot()
        }
        let previousAttention = model.onAttention
        model.onAttention = { [weak self] event in
            previousAttention?(event)
            self?.push(event)
        }
        model.terminals.onOutput = { [weak self] id, bytes in self?.terminalOutput(id, bytes) }
        model.terminals.onResize = { [weak self] id in self?.terminalResized(id) }
        let previousExit = model.terminals.onExit
        model.terminals.onExit = { [weak self] id, code in
            previousExit?(id, code)
            self?.terminalExited(id)
        }
        if let folder = Self.pairingFolder {
            let watcher = DirectoryWatcher(url: folder, debounce: 0.5) { [weak self] in
                Task { @MainActor in self?.pairingFolderChanged() }
            }
            watcher.start()
            folderWatcher = watcher
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
        refresh()
    }

    func stop() {
        server?.stop()
        server = nil
        hostConnection?.close()
        hostConnection = nil
        retryTask?.cancel()
        snapshotTimer?.invalidate()
    }

    /// Matches both sides to the settings.
    func refresh() {
        guard let settings = model?.deck.settings else { return }
        // Local-network access changes what the listener accepts and advertises: start it over.
        if server != nil, hostingLAN != settings.remoteLAN { restartServer() }
        settings.remoteHost ? startHosting() : stopHosting()
        updateLANDiscovery(settings.remoteClient)
        settings.remoteClient ? reconnect(force: false) : disconnect()
    }

    private func saveLocal() {
        try? local.save(to: localURL)
    }

    // MARK: Host

    /// Whether the running listener accepts the local network (and advertises over Bonjour).
    @ObservationIgnored private var hostingLAN = false

    /// Terminals sized by a remote viewer get the window's size back.
    private func releaseFitted() {
        for id in fitted { model?.terminals.view(for: id)?.forcedGrid = nil }
        fitted = []
    }

    private func restartServer() {
        releaseFitted()
        watched = []
        updateStreamingActivity()
        outputBuffers = [:]
        server?.stop()
        server = nil
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        connectedRemotes = []
    }

    private func startHosting() {
        if server == nil {
            let lan = model?.deck.settings.remoteLAN == true
            hostingLAN = lan
            let server = RemoteServer(port: Self.port, key: { [weak self] in
                MainActor.assumeIsolated { self?.model?.deck.settings.remoteHost == true ? self?.local.hostKey : nil }
            }, acceptsPeer: { ip in
                Tailscale.isTailscaleIP(ip) || (lan && Tailscale.isPrivateLAN(ip)) || (Self.allowLoopback && Tailscale.isLoopback(ip))
            })
            if lan { server.bonjour = (Self.hostName, local.hostID) }
            server.onStateChange = { [weak self] state in
                MainActor.assumeIsolated { self?.hostState = state }
            }
            server.onPeersChanged = { [weak self] names in
                MainActor.assumeIsolated { self?.connectedRemotes = names }
            }
            server.onPermission = { [weak self] id, stamp, approve in
                MainActor.assumeIsolated {
                    guard let model = self?.model else { return false }
                    let at = Date(timeIntervalSince1970: stamp)
                    let applied = approve ? model.approvePermission(id, expectedAt: at) : model.denyPermission(id, expectedAt: at)
                    self?.lastRemoteAnswer = "\(approve ? "allow" : "deny") \(id.uuidString): \(applied ? "sent" : "stale")"
                    if applied { self?.publishSnapshot() }
                    return applied
                }
            }
            server.onTerminalOpen = { [weak self] id in
                MainActor.assumeIsolated { self?.terminalStart(id) }
            }
            server.onTerminalInput = { [weak self] id, data in
                MainActor.assumeIsolated {
                    self?.counters["inputReceived", default: 0] += data.count
                    // The same path as a key press on this Mac (status follows, e.g. "1" answers a prompt).
                    guard let view = self?.model?.terminals.view(for: id), self?.model?.terminals.isRunning(id) == true else { return }
                    view.send(source: view, data: ArraySlice(data))
                }
            }
            server.onHistoryRequest = { [weak self] id, before, after, limit, reply in
                MainActor.assumeIsolated { self?.history(id, before: before, after: after, limit: limit, reply: reply) }
            }
            server.onStartSession = { [weak self] projectID, prompt in
                MainActor.assumeIsolated { self?.startSession(in: projectID, prompt: prompt) }
            }
            server.onStartShell = { [weak self] projectID, command in
                MainActor.assumeIsolated {
                    guard let model = self?.model, model.deck.project(projectID) != nil else { return nil }
                    let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let id = trimmed.isEmpty ? model.newShell(in: projectID) : model.newCommandShell(in: projectID, command: trimmed)
                    self?.publishSnapshot()
                    return id
                }
            }
            server.onPastConversations = { [weak self] projectID, reply in
                MainActor.assumeIsolated {
                    guard let path = self?.model?.deck.project(projectID)?.path else { reply([]); return }
                    Task.detached {
                        reply(TranscriptIndex.sessions(forProject: path, limit: 40).map {
                            RemotePastConversation(id: $0.id, title: $0.title, modifiedAt: $0.modifiedAt)
                        })
                    }
                }
            }
            server.onResumeConversation = { [weak self] projectID, conversationID in
                MainActor.assumeIsolated {
                    guard let model = self?.model, model.deck.project(projectID) != nil,
                          conversationID.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
                    let id = model.newSession(in: projectID, resumeID: conversationID)
                    self?.publishSnapshot()
                    return id
                }
            }
            server.onInterrupt = { [weak self] id in
                MainActor.assumeIsolated {
                    // Only while working: on a prompt, Esc means Deny (the phone has a button for that).
                    guard let model = self?.model, model.terminals.isRunning(id), model.status(of: id).display.isRunning else { return }
                    model.terminals.type("\u{1b}", into: id)
                }
            }
            server.onFileRequest = { [weak self] request, reply in
                MainActor.assumeIsolated {
                    switch request {
                    case .listDirectory(let projectID, let path):
                        guard let root = self?.model?.deck.project(projectID)?.path else { return }
                        Task.detached {
                            let result = RemoteFiles.list(path, in: root)
                            reply(.directory(projectID: projectID, path: path, entries: result.entries, error: result.error))
                        }
                    case .readFile(let projectID, let path):
                        guard let root = self?.model?.deck.project(projectID)?.path else { return }
                        Task.detached {
                            let result = RemoteFiles.read(path, in: root)
                            reply(.file(projectID: projectID, path: path, text: result.text, size: result.size, error: result.error))
                        }
                    default:
                        break
                    }
                }
            }
            server.onStopSession = { [weak self] id in
                MainActor.assumeIsolated {
                    guard let model = self?.model, model.terminals.isRunning(id) else { return }
                    model.stop(id)
                }
            }
            server.onResumeSession = { [weak self] id in
                MainActor.assumeIsolated {
                    guard let model = self?.model, model.deck.session(id)?.kind == .claude, !model.terminals.isRunning(id) else { return }
                    model.launch(id, resume: model.canResume(id))
                    self?.publishSnapshot()
                }
            }
            server.onTerminalFit = { [weak self] id, cols, rows in
                MainActor.assumeIsolated {
                    guard let view = self?.model?.terminals.view(for: id) else { return }
                    view.forcedGrid = cols == 0 ? nil : (cols, rows)
                    if cols == 0 { self?.fitted.remove(id) } else { self?.fitted.insert(id) }
                }
            }
            server.onMarkSeen = { [weak self] id in
                MainActor.assumeIsolated {
                    guard let model = self?.model, model.deck.session(id) != nil else { return }
                    model.markSeen(id)
                    self?.publishSnapshot()
                }
            }
            server.onSendPrompt = { [weak self] id, text in
                MainActor.assumeIsolated { self?.sendPrompt(id, text: text) }
            }
            server.onRegisterPush = { [weak self] device in
                MainActor.assumeIsolated { self?.registerPush(device) }
            }
            server.onWatchedChanged = { [weak self] sessions in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.watched = sessions
                    self.outputBuffers = self.outputBuffers.filter { sessions.contains($0.key) }
                    // Nobody watches any more: the window gets its size back.
                    for id in self.fitted where !sessions.contains(id) {
                        self.model?.terminals.view(for: id)?.forcedGrid = nil
                        self.fitted.remove(id)
                    }
                    self.updateStreamingActivity()
                }
            }
            self.server = server
            server.start()
            // Names, details and times change without a count change; resend when they do.
            snapshotTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishSnapshot() }
            }
        }
        publishSnapshot()
        refreshAddresses()
    }

    private func stopHosting() {
        guard server != nil || !hostAddresses.isEmpty else { return }
        releaseFitted()
        watched = []
        updateStreamingActivity()
        outputBuffers = [:]
        server?.stop()
        server = nil
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        hostState = .stopped
        connectedRemotes = []
        if let folder = Self.pairingFolder { RemotePairingFolder.remove(local.hostID, in: folder) }
    }

    /// Looks up the Tailscale name and IPs (off the main thread) and republishes the pairing.
    func refreshAddresses() {
        guard model?.deck.settings.remoteHost == true else { return }
        addressTask?.cancel()
        addressTask = Task { @MainActor [weak self] in
            let found = await Task.detached { () -> [String] in
                let status = Tailscale.status()
                var addresses: [String] = []
                if let dns = status?.dnsName { addresses.append(dns) }
                for ip in (status?.ips ?? []) + Tailscale.interfaceAddresses() where !addresses.contains(ip) {
                    addresses.append(ip)
                }
                return addresses
            }.value
            guard let self, !Task.isCancelled else { return }
            self.hostAddresses = Self.allowLoopback ? found + ["127.0.0.1"] : found
            self.hostError = self.hostAddresses.isEmpty
                ? String(localized: "Tailscale isn't running on this Mac. Install it and sign in, then try again.")
                : nil
            self.publishPairing()
        }
    }

    var hostPairing: RemotePairing? {
        guard !hostAddresses.isEmpty else { return nil }
        return RemotePairing(id: local.hostID, hostName: Self.hostName, addresses: hostAddresses, port: Self.port, key: local.hostKey, updatedAt: Date())
    }

    private func publishPairing() {
        guard let folder = Self.pairingFolder, let pairing = hostPairing else { return }
        do {
            try RemotePairingFolder.write(pairing, in: folder)
        } catch {
            hostError = String(localized: "Couldn't write the pairing to iCloud Drive: \(error.localizedDescription)")
        }
    }

    /// The same password on both Macs: it becomes this Mac's host key and the key used to find
    /// and open the other Mac. No iCloud Drive needed.
    var hasPassword: Bool { local.hostUsesPassword || local.passwordKey != nil }

    func setPassword(_ password: String) {
        let key = RemoteHandshake.key(fromPassword: password)
        let changed = key != local.hostKey
        local.hostKey = key
        local.hostUsesPassword = true
        local.passwordKey = key
        saveLocal()
        if changed { server?.disconnectAll(reason: String(localized: "The pairing key changed on the other Mac.")) }
        publishPairing()
        reconnect(force: true)
    }

    func removePassword() {
        local.passwordKey = nil
        local.lastHostAddress = nil
        regenerateHostKey()
        reconnect(force: true)
    }

    /// New key: every paired remote has to pair again (iCloud Drive does it on its own).
    func regenerateHostKey() {
        local.hostKey = RemotePairing.makeKey()
        local.hostUsesPassword = false
        saveLocal()
        server?.disconnectAll(reason: String(localized: "The pairing key changed on the other Mac."))
        publishPairing()
    }

    private func publishSnapshot() {
        guard let server, let model else { return }
        var snapshot = Self.makeSnapshot(model)
        // How to reach this Mac away from home (a phone paired on the local network learns it here).
        snapshot.hostID = local.hostID
        snapshot.projects = model.deck.projects.map { RemoteProject(id: $0.id, name: $0.name) }
        if case .ok(let usage) = model.usage.state {
            snapshot.usage = RemoteUsage(fiveHour: usage.fiveHour?.usedPercent, fiveHourResetsAt: usage.fiveHour?.resetsAt,
                                         week: usage.sevenDay?.usedPercent, weekResetsAt: usage.sevenDay?.resetsAt)
        }
        snapshot.addresses = hostAddresses.filter { $0 != "127.0.0.1" }
        server.snapshot = snapshot
    }

    private static func makeSnapshot(_ model: AppModel) -> RemoteSnapshot {
        let sessions: [RemoteSession] = model.deck.sessions.compactMap { session in
            let status = model.status(of: session.id)
            guard let state = RemoteSession.State(status.display) else { return nil }
            // Closed sessions only when they can be resumed (the phone lists them under "Closed").
            if state == .notStarted, session.kind != .claude || !model.canResume(session.id) { return nil }
            return RemoteSession(
                id: session.id,
                name: session.name,
                project: model.deck.project(session.projectID)?.name ?? "",
                state: state,
                detail: status.detail.map { String($0.prefix(300)) },
                updatedAt: status.updatedAt,
                unseen: model.isUnseenIdle(session.id),
                permissionStamp: model.pendingPermissionStamp(session.id)?.timeIntervalSince1970
            )
        }
        return RemoteSnapshot(hostName: hostName, sessions: sessions)
    }

    // MARK: Host — live terminals

    private func updateStreamingActivity() {
        if watched.isEmpty, let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        } else if !watched.isEmpty, streamingActivity == nil {
            streamingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Streaming a terminal to another Mac"
            )
        }
    }

    private func terminalStart(_ id: UUID) -> RemoteServer.TerminalStart? {
        guard let model, model.terminals.isRunning(id), let view = model.terminals.view(for: id) else { return nil }
        // Output already on screen goes to the other watchers first; the new one gets it in the screen.
        flushOutput(id)
        let screen = TerminalCapture.screen(of: view)
        return RemoteServer.TerminalStart(cols: screen.cols, rows: screen.rows, screen: screen.ansi())
    }

    private func terminalOutput(_ id: UUID, _ bytes: ArraySlice<UInt8>) {
        counters["tapped", default: 0] += bytes.count
        guard watched.contains(id) else { return }
        counters["buffered", default: 0] += bytes.count
        outputBuffers[id, default: Data()].append(contentsOf: bytes)
        guard !flushScheduled else { return }
        flushScheduled = true
        // Coalesce a burst into one frame per ~16 ms.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushScheduled = false
                for id in Array(self.outputBuffers.keys) { self.flushOutput(id) }
            }
        }
    }

    private func flushOutput(_ id: UUID) {
        guard let bytes = outputBuffers.removeValue(forKey: id), !bytes.isEmpty else { return }
        counters["sent", default: 0] += bytes.count
        server?.sendOutput(sessionID: id, bytes: bytes)
    }

    /// The grid changed: once it settles, watchers get a fresh screen at the new size.
    private func terminalResized(_ id: UUID) {
        guard watched.contains(id) else { return }
        resizeTasks[id]?.cancel()
        resizeTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            self.resizeTasks[id] = nil
            self.server?.restartTerminal(sessionID: id)
        }
    }

    private func terminalExited(_ id: UUID) {
        guard watched.contains(id) else { return }
        flushOutput(id)
        server?.terminalEnded(sessionID: id)
    }

    // MARK: Host — conversation for remotes

    /// Parsed transcripts by session, reused while the file doesn't change.
    @ObservationIgnored private var historyCache: [UUID: (path: String, size: Int, entries: [ChatEntry])] = [:]

    private func history(_ id: UUID, before: String?, after: String?, limit: Int, reply: @escaping @Sendable (ChatPage?) -> Void) {
        // The hook's path follows /clear (a new transcript); the deck's is the one it resumed.
        guard let model, let path = model.hookStatuses[id]?.transcriptPath ?? model.deck.transcriptPath(for: id) else {
            reply(nil)
            return
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? 0
        if let cached = historyCache[id], cached.path == path, cached.size == size {
            reply(ConversationLog.page(cached.entries, before: before, after: after, limit: limit))
            return
        }
        Task { @MainActor [weak self] in
            let entries = await Task.detached { ConversationLog.entries(of: URL(fileURLWithPath: path)) }.value
            self?.historyCache[id] = (path, size, entries)
            reply(ConversationLog.page(entries, before: before, after: after, limit: limit))
        }
    }

    /// A new Claude session from the phone; the first message goes in once Claude is ready.
    private func startSession(in projectID: UUID, prompt: String?) -> UUID? {
        guard let model, model.deck.project(projectID) != nil else { return nil }
        let title = prompt?.split(separator: "\n").first.map(String.init)
        guard let id = model.newSession(in: projectID, title: title.flatMap { $0.isEmpty ? nil : $0 }) else { return nil }
        publishSnapshot()
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let launched = Date()
            Task { @MainActor [weak self] in
                // Like an automation: wait for this process's first hook (Claude is up), then a moment for the input box.
                for _ in 0..<120 {
                    if let hook = self?.model?.hookStatuses[id], hook.updatedAt >= launched { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                try? await Task.sleep(for: .seconds(1))
                self?.sendPrompt(id, text: prompt)
            }
        }
        return id
    }

    /// A message from the phone: typed into the session like the user would. Not while a prompt is
    /// on screen (Enter would answer it).
    private func sendPrompt(_ id: UUID, text: String) {
        guard let model, model.deck.session(id)?.kind == .claude, model.terminals.isRunning(id),
              !model.status(of: id).display.isBlocked
        else { return }
        model.terminals.type(text.trimmingCharacters(in: .whitespacesAndNewlines) + "\r", into: id)
    }

    // MARK: Host — iPhone pushes

    func setAPNs(_ credentials: APNsCredentials?) {
        local.apns = credentials
        apnsToken = nil
        saveLocal()
    }

    func removePushDevice(_ token: Data) {
        local.pushDevices.removeAll { $0.token == token }
        saveLocal()
    }

    private func registerPush(_ device: PushDevice) {
        if let index = local.pushDevices.firstIndex(where: { $0.token == device.token }) {
            guard local.pushDevices[index].environment != device.environment || local.pushDevices[index].name != device.name
                    || local.pushDevices[index].topic != device.topic else { return }
            local.pushDevices[index] = device
        } else {
            // A phone gets a new token after a reinstall: keep one entry per name and app.
            local.pushDevices.removeAll { $0.name == device.name && $0.topic == device.topic }
            local.pushDevices.append(device)
        }
        saveLocal()
    }

    /// A session needs the user: tell the phones that aren't connected (a connected phone shows
    /// its own alert). Unlike the Mac's banner, this isn't skipped when the session is on screen here.
    private func push(_ event: AttentionEvent) {
        guard model?.deck.settings.remoteHost == true, let credentials = local.apns, !local.pushDevices.isEmpty else { return }
        let connected = server?.connectedPushTokens ?? []
        let devices = local.pushDevices.filter { !connected.contains($0.token) }
        guard !devices.isEmpty else { return }
        let stamp = event.activity == .needsPermission ? model?.pendingPermissionStamp(event.sessionID)?.timeIntervalSince1970 : nil
        let payload = APNs.payload(title: event.title, subtitle: Self.hostName, body: event.body, sessionID: event.sessionID,
                                   permissionStamp: stamp, blocked: event.activity.isBlocked)
        send(payload, to: devices, credentials: credentials, collapseID: event.sessionID.uuidString)
    }

    func sendTestPush() {
        guard let credentials = local.apns else { return }
        let payload = APNs.payload(title: "ClaudeDeck", subtitle: Self.hostName, body: String(localized: "Notifications from this Mac work."),
                                   sessionID: UUID(), permissionStamp: nil, blocked: false)
        send(payload, to: local.pushDevices, credentials: credentials, collapseID: "test")
    }

    private func send(_ payload: Data, to devices: [PushDevice], credentials: APNsCredentials, collapseID: String) {
        // Apple wants the provider token reused for 20–60 minutes.
        let now = Date()
        if apnsToken == nil || now.timeIntervalSince(apnsToken!.issuedAt) > 50 * 60 {
            guard let value = try? APNs.token(credentials, issuedAt: now) else {
                pushStatus = String(localized: "The .p8 key can't be read.")
                return
            }
            apnsToken = (value, now)
        }
        guard let token = apnsToken?.value else { return }
        for device in devices {
            Task { @MainActor [weak self] in
                let result = await APNs.send(payload, to: device, token: token, collapseID: collapseID)
                guard let self else { return }
                switch result {
                case .sent:
                    self.pushStatus = String(localized: "Last notification sent to \(device.name).")
                case .unregistered:
                    self.removePushDevice(device.token)
                    self.pushStatus = String(localized: "\(device.name) no longer accepts notifications; removed.")
                case .failed(let reason):
                    if reason == "ExpiredProviderToken" || reason == "InvalidProviderToken" { self.apnsToken = nil }
                    self.pushStatus = String(localized: "Notification to \(device.name) failed: \(reason)")
                }
            }
        }
    }

    // MARK: Remote — live terminals

    /// A remote terminal tab appeared: stream that session into `sink`.
    func attachTerminal(_ id: UUID, sink: RemoteTerminalSink) {
        sinks[id] = sink
        terminalStates[id] = .waiting
        hostConnection?.openTerminal(id)
        hostConnection?.send(.markSeen(sessionID: id))
    }

    /// The tab went away (closed, or not shown any more).
    func detachTerminal(_ id: UUID, sink: RemoteTerminalSink) {
        guard sinks[id] === sink else { return }
        sinks[id] = nil
        terminalStates[id] = nil
        hostConnection?.closeTerminal(id)
    }

    func sendTerminalInput(_ id: UUID, data: Data) {
        counters["input", default: 0] += data.count
        guard terminalStates[id] == .live else { return }
        counters["inputSent", default: 0] += data.count
        hostConnection?.sendInput(id, data: data)
    }

    /// Visible text of the open remote terminals and of the host's watched sessions (DebugSnapshot).
    func debugScreens() -> [UUID: String] {
        var result: [UUID: String] = [:]
        for (id, sink) in sinks {
            if let container = sink as? RemoteTerminalContainer { result[id] = Self.debugText(TerminalCapture.screen(of: container.terminal, scrollback: 0)) }
        }
        for id in watched {
            if let view = model?.terminals.view(for: id) { result[id] = Self.debugText(TerminalCapture.screen(of: view, scrollback: 0)) }
        }
        return result
    }

    private static func debugText(_ screen: TermScreen) -> String {
        "\(screen.cols)x\(screen.rows)\n" + screen.visibleText
    }

    /// Title of a remote terminal tab: the session's name on the other Mac.
    @ObservationIgnored nonisolated(unsafe) static weak var current: RemoteController?

    static func tabTitle(_ id: UUID) -> String {
        current?.terminalNames[id] ?? String(localized: "Other Mac")
    }

    /// Ask the host for the screen again (the local grid was disturbed).
    func redrawTerminal(_ id: UUID) {
        guard sinks[id] != nil else { return }
        hostConnection?.openTerminal(id)
    }

    // MARK: Remote

    /// The host this Mac connects to: a pasted link first, then the chosen (or newest) host in iCloud Drive.
    var pairing: RemotePairing? { fixedPairing ?? passwordPairing(addresses: discoveredMacs) }

    /// A host known by its record (pasted link or iCloud Drive), its local-network address first.
    private var fixedPairing: RemotePairing? {
        guard var record = recordPairing else { return nil }
        let local = lanHosts.filter { $0.hostID == record.id }.map(\.address)
        record.addresses = local + record.addresses.filter { !local.contains($0) }
        return record
    }

    private var recordPairing: RemotePairing? {
        if let manual = local.manualPairing {
            // iCloud may have a newer record of the same host (new address or key).
            if let newer = availableHosts.first(where: { $0.id == manual.id }) { return newer }
            return manual
        }
        if let id = local.pairedHostID, let chosen = availableHosts.first(where: { $0.id == id }) { return chosen }
        return availableHosts.first
    }

    /// Starts / stops browsing the local network with the remote side.
    private func updateLANDiscovery(_ on: Bool) {
        if on, lanDiscovery == nil {
            let discovery = RemoteDiscovery()
            discovery.onChange = { [weak self] hosts in
                MainActor.assumeIsolated { self?.lanHostsChanged(hosts) }
            }
            discovery.start()
            lanDiscovery = discovery
        } else if !on, let discovery = lanDiscovery {
            discovery.stop()
            lanDiscovery = nil
            lanHosts = []
        }
    }

    private func lanHostsChanged(_ hosts: [DiscoveredHost]) {
        let others = hosts.filter { $0.hostID != local.hostID }
        guard others != lanHosts else { return }
        lanHosts = others
        // At home now: try the local path if we're not connected.
        if connection != .connected, model?.deck.settings.remoteClient == true { reconnect(force: true) }
    }

    /// The password's key and every candidate address, the last one that worked first.
    private func passwordPairing(addresses: [String]) -> RemotePairing? {
        guard let key = local.passwordKey else { return nil }
        var list: [String] = []
        // Local network first (at home), then the Tailscale address that worked last, then the rest.
        for address in lanHosts.map(\.address) + [local.lastHostAddress].compactMap({ $0 }) + addresses + (Self.allowLoopback ? ["127.0.0.1"] : [])
        where !list.contains(address) {
            list.append(address)
        }
        guard !list.isEmpty else { return nil }
        let name = snapshot?.hostName ?? String(localized: "Other Mac")
        return RemotePairing(id: Self.passwordHostID, hostName: name, addresses: list, port: Self.connectPort, key: key, updatedAt: Date())
    }

    func choose(host id: UUID) {
        local.pairedHostID = id
        local.manualPairing = nil
        saveLocal()
        reconnect(force: true)
    }

    /// Pasted `claudedeck://pair?…` link. False when it isn't one.
    @discardableResult
    func pair(link: String) -> Bool {
        guard let pairing = RemotePairing.parse(link: link), pairing.id != local.hostID else { return false }
        local.manualPairing = pairing
        local.pairedHostID = pairing.id
        saveLocal()
        reconnect(force: true)
        return true
    }

    func forgetPairing() {
        local.manualPairing = nil
        local.pairedHostID = nil
        saveLocal()
        reconnect(force: true)
    }

    private func pairingFolderChanged() {
        loadAvailableHosts()
        if model?.deck.settings.remoteHost == true { publishPairing() }
        // A changed key or address of our host: use it now.
        if let pairing = fixedPairing, let connectedPairing, connectedPairing.id != Self.passwordHostID, pairing.addresses != connectedPairing.addresses || pairing.key != connectedPairing.key || pairing.port != connectedPairing.port {
            reconnect(force: true)
        } else if connection == .noHost || isWaiting {
            reconnect(force: true)
        }
    }

    private var isWaiting: Bool {
        switch connection {
        case .retrying, .refused: true
        default: false
        }
    }

    private func loadAvailableHosts() {
        guard let folder = Self.pairingFolder else { availableHosts = []; return }
        let hosts = RemotePairingFolder.readAll(in: folder).filter { $0.id != local.hostID }
        if hosts != availableHosts { availableHosts = hosts }
    }

    private func networkChanged() {
        if model?.deck.settings.remoteHost == true { refreshAddresses() }
        let wrongPassword = connectedPairing?.id == Self.passwordHostID && { if case .refused = connection { true } else { false } }()
        if isWaiting, !wrongPassword { reconnect(force: true) }
    }

    private func reconnect(force: Bool) {
        guard model?.deck.settings.remoteClient == true else { return }
        if hostConnection != nil || discoveryTask != nil, !force { return }
        loadAvailableHosts()
        retryTask?.cancel()
        discoveryTask?.cancel()
        discoveryTask = nil
        hostConnection?.close()
        hostConnection = nil
        if force { retryDelay = 2 }
        if let fixed = fixedPairing {
            connect(fixed)
            return
        }
        guard local.passwordKey != nil else {
            connection = .noHost
            snapshot = nil
            return
        }
        // Password: ask Tailscale which Macs are online, then try them in turn.
        connection = .connecting
        discoveryTask = Task { @MainActor [weak self] in
            let status = await Task.detached { Tailscale.status() }.value
            guard let self, !Task.isCancelled else { return }
            self.discoveryTask = nil
            self.discoveredMacs = (status?.onlineMacs ?? []).filter { $0 != status?.dnsName }
            guard let pairing = self.passwordPairing(addresses: self.discoveredMacs) else {
                self.scheduleRetry(reason: String(localized: "No other Mac found on the local network or in Tailscale"), after: 15)
                return
            }
            self.connect(pairing)
        }
    }

    private func connect(_ pairing: RemotePairing) {
        connectedPairing = pairing
        connection = .connecting
        let next = RemoteHostConnection(pairing: pairing, deviceName: Self.hostName)
        next.onStateChange = { [weak self, weak next] state in
            MainActor.assumeIsolated {
                guard let self, let next, self.hostConnection === next else { return }
                self.connectionChanged(state)
            }
        }
        next.onSnapshot = { [weak self] snapshot in
            MainActor.assumeIsolated { self?.received(snapshot) }
        }
        next.onPermissionResult = { [weak self] id, _, applied in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.answering.remove(id)
                self.answerError = applied ? nil : String(localized: "That prompt was already answered or changed on the other Mac.")
            }
        }
        next.onTerminalStart = { [weak self] id, cols, rows, screen in
            MainActor.assumeIsolated {
                guard let self, let sink = self.sinks[id] else { return }
                self.terminalStates[id] = .live
                sink.start(cols: cols, rows: rows, screen: screen)
            }
        }
        next.onTerminalOutput = { [weak self] id, bytes in
            MainActor.assumeIsolated {
                self?.counters["received", default: 0] += bytes.count
                self?.sinks[id]?.feed(bytes)
            }
        }
        next.onTerminalEnded = { [weak self] id in
            MainActor.assumeIsolated {
                guard let self, self.sinks[id] != nil else { return }
                self.terminalStates[id] = .ended
            }
        }
        hostConnection = next
        next.start()
    }

    private func connectionChanged(_ state: RemoteHostConnection.State) {
        switch state {
        case .connecting:
            connection = .connecting
        case .connected:
            connection = .connected
            retryDelay = 2
            // Open tabs pick up where they were (fresh screen from the host).
            for id in sinks.keys {
                terminalStates[id] = .waiting
                hostConnection?.openTerminal(id)
            }
            // Remember the Tailscale address only: a Bonjour name is tried first anyway when present.
            if connectedPairing?.id == Self.passwordHostID, let address = hostConnection?.connectedAddress,
               RemoteBonjour.serviceName(of: address) == nil, address != local.lastHostAddress {
                local.lastHostAddress = address
                saveLocal()
            }
        case .disconnected(let reason):
            scheduleRetry(reason: reason, after: retryDelay)
            retryDelay = min(retryDelay * 2, 30)
        case .refused(let reason):
            hostConnection = nil
            connection = .refused(reason)
            answering = []
            // A wrong password stays wrong (and would count against the host's limit): wait for
            // a new one. A record-based key may still arrive through iCloud: retry slowly.
            if connectedPairing?.id == Self.passwordHostID {
                retryTask?.cancel()
            } else {
                scheduleRetry(reason: reason, after: 60, keepState: true)
            }
        }
    }

    private func scheduleRetry(reason: String, after delay: TimeInterval, keepState: Bool = false) {
        hostConnection = nil
        answering = []
        if !keepState { connection = .retrying(reason, at: Date().addingTimeInterval(delay)) }
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconnect(force: false)
        }
    }

    private func disconnect() {
        retryTask?.cancel()
        discoveryTask?.cancel()
        discoveryTask = nil
        hostConnection?.close()
        hostConnection = nil
        connectedPairing = nil
        connection = .off
        snapshot = nil
        answering = []
        model?.onCountsChanged?()
    }

    private func received(_ new: RemoteSnapshot) {
        let fresh = RemoteSnapshot.newAttention(from: snapshot, to: new)
        let cleared = (snapshot?.sessions ?? []).filter { old in
            old.attentionKey != nil && new.session(old.id)?.attentionKey != old.attentionKey
        }.map(\.id)
        snapshot = new
        for session in new.sessions where terminalNames[session.id] != session.name { terminalNames[session.id] = session.name }
        // A watched session that started again on the host: reopen its stream.
        for id in sinks.keys where terminalStates[id] == .ended && new.session(id)?.state != nil && new.session(id)?.state != .notStarted {
            terminalStates[id] = .waiting
            hostConnection?.openTerminal(id)
        }
        if !cleared.isEmpty { onAttentionCleared?(cleared) }
        // A prompt that went away was answered (here or on the host).
        answering = answering.filter { new.session($0)?.permissionStamp != nil }
        for session in fresh { onAttention?(session, new.hostName) }
        model?.onCountsChanged?()
    }

    /// Allow / Deny from the sidebar or a notification. False when not connected or not that prompt.
    @discardableResult
    func answer(_ id: UUID, stamp: Double?, approve: Bool) -> Bool {
        guard let stamp, let session = snapshot?.session(id), session.permissionStamp == stamp,
              let hostConnection, hostConnection.sendPermission(sessionID: id, stamp: stamp, approve: approve)
        else { return false }
        answering.insert(id)
        answerError = nil
        return true
    }

    /// Remote sessions that need the user (dock badge).
    var attentionCount: Int {
        guard connection == .connected else { return 0 }
        return snapshot?.sessions.filter(\.needsAttention).count ?? 0
    }
}

extension RemoteSession.State {
    init?(_ display: DisplayState) {
        switch display {
        case .notStarted: self = .notStarted
        case .starting: self = .starting
        case .shell: self = .shell
        case .activity(let activity):
            switch activity {
            case .running: self = .running
            case .needsPermission: self = .needsPermission
            case .needsAnswer: self = .needsAnswer
            case .idle: self = .idle
            case .ended: self = .ended
            }
        }
    }

    var display: DisplayState {
        switch self {
        case .notStarted: .notStarted
        case .starting: .starting
        case .shell: .shell
        case .running: .activity(.running)
        case .needsPermission: .activity(.needsPermission)
        case .needsAnswer: .activity(.needsAnswer)
        case .idle: .activity(.idle)
        case .ended: .activity(.ended)
        }
    }
}
