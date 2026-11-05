import Foundation
import Network

/// Loopback-only HTTP listener for the kod checker API. Separate from the Tailscale remote
/// listener (`RemoteServer`, port 47821): this one binds 127.0.0.1 and speaks one HTTP request
/// per connection.
final class KodBridgeServer: @unchecked Sendable {
    enum State: Sendable {
        case listening(UInt16)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "co.codemagnet.ClaudeDeck.kod-bridge")
    private let lock = NSLock()
    private var listener: NWListener?
    private var generation = 0
    private var handler: (@Sendable (KodHTTPRequest) async -> KodHTTPResponse)?
    var onState: (@Sendable (State) -> Void)?

    func start(port: UInt16, handler: @escaping @Sendable (KodHTTPRequest) async -> KodHTTPResponse) {
        let token = retire()
        lock.lock()
        self.handler = handler
        lock.unlock()

        let tcp = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        // 127.0.0.1 only. The Tailscale remote listener is a different port and a different socket.
        parameters.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onState?(.failed("Invalid port \(port)"))
            return
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(IPv4Address.loopback), port: nwPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            onState?(.failed(error.localizedDescription))
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.isCurrent(token) else { return }
            switch state {
            case .ready:
                let bound = listener.port?.rawValue ?? port
                self.onState?(.listening(bound))
            case .failed(let error):
                self.onState?(.failed(error.localizedDescription))
                self.retire()
            case .cancelled:
                break
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.isCurrent(token) else { connection.cancel(); return }
            self.serve(connection)
        }
        lock.lock()
        guard generation == token else {
            lock.unlock()
            listener.cancel()
            return
        }
        self.listener = listener
        lock.unlock()
        listener.start(queue: queue)
    }

    func stop() {
        // No `.stopped` callback: the caller already knows it asked to stop, and a late
        // callback would clear `listening` after a newer listener had become ready.
        retire()
    }

    /// Drops the current listener. Callbacks captured for the previous generation do nothing.
    private func retire() -> Int {
        lock.lock()
        generation += 1
        let token = generation
        let listener = listener
        self.listener = nil
        lock.unlock()
        listener?.cancel()
        return token
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        let current = generation
        lock.unlock()
        return current == token
    }

    private func serve(_ connection: NWConnection) {
        let box = ConnectionBox(connection)
        box.start(queue: queue) { [weak self] in
            guard let self else { box.cancel(); return }
            if case .hostPort = box.endpoint, !Self.isLoopback(box.endpoint) {
                box.cancel()
                return
            }
            Task {
                let decoded = await box.readRequest()
                let response: KodHTTPResponse
                switch decoded {
                case .ready(let request):
                    let handler = self.currentHandler()
                    response = await handler(request)
                case .tooLarge:
                    response = .error(413, "too_large")
                case .invalid, .needMore:
                    response = .error(400, "bad_request")
                }
                box.send(response.encoded())
            }
        }
    }

    private func currentHandler() -> @Sendable (KodHTTPRequest) async -> KodHTTPResponse {
        lock.lock()
        let handler = handler
        lock.unlock()
        return handler ?? { _ in .error(503, "unavailable") }
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address):
                guard let first = address.rawValue.first else { return false }
                return first == 127
            case .ipv6(let address):
                guard let loopback = IPv6Address("::1") else { return false }
                return address == loopback
            default:
                return false
            }
        default:
            return false
        }
    }
}

/// `NWConnection` is used from the listener queue and from unstructured tasks.
private final class ConnectionBox: @unchecked Sendable {
    let connection: NWConnection
    private let started = OSAllocatedUnfairLock(initialState: false)
    init(_ connection: NWConnection) { self.connection = connection }

    var endpoint: NWEndpoint { connection.endpoint }

    func cancel() { connection.cancel() }

    func start(queue: DispatchQueue, onReady: @escaping @Sendable () -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            let first = self.started.withLock { value -> Bool in
                if value { return false }
                value = true
                return true
            }
            guard first else { return }
            onReady()
        }
        connection.start(queue: queue)
    }

    func send(_ bytes: Data) {
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }

    func readRequest() async -> KodHTTPDecode {
        let accumulator = HTTPAccumulator()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            accumulator.finish(.invalid)
            self?.cancel()
        }
        let decoded = await withCheckedContinuation { (continuation: CheckedContinuation<KodHTTPDecode, Never>) in
            accumulator.set(continuation)
            self.pull(accumulator)
        }
        timeout.cancel()
        return decoded
    }

    private func pull(_ accumulator: HTTPAccumulator) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { accumulator.finish(.invalid); return }
            if error != nil {
                accumulator.finish(.invalid)
                return
            }
            if accumulator.consume(data, isComplete: isComplete) { self.pull(accumulator) }
        }
    }
}

/// Bytes of one HTTP request, touched from the connection queue and the timeout task.
private final class HTTPAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<KodHTTPDecode, Never>?
    private var finished = false

    func set(_ continuation: CheckedContinuation<KodHTTPDecode, Never>) {
        lock.lock()
        let already = finished
        if !already { self.continuation = continuation }
        lock.unlock()
        if already { continuation.resume(returning: .invalid) }
    }

    /// True when the caller should read more.
    func consume(_ data: Data?, isComplete: Bool) -> Bool {
        lock.lock()
        if let data, buffer.count < KodHTTP.maxHeaderBytes + KodHTTP.maxBodyBytes {
            let room = KodHTTP.maxHeaderBytes + KodHTTP.maxBodyBytes - buffer.count
            buffer.append(data.prefix(room))
        }
        let decode = KodHTTP.decode(buffer)
        let decision: KodHTTPDecode? = switch decode {
        case .needMore where buffer.count >= KodHTTP.maxHeaderBytes + KodHTTP.maxBodyBytes:
            .tooLarge
        case .needMore where isComplete:
            .invalid
        case .needMore:
            nil
        default:
            decode
        }
        lock.unlock()
        if let decision {
            finish(decision)
            return false
        }
        return true
    }

    func finish(_ value: KodHTTPDecode) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
