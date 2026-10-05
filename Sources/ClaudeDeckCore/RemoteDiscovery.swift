import Foundation
import Network

// Local-network discovery: a hosting Mac advertises itself over Bonjour (when allowed in
// Settings); remotes browse for it, so at home they connect directly, without Tailscale.
// The connection is encrypted the same way on every path (RemoteCrypto.swift).

public enum RemoteBonjour {
    /// `CLAUDEDECK_BONJOUR_TYPE` keeps demo copies apart from real ones on the same network.
    nonisolated(unsafe) public static var serviceType = ProcessInfo.processInfo.environment["CLAUDEDECK_BONJOUR_TYPE"] ?? "_claudedeck._tcp"
    public static let addressPrefix = "bonjour:"

    /// `bonjour:<service name>` in a pairing's address list.
    public static func address(_ name: String) -> String { addressPrefix + name }

    public static func serviceName(of address: String) -> String? {
        address.hasPrefix(addressPrefix) ? String(address.dropFirst(addressPrefix.count)) : nil
    }

    public static func endpoint(serviceName: String) -> NWEndpoint {
        .service(name: serviceName, type: serviceType, domain: "local.", interface: nil)
    }
}

/// A ClaudeDeck host seen on the local network.
public struct DiscoveredHost: Sendable, Equatable, Identifiable {
    public var name: String
    public var hostID: UUID?
    public var id: String { name }
    public var address: String { RemoteBonjour.address(name) }

    public init(name: String, hostID: UUID?) {
        self.name = name
        self.hostID = hostID
    }
}

/// Browses for hosts; `onChange` gets the current list (on the given queue).
public final class RemoteDiscovery: @unchecked Sendable {
    private let queue: DispatchQueue
    private var browser: NWBrowser?
    public private(set) var hosts: [DiscoveredHost] = []
    public var onChange: (([DiscoveredHost]) -> Void)?

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteBonjour.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let hosts = results.compactMap { result -> DiscoveredHost? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var id: UUID?
                if case .bonjour(let txt) = result.metadata, let raw = txt["id"] { id = UUID(uuidString: raw) }
                return DiscoveredHost(name: name, hostID: id)
            }
            .sorted { $0.name < $1.name }
            guard hosts != self.hosts else { return }
            self.hosts = hosts
            self.onChange?(hosts)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.restart() }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        if !hosts.isEmpty {
            hosts = []
            onChange?([])
        }
    }

    private func restart() {
        browser?.cancel()
        browser = nil
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
    }
}
