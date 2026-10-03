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

    // Live terminals (RemoteTerminalView).
    enum TerminalState: Equatable { case waiting, live, ended }
    private(set) var terminalStates: [UUID: TerminalState] = [:]
    @ObservationIgnored private var sinks: [UUID: RemoteTerminalSink] = [:]

    @ObservationIgnored private var hostConnection: RemoteHostConnection?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: TimeInterval = 2
    @ObservationIgnored private var isActive = false
    /// Waiting `answerAndWait` calls (notification actions), by session.
    @ObservationIgnored private var answerWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// Called after connecting (push registration, see PushRegistration).
    @ObservationIgnored var onConnected: (() -> Void)?
    /// Sessions pushed on the navigation stack (notification taps open a session).
    var path: [UUID] = []

    static let deviceName = UIDevice.current.name

    init() {
        let saved = PairingKeychain.load()
        pairing = saved
        connection = saved == nil ? .unpaired : .paused
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
    func pair(host: String, password: String, port: UInt16 = RemotePairing.defaultPort) {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairing = RemotePairing(
            id: UUID(), hostName: address, addresses: [address], port: port,
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
        let next = RemoteHostConnection(pairing: pairing, deviceName: Self.deviceName)
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
        next.onTerminalStart = { [weak self] id, cols, rows, screen in
            MainActor.assumeIsolated {
                guard let self, let sink = self.sinks[id] else { return }
                self.terminalStates[id] = .live
                sink.start(cols: cols, rows: rows, screen: screen)
            }
        }
        next.onTerminalOutput = { [weak self] id, bytes in
            MainActor.assumeIsolated { self?.sinks[id]?.feed(bytes) }
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
            }
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
        let fresh = RemoteSnapshot.newAttention(from: snapshot, to: new)
        snapshot = new
        answering = answering.filter { new.session($0)?.permissionStamp != nil }
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

    /// For a notification action: connect if needed, answer, wait for the Mac's result.
    func answerAndWait(_ id: UUID, stamp: Double, approve: Bool, timeout: TimeInterval = 20) async -> Bool {
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

    // MARK: Terminals

    func attachTerminal(_ id: UUID, sink: RemoteTerminalSink) {
        sinks[id] = sink
        terminalStates[id] = .waiting
        hostConnection?.openTerminal(id)
    }

    func detachTerminal(_ id: UUID, sink: RemoteTerminalSink) {
        guard sinks[id] === sink else { return }
        sinks[id] = nil
        terminalStates[id] = nil
        hostConnection?.closeTerminal(id)
    }

    func sendTerminalInput(_ id: UUID, data: Data) {
        guard terminalStates[id] == .live else { return }
        hostConnection?.sendInput(id, data: data)
    }

    func redrawTerminal(_ id: UUID) {
        guard sinks[id] != nil else { return }
        hostConnection?.openTerminal(id)
    }

    /// Open terminal views (DebugHooks).
    func debugTerminals() -> [UUID: RemoteTerminalUIView] {
        sinks.compactMapValues { $0 as? RemoteTerminalUIView }
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
