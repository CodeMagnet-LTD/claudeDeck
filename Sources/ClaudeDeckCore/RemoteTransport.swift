import Foundation
import Network

// TCP transport for remote mode (see RemoteProtocol.swift). Everything runs on the queue given
// at init (the app passes `.main`); callbacks arrive there too.

/// One framed TCP connection.
public final class RemoteChannel: @unchecked Sendable {
    public let connection: NWConnection
    private let queue: DispatchQueue
    private var decoder = RemoteFrameDecoder()
    private var closed = false

    public var onReady: (() -> Void)?
    public var onMessage: ((RemoteMessage) -> Void)?
    /// Frames of other kinds (reserved for terminal streaming).
    public var onFrame: ((RemoteFrame) -> Void)?
    /// Called once; `reason` is nil for a clean close by this side.
    public var onClose: ((String?) -> Void)?
    /// Last time anything arrived (keepalive).
    public private(set) var lastReceived = Date()

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onReady?()
            case .failed(let error): self.finish(error.localizedDescription)
            // A client connection waits (retries) when the host is unreachable; give up instead:
            // the caller tries the next address or reconnects later.
            case .waiting(let error): self.finish(error.localizedDescription)
            case .cancelled: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    public func send(_ message: RemoteMessage) {
        guard !closed, let frame = try? message.frame() else { return }
        send(frame)
    }

    public func send(_ frame: RemoteFrame) {
        guard !closed else { return }
        let data = frame.encoded()
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes -= data.count
            if let error { self.finish(error.localizedDescription) }
        })
    }

    /// Bytes handed to the connection and not yet sent (backpressure for terminal output).
    public private(set) var pendingBytes = 0

    /// Sends `refused` (if given) and closes once it is out.
    public func close(refusing reason: String? = nil) {
        guard !closed else { return }
        if let reason, let frame = try? RemoteMessage.refused(reason: reason).frame() {
            connection.send(content: frame.encoded(), completion: .contentProcessed { [weak self] _ in
                self?.finish(nil)
            })
        } else {
            finish(nil)
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.lastReceived = Date()
                do {
                    for frame in try self.decoder.append(data) {
                        // A message this version doesn't know (the other side is newer): skip it.
                        if frame.kind == RemoteFrameKind.message.rawValue {
                            if let message = try? RemoteMessage.decode(frame) { self.onMessage?(message) }
                        } else {
                            self.onFrame?(frame)
                        }
                        if self.closed { return }
                    }
                } catch {
                    self.finish(String(localized: "Malformed data from the other Mac"))
                    return
                }
            }
            if let error { self.finish(error.localizedDescription); return }
            if isComplete { self.finish(String(localized: "Connection closed by the other Mac")); return }
            self.receive()
        }
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let handler = onClose
        onClose = nil
        onReady = nil
        onMessage = nil
        onFrame = nil
        handler?(reason)
    }

    /// The peer's IP address, for incoming connections.
    public var remoteIP: String? {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        return Self.ipString(host)
    }

    static func ipString(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address):
            return address.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let address):
            var raw = in6_addr()
            withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: address.rawValue) }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }
}

// MARK: Host side

/// Listens for remotes, authenticates them and keeps them up to date.
public final class RemoteServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    private let port: UInt16
    private let queue: DispatchQueue
    private let key: () -> Data?
    private let acceptsPeer: (String) -> Bool
    private var listener: NWListener?
    private var pending: [ObjectIdentifier: PendingPeer] = [:]
    private var peers: [ObjectIdentifier: Peer] = [:]

    private struct Peer {
        var channel: RemoteChannel
        var name: String
        /// Sessions whose terminal this remote shows.
        var watching: Set<UUID> = []
        /// Watched sessions whose output was dropped (remote too slow): they get a fresh start.
        var resync: Set<UUID> = []
        /// A phone that registered for pushes (it gets in-app alerts while connected).
        var pushToken: Data?
    }

    /// Output stops being queued for a remote with this much unsent data.
    static let maxPendingBytes = 2 << 20
    private var keepalive: DispatchSourceTimer?
    private var failures: [String: [Date]] = [:]
    static let maxFailures = 10
    static let failureWindow: TimeInterval = 600

    public private(set) var state: State = .stopped { didSet { if state != oldValue { onStateChange?(state) } } }
    public var onStateChange: ((State) -> Void)?
    /// Names of the connected (authenticated) remotes.
    public var onPeersChanged: (([String]) -> Void)?
    /// A remote answered a prompt; return whether the keystroke was sent.
    public var onPermission: ((_ sessionID: UUID, _ stamp: Double, _ approve: Bool) -> Bool)?
    /// The latest snapshot; setting a different one sends it to every remote.
    public var snapshot: RemoteSnapshot? {
        didSet {
            guard let snapshot, snapshot != oldValue else { return }
            for peer in peers.values { peer.channel.send(.snapshot(snapshot)) }
        }
    }

    private struct PendingPeer {
        var channel: RemoteChannel
        var remoteNonce: Data?
        var hostNonce: Data?
        var name: String?
        var startedAt: Date
    }

    /// `acceptsPeer` filters by the peer's IP before any byte is read (Tailscale addresses only).
    public init(port: UInt16, queue: DispatchQueue = .main, key: @escaping () -> Data?, acceptsPeer: @escaping (String) -> Bool) {
        self.port = port
        self.queue = queue
        self.key = key
        self.acceptsPeer = acceptsPeer
    }

    public var peerNames: [String] { peers.values.map(\.name).sorted() }
    /// Push tokens of the phones connected right now.
    public var connectedPushTokens: Set<Data> { Set(peers.values.compactMap(\.pushToken)) }

    public struct TerminalStart: Sendable {
        public var cols: Int
        public var rows: Int
        public var screen: Data
        public init(cols: Int, rows: Int, screen: Data) {
            self.cols = cols
            self.rows = rows
            self.screen = screen
        }
    }

    /// A remote opened a session's terminal: its size and screen, or nil if it isn't running.
    public var onTerminalOpen: ((UUID) -> TerminalStart?)?
    /// Keystrokes from a remote.
    public var onTerminalInput: ((UUID, Data) -> Void)?
    /// A phone registered for push notifications.
    public var onRegisterPush: ((PushDevice) -> Void)?
    /// The set of sessions any remote watches changed (the host taps only those).
    public var onWatchedChanged: ((Set<UUID>) -> Void)?

    public var watchedSessions: Set<UUID> { peers.values.reduce(into: Set()) { $0.formUnion($1.watching) } }

    /// New output of a session, for every remote watching it.
    public func sendOutput(sessionID: UUID, bytes: Data) {
        let frame = RemoteTerminalOutput.frame(sessionID: sessionID, bytes: bytes)
        for (id, peer) in peers where peer.watching.contains(sessionID) {
            if peer.resync.contains(sessionID) { continue }
            if peer.channel.pendingBytes > Self.maxPendingBytes {
                peers[id]?.resync.insert(sessionID)
                continue
            }
            peer.channel.send(frame)
        }
        resyncDrained()
    }

    /// The terminal was resized (or must be redrawn): every watcher gets a fresh start.
    public func restartTerminal(sessionID: UUID) {
        for (id, peer) in peers where peer.watching.contains(sessionID) { sendStart(sessionID, to: id, channel: peer.channel) }
    }

    /// The session stopped: tell its watchers and forget them.
    public func terminalEnded(sessionID: UUID) {
        var changed = false
        for (id, peer) in peers where peer.watching.contains(sessionID) {
            peer.channel.send(.terminalEnded(sessionID: sessionID))
            peers[id]?.watching.remove(sessionID)
            peers[id]?.resync.remove(sessionID)
            changed = true
        }
        if changed { onWatchedChanged?(watchedSessions) }
    }

    private func sendStart(_ sessionID: UUID, to id: ObjectIdentifier, channel: RemoteChannel) {
        peers[id]?.resync.remove(sessionID)
        guard let start = onTerminalOpen?(sessionID) else {
            channel.send(.terminalEnded(sessionID: sessionID))
            peers[id]?.watching.remove(sessionID)
            return
        }
        channel.send(.terminalStart(sessionID: sessionID, cols: start.cols, rows: start.rows, screen: start.screen))
    }

    /// Remotes that caught up get a fresh screen instead of the output they missed.
    private func resyncDrained() {
        for (id, peer) in peers where !peer.resync.isEmpty && peer.channel.pendingBytes < Self.maxPendingBytes / 4 {
            for sessionID in peer.resync { sendStart(sessionID, to: id, channel: peer.channel) }
        }
    }
    /// Last connection dropped for not coming from an allowed address (diagnostics).
    public private(set) var lastRejectedPeer: String?

    public func start() {
        guard listener == nil else { return }
        // Port 0: the system picks one (tests); `state` reports it.
        guard let nwPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port) else { state = .failed("Invalid port \(port)"); return }
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        listener.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready: self.state = .listening(port: self.listener?.port?.rawValue ?? self.port)
            case .failed(let error):
                self.state = .failed(error.localizedDescription)
                self.stop(keepState: true)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        listener.start(queue: queue)
        startKeepalive()
    }

    public func stop() { stop(keepState: false) }

    private func stop(keepState: Bool) {
        listener?.cancel()
        listener = nil
        keepalive?.cancel()
        keepalive = nil
        for peer in pending.values { peer.channel.close() }
        for peer in peers.values { peer.channel.close() }
        pending = [:]
        peers = [:]
        onPeersChanged?([])
        if !keepState { state = .stopped }
    }

    /// Drops every remote (after a key change), keeps listening.
    public func disconnectAll(reason: String) {
        for peer in pending.values { peer.channel.close(refusing: reason) }
        for peer in peers.values { peer.channel.close(refusing: reason) }
    }

    private func accept(_ connection: NWConnection) {
        let channel = RemoteChannel(connection: connection, queue: queue)
        guard let ip = channel.remoteIP, acceptsPeer(ip) else {
            lastRejectedPeer = "\(connection.endpoint)"
            connection.cancel()
            return
        }
        // Wrong passwords: at most `maxFailures` per address in `failureWindow`.
        let now = Date()
        failures[ip] = failures[ip]?.filter { now.timeIntervalSince($0) < Self.failureWindow }
        if (failures[ip]?.count ?? 0) >= Self.maxFailures {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(channel)
        pending[id] = PendingPeer(channel: channel, startedAt: Date())
        channel.onMessage = { [weak self] message in self?.received(message, from: id) }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            self.pending[id] = nil
            if let peer = self.peers.removeValue(forKey: id) {
                self.onPeersChanged?(self.peerNames)
                if !peer.watching.isEmpty { self.onWatchedChanged?(self.watchedSessions) }
            }
        }
        channel.start()
    }

    private func received(_ message: RemoteMessage, from id: ObjectIdentifier) {
        if let peer = peers[id] {
            switch message {
            case .ping:
                peer.channel.send(.pong)
            case .permission(let sessionID, let stamp, let approve):
                let applied = onPermission?(sessionID, stamp, approve) ?? false
                peer.channel.send(.permissionResult(sessionID: sessionID, approve: approve, applied: applied))
            case .terminalOpen(let sessionID):
                let wasWatched = watchedSessions
                peers[id]?.watching.insert(sessionID)
                sendStart(sessionID, to: id, channel: peer.channel)
                if watchedSessions != wasWatched { onWatchedChanged?(watchedSessions) }
            case .terminalClose(let sessionID):
                let wasWatched = watchedSessions
                peers[id]?.watching.remove(sessionID)
                peers[id]?.resync.remove(sessionID)
                if watchedSessions != wasWatched { onWatchedChanged?(watchedSessions) }
            case .terminalInput(let sessionID, let data) where peer.watching.contains(sessionID):
                onTerminalInput?(sessionID, data)
            case .registerPush(let token, let topic, let environment, let deviceName) where !token.isEmpty && !topic.isEmpty:
                peers[id]?.pushToken = token
                onRegisterPush?(PushDevice(token: token, topic: topic, environment: environment == "production" ? "production" : "development", name: String(deviceName.prefix(80)), addedAt: Date()))
            default:
                break
            }
            return
        }
        guard var peer = pending[id] else { return }
        switch message {
        case .hello(let version, let nonce, let deviceName) where peer.remoteNonce == nil:
            guard version == RemoteMessage.protocolVersion else {
                peer.channel.close(refusing: String(localized: "The other Mac runs a different ClaudeDeck version. Update both Macs."))
                return
            }
            guard let key = key(), nonce.count >= 16 else {
                peer.channel.close(refusing: String(localized: "Remote access is off on this Mac."))
                return
            }
            let hostNonce = RemoteHandshake.makeNonce()
            peer.remoteNonce = nonce
            peer.hostNonce = hostNonce
            peer.name = String(deviceName.prefix(80))
            pending[id] = peer
            peer.channel.send(.challenge(nonce: hostNonce))
        case .auth(let proof):
            guard let key = key(), let remoteNonce = peer.remoteNonce, let hostNonce = peer.hostNonce,
                  RemoteHandshake.matches(proof, RemoteHandshake.remoteProof(key: key, remoteNonce: remoteNonce, hostNonce: hostNonce))
            else {
                if let ip = peer.channel.remoteIP { failures[ip, default: []].append(Date()) }
                peer.channel.close(refusing: String(localized: "The password or pairing key doesn't match."))
                return
            }
            pending[id] = nil
            peers[id] = Peer(channel: peer.channel, name: peer.name ?? "Mac")
            peer.channel.send(.welcome(proof: RemoteHandshake.hostProof(key: key, remoteNonce: remoteNonce, hostNonce: hostNonce)))
            if let snapshot { peer.channel.send(.snapshot(snapshot)) }
            onPeersChanged?(peerNames)
        default:
            peer.channel.close(refusing: String(localized: "Unexpected message during pairing."))
        }
    }

    /// Unfinished handshakes get 10 s; authenticated remotes ping every 20 s.
    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for peer in self.pending.values where now.timeIntervalSince(peer.startedAt) > 10 { peer.channel.close() }
            for peer in self.peers.values where now.timeIntervalSince(peer.channel.lastReceived) > 75 { peer.channel.close() }
            self.resyncDrained()
        }
        timer.resume()
        keepalive = timer
    }
}

// MARK: Remote side

/// The remote's connection to one host: tries each address in turn, authenticates, then
/// delivers snapshots. One attempt; the caller reconnects.
public final class RemoteHostConnection: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case connecting
        case connected(hostName: String?)
        /// Unreachable or dropped; worth retrying.
        case disconnected(String)
        /// The host said no (wrong key, old version); retrying won't help until something changes.
        case refused(String)
    }

    private let pairing: RemotePairing
    private let deviceName: String
    private let queue: DispatchQueue
    private var channel: RemoteChannel?
    private var addressIndex = 0
    private var nonce = Data()
    private var ping: DispatchSourceTimer?
    private var finished = false
    private var lastError: String?
    /// A ClaudeDeck answered but the keys didn't match (reported if no address works).
    private var refusal: String?
    /// The address that authenticated.
    public private(set) var connectedAddress: String?

    public private(set) var state: State = .connecting { didSet { if state != oldValue { onStateChange?(state) } } }
    public var onStateChange: ((State) -> Void)?
    public var onSnapshot: ((RemoteSnapshot) -> Void)?
    public var onPermissionResult: ((_ sessionID: UUID, _ approve: Bool, _ applied: Bool) -> Void)?
    public var onTerminalStart: ((_ sessionID: UUID, _ cols: Int, _ rows: Int, _ screen: Data) -> Void)?
    public var onTerminalOutput: ((_ sessionID: UUID, _ bytes: Data) -> Void)?
    public var onTerminalEnded: ((_ sessionID: UUID) -> Void)?

    /// Per address: connect + pairing must finish within this.
    public var handshakeTimeout: TimeInterval = 10

    public init(pairing: RemotePairing, deviceName: String, queue: DispatchQueue = .main) {
        self.pairing = pairing
        self.deviceName = deviceName
        self.queue = queue
    }

    public func start() {
        addressIndex = 0
        refusal = nil
        tryNextAddress()
    }

    public func close() {
        finished = true
        ping?.cancel()
        ping = nil
        channel?.close()
        channel = nil
    }

    @discardableResult
    public func openTerminal(_ sessionID: UUID) -> Bool { sendIfConnected(.terminalOpen(sessionID: sessionID)) }

    @discardableResult
    public func closeTerminal(_ sessionID: UUID) -> Bool { sendIfConnected(.terminalClose(sessionID: sessionID)) }

    @discardableResult
    public func sendInput(_ sessionID: UUID, data: Data) -> Bool { sendIfConnected(.terminalInput(sessionID: sessionID, data: data)) }

    /// Any message, while connected.
    @discardableResult
    public func send(_ message: RemoteMessage) -> Bool { sendIfConnected(message) }

    private func sendIfConnected(_ message: RemoteMessage) -> Bool {
        guard case .connected = state, let channel else { return false }
        channel.send(message)
        return true
    }

    public func sendPermission(sessionID: UUID, stamp: Double, approve: Bool) -> Bool {
        guard case .connected = state, let channel else { return false }
        channel.send(.permission(sessionID: sessionID, stamp: stamp, approve: approve))
        return true
    }

    private func tryNextAddress() {
        guard !finished else { return }
        guard addressIndex < pairing.addresses.count, let port = NWEndpoint.Port(rawValue: pairing.port) else {
            end(refusal.map { .refused($0) } ?? .disconnected(lastError ?? String(localized: "Couldn't reach the Mac")))
            return
        }
        let address = pairing.addresses[addressIndex]
        addressIndex += 1
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: NWParameters(tls: nil, tcp: tcp))
        let channel = RemoteChannel(connection: connection, queue: queue)
        self.channel = channel
        var authenticated = false
        var sentHostNonce: Data?
        channel.onReady = { [weak self] in
            guard let self else { return }
            self.nonce = RemoteHandshake.makeNonce()
            channel.send(.hello(version: RemoteMessage.protocolVersion, nonce: self.nonce, deviceName: self.deviceName))
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel else { return }
            switch message {
            case .challenge(let hostNonce) where !authenticated && sentHostNonce == nil:
                sentHostNonce = hostNonce
                channel.send(.auth(proof: RemoteHandshake.remoteProof(key: self.pairing.key, remoteNonce: self.nonce, hostNonce: hostNonce)))
            case .welcome(let proof) where !authenticated:
                guard let hostNonce = sentHostNonce,
                      RemoteHandshake.matches(proof, RemoteHandshake.hostProof(key: self.pairing.key, remoteNonce: self.nonce, hostNonce: hostNonce))
                else {
                    // Not the Mac it claims to be: try the next address.
                    self.refusal = String(localized: "The other Mac has a different password or pairing key.")
                    channel.close()
                    return
                }
                authenticated = true
                self.connectedAddress = address
                self.state = .connected(hostName: nil)
                self.startPing()
            case .snapshot(let snapshot) where authenticated:
                self.state = .connected(hostName: snapshot.hostName)
                self.onSnapshot?(snapshot)
            case .permissionResult(let id, let approve, let applied) where authenticated:
                self.onPermissionResult?(id, approve, applied)
            case .terminalStart(let id, let cols, let rows, let screen) where authenticated:
                self.onTerminalStart?(id, cols, rows, screen)
            case .terminalEnded(let id) where authenticated:
                self.onTerminalEnded?(id)
            case .refused(let reason):
                if authenticated {
                    self.end(.refused(reason))
                } else {
                    self.refusal = reason
                    channel.close()
                }
            default:
                break
            }
        }
        channel.onFrame = { [weak self] frame in
            guard let self, authenticated, let output = RemoteTerminalOutput.decode(frame) else { return }
            self.onTerminalOutput?(output.sessionID, output.bytes)
        }
        channel.onClose = { [weak self] reason in
            guard let self, !self.finished else { return }
            if authenticated {
                self.end(.disconnected(reason ?? String(localized: "Connection closed")))
            } else {
                if let reason { self.lastError = reason }
                self.tryNextAddress()
            }
        }
        state = .connecting
        channel.start()
        // An address can accept TCP and never answer (a stale route, a proxy): move on.
        queue.asyncAfter(deadline: .now() + handshakeTimeout) { [weak self, weak channel] in
            guard let self, let channel, self.channel === channel, !authenticated, !self.finished else { return }
            self.lastError = String(localized: "The other Mac didn't answer")
            channel.close()
        }
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self, let channel = self.channel else { return }
            if Date().timeIntervalSince(channel.lastReceived) > 50 {
                self.end(.disconnected(String(localized: "The other Mac stopped answering")))
                return
            }
            channel.send(.ping)
        }
        timer.resume()
        ping = timer
    }

    private func end(_ final: State) {
        guard !finished else { return }
        state = final
        close()
    }
}
