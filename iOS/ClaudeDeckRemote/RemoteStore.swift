import Foundation
import Observation
import UIKit
import UserNotifications

/// The phone's side of remote mode: one paired Mac, connected while the app is in front.
/// iOS closes sockets in the background; notifications then come from the Mac through APNs.
@MainActor
@Observable
final class RemoteStore {
    enum Connection: Equatable {
        case unpaired
        /// The app isn't in front.
        case paused
        case connecting
        case connected
        case retrying(String, at: Date)
        case refused(String)
    }

    private(set) var pairing: RemotePairing?
    private(set) var connection: Connection
    private(set) var snapshot: RemoteSnapshot?
    /// Prompts answered from here, waiting for the Mac's result.
    private(set) var answering: Set<UUID> = []
    var answerError: String?

    // Conversations (ConversationView).
    struct Conversation: Equatable {
        var entries: [ChatEntry] = []
        var hasMoreBefore = false
        var loaded = false
        var loadingOlder = false
    }
    private(set) var conversations: [UUID: Conversation] = [:]
    /// Conversations on screen: kept current and marked seen.
    /// Counted: the same session can be open in two windows.
    @ObservationIgnored private var openConversations: [UUID: Int] = [:]
    @ObservationIgnored private var conversationTimer: Timer?

    // Live terminals (RemoteTerminalView).
    enum TerminalState: Equatable { case waiting, live, ended }
    private(set) var terminalStates: [UUID: TerminalState] = [:]
    /// Several per session when it's open in more than one window.
    @ObservationIgnored private var sinks: [UUID: [RemoteTerminalSink]] = [:]

    @ObservationIgnored private var hostConnection: RemoteHostConnection?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: TimeInterval = 2
    @ObservationIgnored private var isActive = false
    /// The app is on screen (scene phase), unlike `isActive`, which a notification action also sets.
    @ObservationIgnored private var inForeground = false
    /// Waiting `answerAndWait` calls (notification actions), by session.
    @ObservationIgnored private var answerWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// Called after connecting (push registration, see PushRegistration).
    @ObservationIgnored var onConnected: (() -> Void)?
    /// Messages with files on their way, by session (sending a few MB takes a moment).
    private(set) var sendingFiles: Set<UUID> = []
    /// Why the last message with files didn't go in.
    var promptError: String?

    // Windows (iPad): each keeps its own selection; the store only routes "show this session".
    struct OpenRequest: Equatable {
        let session: UUID
        /// The window that should show it; nil: whichever window takes it first.
        let scene: UUID?
        let token = UUID()
    }
    var openRequest: OpenRequest?
    /// Debug hooks: open a session in a new window.
    var newWindowRequest: OpenRequest?
    /// Open windows and what each shows.
    @ObservationIgnored private(set) var scenes: [UUID: UUID?] = [:]
    /// The window last brought to the front: notification taps open there.
    @ObservationIgnored private var activeScene: UUID?
    /// The window that last started a session: it shows it once the Mac has it.
    @ObservationIgnored private var startingScene: UUID?

    static let deviceName = UIDevice.current.name

    var connectedVia: String? { hostConnection?.connectedAddress }

    /// ClaudeDeck Macs advertising on this network (Bonjour).
    private(set) var lanHosts: [DiscoveredHost] = []
    @ObservationIgnored private let discovery = RemoteDiscovery()

    init() {
        let saved = PairingKeychain.load()
        pairing = saved
        connection = saved == nil ? .unpaired : .paused
        discovery.onChange = { [weak self] hosts in
            MainActor.assumeIsolated { self?.lanHostsChanged(hosts) }
        }
    }

    /// The pairing screen lists Macs on this network before anything is paired.
    func startLANDiscovery() { discovery.start() }

    private func lanHostsChanged(_ hosts: [DiscoveredHost]) {
        lanHosts = hosts
        // Just got home: go local if we aren't connected.
        if isActive, pairing != nil, connection != .connected, connection != .connecting, !isRefused { reconnect() }
    }

    private var isRefused: Bool { if case .refused = connection { true } else { false } }

    /// The paired Mac's addresses for this attempt: its local-network name first when it's
    /// advertising here, then the stored ones (Tailscale).
    private func effectivePairing(_ pairing: RemotePairing) -> RemotePairing {
        var copy = pairing
        let local = lanHosts.filter { $0.hostID == pairing.id }.map(\.address)
        copy.addresses = local + pairing.addresses.filter { !local.contains($0) }
        return copy
    }

    /// The snapshot says who the Mac is and how to reach it away from home: keep that.
    private func learn(from snapshot: RemoteSnapshot) {
        guard var stored = pairing else { return }
        let before = stored
        if let id = snapshot.hostID { stored.id = id }
        stored.hostName = snapshot.hostName
        if let remote = snapshot.addresses, !remote.isEmpty {
            let bonjour = stored.addresses.filter { RemoteBonjour.serviceName(of: $0) != nil }
            let typed = stored.addresses.filter { RemoteBonjour.serviceName(of: $0) == nil && !remote.contains($0) }
            stored.addresses = bonjour + remote + typed
        }
        guard stored != before else { return }
        stored.updatedAt = Date()
        PairingKeychain.save(stored)
        pairing = stored
    }

    // MARK: Pairing

    /// `claudedeck://pair?…` from the QR code, a tapped link or the clipboard.
    @discardableResult
    func pair(link: String) -> Bool {
        guard let pairing = RemotePairing.parse(link: link) else { return false }
        use(pairing)
        return true
    }

    /// The Mac's Tailscale name (or IP) and the password set on it.
    /// A Mac found on this network and the password set on it.
    func pair(lanHost: DiscoveredHost, password: String) {
        var pairing = RemotePairing(
            id: lanHost.hostID ?? UUID(), hostName: lanHost.name, addresses: [lanHost.address], port: RemotePairing.defaultPort,
            key: RemoteHandshake.key(fromPassword: password), updatedAt: Date()
        )
        pairing.hostName = lanHost.name
        use(pairing)
    }

    func pair(host: String, password: String, port: UInt16 = RemotePairing.defaultPort) {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairing = RemotePairing(
            id: UUID(), hostName: RemoteBonjour.serviceName(of: address) ?? address, addresses: [address], port: port,
            key: RemoteHandshake.key(fromPassword: password), updatedAt: Date()
        )
        use(pairing)
    }

    private func use(_ pairing: RemotePairing) {
        PairingKeychain.save(pairing)
        self.pairing = pairing
        snapshot = nil
        retryDelay = 2
        reconnect()
    }

    func forget() {
        PairingKeychain.delete()
        close()
        pairing = nil
        snapshot = nil
        connection = .unpaired
    }

    // MARK: Lifecycle

    /// Scene phase: connect in front, let go in the background.
    func setActive(_ active: Bool) {
        inForeground = active
        if active { discovery.start() } else { discovery.stop() }
        // After a refusal (wrong password) only a new pairing retries: each attempt counts
        // against the Mac's limit.
        if active, case .refused = connection { isActive = true; return }
        guard active != isActive || (active && connection != .connected && hostConnection == nil) else { return }
        isActive = active
        if active {
            retryDelay = 2
            reconnect()
        } else {
            close()
            if pairing != nil { connection = .paused }
        }
    }

    func reconnect() {
        guard let pairing else { connection = .unpaired; return }
        retryTask?.cancel()
        hostConnection?.close()
        connection = .connecting
        let next = RemoteHostConnection(pairing: effectivePairing(pairing), deviceName: Self.deviceName)
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
                self.answerWaiters.removeValue(forKey: id)?.resume(returning: applied)
            }
        }
        next.onSessionStarted = { [weak self] id in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.open(id, in: self.startingScene)
            }
        }
        next.onPromptResult = { [weak self] id, error in
            MainActor.assumeIsolated {
                guard let self, self.sendingFiles.remove(id) != nil else { return }
                self.promptError = error
            }
        }
        next.onFileReply = { [weak self] message in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch message {
                case .directory(let projectID, let path, let entries, let error):
                    self.directories[Self.fileKey(projectID, path)] = DirectoryState(entries: entries, error: error)
                case .file(let projectID, let path, let text, let size, let error):
                    self.files[Self.fileKey(projectID, path)] = FileState(text: text, size: size, error: error)
                default: break
                }
            }
        }
        next.onPastConversations = { [weak self] projectID, items in
            MainActor.assumeIsolated { self?.pastConversations[projectID] = items }
        }
        next.onHistory = { [weak self] id, page in
            MainActor.assumeIsolated { self?.received(page, for: id) }
        }
        next.onTerminalStart = { [weak self] id, cols, rows, screen in
            MainActor.assumeIsolated {
                guard let self, let sinks = self.sinks[id] else { return }
                self.terminalStates[id] = .live
                for sink in sinks { sink.start(cols: cols, rows: rows, screen: screen) }
            }
        }
        next.onTerminalOutput = { [weak self] id, bytes in
            MainActor.assumeIsolated { self?.sinks[id]?.forEach { $0.feed(bytes) } }
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

    private func close() {
        retryTask?.cancel()
        hostConnection?.close()
        hostConnection = nil
        answering = []
        for waiter in answerWaiters.values { waiter.resume(returning: false) }
        answerWaiters = [:]
    }

    private func connectionChanged(_ state: RemoteHostConnection.State) {
        switch state {
        case .connecting:
            connection = .connecting
        case .connected:
            connection = .connected
            retryDelay = 2
            for id in sinks.keys {
                terminalStates[id] = .waiting
                hostConnection?.openTerminal(id)
                if let grid = fitGrids[id] { hostConnection?.send(.terminalFit(sessionID: id, cols: grid.0, rows: grid.1)) }
            }
            for id in openConversations.keys { requestLatest(id) }
            onConnected?()
        case .disconnected(let reason):
            hostConnection = nil
            answering = []
            guard isActive else { connection = .paused; return }
            connection = .retrying(reason, at: Date().addingTimeInterval(retryDelay))
            scheduleRetry(after: retryDelay)
            retryDelay = min(retryDelay * 2, 30)
        case .refused(let reason):
            hostConnection = nil
            answering = []
            connection = .refused(reason)
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.isActive else { return }
            self.reconnect()
        }
    }

    private func received(_ new: RemoteSnapshot) {
        let old = snapshot
        let fresh = RemoteSnapshot.newAttention(from: snapshot, to: new)
        snapshot = new
        learn(from: new)
        for id in openConversations.keys {
            guard let session = new.session(id) else { continue }
            // Watching it finish here counts as seeing it.
            if session.state == .idle, session.unseen { _ = send(.markSeen(sessionID: id)) }
            if old?.session(id) != session { requestNewer(id) }
        }
        answering = answering.filter { new.session($0)?.permissionStamp != nil || new.session($0)?.state == .needsAnswer }
        for session in fresh { LocalAlerts.post(session, hostName: new.hostName) }
    }

    // MARK: Answers

    @discardableResult
    func answer(_ id: UUID, stamp: Double?, approve: Bool) -> Bool {
        guard let stamp, let hostConnection, hostConnection.sendPermission(sessionID: id, stamp: stamp, approve: approve) else { return false }
        answering.insert(id)
        answerError = nil
        return true
    }

    /// Answers Claude's question (one answer per question); the Mac types it into the prompt.
    @discardableResult
    func answerQuestion(_ id: UUID, toolUseID: String, answers: [QuestionAnswer]) -> Bool {
        guard send(.answerQuestion(sessionID: id, toolUseID: toolUseID, answers: answers)) else { return false }
        answering.insert(id)
        answerError = nil
        // A Mac without question support never replies.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.answering.remove(id) != nil else { return }
            self.answerError = String(localized: "The other Mac didn't answer. Update ClaudeDeck on it, or answer in the terminal.")
        }
        return true
    }

    /// For a notification action: connect if needed, answer, wait for the Mac's result.
    func answerAndWait(_ id: UUID, stamp: Double, approve: Bool, timeout: TimeInterval = 20) async -> Bool {
        let applied = await answerConnecting(id, stamp: stamp, approve: approve, timeout: timeout)
        // Answered from the lock screen: let go now. A socket left open until iOS suspends us would
        // make the Mac think this phone is connected and skip its next push.
        if !inForeground {
            close()
            isActive = false
            if pairing != nil, connection == .connected || connection == .connecting { connection = .paused }
        }
        return applied
    }

    private func answerConnecting(_ id: UUID, stamp: Double, approve: Bool, timeout: TimeInterval) async -> Bool {
        if connection != .connected {
            isActive = true
            reconnect()
            let deadline = Date().addingTimeInterval(timeout / 2)
            while connection != .connected, Date() < deadline {
                if case .refused = connection { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let hostConnection, hostConnection.sendPermission(sessionID: id, stamp: stamp, approve: approve) else { return false }
        return await withCheckedContinuation { continuation in
            answerWaiters[id]?.resume(returning: false)
            answerWaiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout / 2))
                self?.answerWaiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    // MARK: Sessions

    var projects: [RemoteProject] { snapshot?.projects ?? [] }

    /// A new Claude session in a project on the Mac; it opens here once started.
    func startSession(in projectID: UUID, prompt: String, from scene: UUID? = nil) {
        startingScene = scene
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = send(.startSession(projectID: projectID, prompt: text.isEmpty ? nil : text))
    }

    func stopSession(_ id: UUID) { _ = send(.stopSession(sessionID: id)) }

    func startShell(in projectID: UUID, command: String, from scene: UUID? = nil) {
        startingScene = scene
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = send(.startShell(projectID: projectID, command: text.isEmpty ? nil : text))
    }

    /// The project's past conversations, by project (filled by the Mac's answer).
    private(set) var pastConversations: [UUID: [RemotePastConversation]] = [:]

    func loadPastConversations(_ projectID: UUID) {
        _ = send(.pastConversationsRequest(projectID: projectID))
    }

    func resumeConversation(_ conversationID: String, in projectID: UUID, from scene: UUID? = nil) {
        startingScene = scene
        _ = send(.resumeConversation(projectID: projectID, conversationID: conversationID))
    }

    // MARK: Files (FileBrowser)

    struct DirectoryState: Equatable { var entries: [RemoteFileEntry]; var error: String? }
    struct FileState: Equatable { var text: String?; var size: Int; var error: String? }
    private(set) var directories: [String: DirectoryState] = [:]
    private(set) var files: [String: FileState] = [:]

    static func fileKey(_ projectID: UUID, _ path: String) -> String { "\(projectID.uuidString)/\(path)" }

    func listDirectory(_ projectID: UUID, path: String) {
        _ = send(.listDirectory(projectID: projectID, path: path))
    }

    func readFile(_ projectID: UUID, path: String) {
        _ = send(.readFile(projectID: projectID, path: path))
    }

    /// Esc in a working session.
    func interrupt(_ id: UUID) { _ = send(.interrupt(sessionID: id)) }

    /// Clears "your turn" without opening the session.
    func markSeen(_ id: UUID) { _ = send(.markSeen(sessionID: id)) }

    func resumeSession(_ id: UUID, from scene: UUID? = nil) {
        guard send(.resumeSession(sessionID: id)) else { return }
        open(id, in: scene)
    }

    // MARK: Windows

    /// Shows a session in a window (default: the one last in front).
    func open(_ id: UUID, in scene: UUID? = nil) {
        let target = scene ?? activeScene
        openRequest = OpenRequest(session: id, scene: target.flatMap { scenes[$0] != nil ? $0 : nil })
    }

    func sceneAppeared(_ scene: UUID) { if scenes[scene] == nil { scenes[scene] = .some(nil) } }
    func sceneActivated(_ scene: UUID) { activeScene = scene }
    func sceneSelected(_ scene: UUID, session: UUID?) { scenes[scene] = .some(session) }

    func sceneDisappeared(_ scene: UUID) {
        scenes[scene] = nil
        if activeScene == scene { activeScene = nil }
        if startingScene == scene { startingScene = nil }
    }

    // MARK: Conversations

    func openConversation(_ id: UUID) {
        openConversations[id, default: 0] += 1
        _ = send(.markSeen(sessionID: id))
        requestLatest(id)
        // Tool results and long answers grow without a state change: check every few seconds.
        if conversationTimer == nil {
            conversationTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for id in self.openConversations.keys { self.requestNewer(id) }
                }
            }
        }
    }

    func closeConversation(_ id: UUID) {
        guard let count = openConversations[id] else { return }
        openConversations[id] = count > 1 ? count - 1 : nil
        if openConversations.isEmpty {
            conversationTimer?.invalidate()
            conversationTimer = nil
        }
    }

    private func requestLatest(_ id: UUID) {
        _ = send(.historyRequest(sessionID: id, before: nil, after: nil, limit: 80))
    }

    /// New entries since the last complete one (a tool call without its result yet comes again).
    private func requestNewer(_ id: UUID) {
        guard let entries = conversations[id]?.entries, conversations[id]?.loaded == true else { requestLatest(id); return }
        guard let anchor = entries.last(where: { $0.kind != .tool || $0.result != nil }) else { requestLatest(id); return }
        _ = send(.historyRequest(sessionID: id, before: nil, after: anchor.id, limit: 120))
    }

    func loadOlder(_ id: UUID) {
        guard var conversation = conversations[id], conversation.hasMoreBefore, !conversation.loadingOlder,
              let first = conversation.entries.first else { return }
        conversation.loadingOlder = true
        conversations[id] = conversation
        _ = send(.historyRequest(sessionID: id, before: first.id, after: nil, limit: 80))
    }

    private func received(_ page: ChatPage, for id: UUID) {
        var conversation = conversations[id] ?? Conversation()
        if page.reset {
            conversation.entries = page.entries
            conversation.hasMoreBefore = page.hasMoreBefore
        } else if page.before != nil {
            let known = Set(conversation.entries.map(\.id))
            conversation.entries = page.entries.filter { !known.contains($0.id) } + conversation.entries
            conversation.hasMoreBefore = page.hasMoreBefore
            conversation.loadingOlder = false
        } else {
            for entry in page.entries {
                if let index = conversation.entries.firstIndex(where: { $0.id == entry.id }) {
                    conversation.entries[index] = entry
                } else {
                    conversation.entries.append(entry)
                }
            }
        }
        conversation.loaded = true
        if conversations[id] != conversation { conversations[id] = conversation }
    }

    /// Typed into the session on the Mac (not while it shows a prompt).
    @discardableResult
    func sendPrompt(_ id: UUID, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, snapshot?.session(id)?.state.isBlocked == false else { return false }
        guard send(.sendPrompt(sessionID: id, text: trimmed)) else { return false }
        // The answer shows up through the conversation updates.
        Task { @MainActor [weak self] in
            for _ in 0..<4 {
                try? await Task.sleep(for: .seconds(1))
                self?.requestNewer(id)
            }
        }
        return true
    }

    /// A message with photos / files: the Mac saves them and puts them in with the text.
    @discardableResult
    func sendPrompt(_ id: UUID, text: String, files: [RemoteUpload]) -> Bool {
        guard !files.isEmpty else { return sendPrompt(id, text: text) }
        guard snapshot?.session(id)?.state.isBlocked == false, !sendingFiles.contains(id) else { return false }
        guard send(.sendPromptWithFiles(sessionID: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines), files: files)) else { return false }
        sendingFiles.insert(id)
        promptError = nil
        Task { @MainActor [weak self] in
            // An older Mac skips the message without answering.
            try? await Task.sleep(for: .seconds(60))
            guard let self, self.sendingFiles.remove(id) != nil else { return }
            self.promptError = String(localized: "The other Mac didn't answer. Update ClaudeDeck on it.")
        }
        Task { @MainActor [weak self] in
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(1.5))
                self?.requestNewer(id)
            }
        }
        return true
    }

    // MARK: Terminals

    func attachTerminal(_ id: UUID, sink: RemoteTerminalSink) {
        // Opening again gives every view of it a fresh screen, the new one included.
        sinks[id, default: []].append(sink)
        if terminalStates[id] != .live { terminalStates[id] = .waiting }
        hostConnection?.openTerminal(id)
        if let grid = fitGrids[id] { hostConnection?.send(.terminalFit(sessionID: id, cols: grid.0, rows: grid.1)) }
    }

    func detachTerminal(_ id: UUID, sink: RemoteTerminalSink) {
        guard let views = sinks[id], views.contains(where: { $0 === sink }) else { return }
        let rest = views.filter { $0 !== sink }
        guard rest.isEmpty else {
            sinks[id] = rest
            return
        }
        sinks[id] = nil
        terminalStates[id] = nil
        hostConnection?.closeTerminal(id)
    }

    func sendTerminalInput(_ id: UUID, data: Data) {
        guard terminalStates[id] == .live else { return }
        hostConnection?.sendInput(id, data: data)
    }

    /// Fit mode: size the Mac's terminal to this screen (0 cols gives it back). Re-sent after reconnects.
    func fitTerminal(_ id: UUID, cols: Int, rows: Int) {
        // Closing one of several views keeps the size the others fit.
        if cols == 0, (sinks[id]?.count ?? 0) > 1 { return }
        if cols == 0 { fitGrids[id] = nil } else { fitGrids[id] = (cols, rows) }
        hostConnection?.send(.terminalFit(sessionID: id, cols: cols, rows: rows))
    }
    @ObservationIgnored private var fitGrids: [UUID: (Int, Int)] = [:]

    func redrawTerminal(_ id: UUID) {
        guard sinks[id] != nil else { return }
        hostConnection?.openTerminal(id)
    }

    /// Open terminal views (DebugHooks).
    func debugTerminals() -> [UUID: RemoteTerminalUIView] {
        sinks.compactMapValues { $0.first as? RemoteTerminalUIView }
    }

    /// Sends a message only while connected (push registration).
    func send(_ message: RemoteMessage) -> Bool {
        hostConnection?.send(message) ?? false
    }
}

/// Receives one session's stream.
@MainActor
protocol RemoteTerminalSink: AnyObject {
    func start(cols: Int, rows: Int, screen: Data)
    func feed(_ bytes: Data)
}

/// Banners while the app is open (the Mac's pushes cover the background).
enum LocalAlerts {
    static let permissionCategory = "permission"
    static let approveAction = "approve"
    static let denyAction = "deny"

    static func registerCategories() {
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(
            identifier: permissionCategory,
            actions: [
                UNNotificationAction(identifier: approveAction, title: String(localized: "Allow"), options: [.authenticationRequired]),
                UNNotificationAction(identifier: denyAction, title: String(localized: "Deny"), options: [.destructive, .authenticationRequired]),
            ],
            intentIdentifiers: []
        )])
    }

    static func post(_ session: RemoteSession, hostName: String) {
        let content = UNMutableNotificationContent()
        content.title = session.project.isEmpty || session.name.hasPrefix(session.project) ? session.name : "\(session.name) — \(session.project)"
        content.subtitle = hostName
        content.body = SessionStyle.label(session.state) + (session.detail.map { ": \($0)" } ?? "")
        content.sound = session.state.isBlocked ? .default : nil
        content.userInfo = ["sessionID": session.id.uuidString]
        if let stamp = session.permissionStamp {
            content.categoryIdentifier = permissionCategory
            content.userInfo["stamp"] = String(stamp)
        }
        content.threadIdentifier = session.id.uuidString
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: session.id.uuidString, content: content, trigger: nil))
    }
}
