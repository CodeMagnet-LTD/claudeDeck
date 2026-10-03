import Darwin
import Foundation

/// Finds this Mac's Tailscale addresses, and tells Tailscale peers from everything else.
public enum Tailscale {
    public struct Status: Sendable, Equatable {
        /// "Running" when connected; "NeedsLogin", "Stopped", "Starting"… otherwise.
        public var backendState: String?
        /// MagicDNS name, without the trailing dot.
        public var dnsName: String?
        public var ips: [String]
        /// Other devices in the tailnet: MagicDNS name (no trailing dot) → online.
        public var peers: [String: Bool]
        /// MagicDNS names of the user's own online macOS devices (where a ClaudeDeck host can be).
        public var onlineMacs: [String] = []

        public var isRunning: Bool { backendState == "Running" }

        public init(backendState: String?, dnsName: String?, ips: [String], peers: [String: Bool] = [:]) {
            self.backendState = backendState
            self.dnsName = dnsName
            self.ips = ips
            self.peers = peers
        }
    }

    /// Parses `tailscale status --json`.
    public static func parseStatus(_ data: Data) -> Status? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = root["Self"] as? [String: Any]
        else { return nil }
        func trimmed(_ name: Any?) -> String? {
            guard let name = name as? String, !name.isEmpty else { return nil }
            return name.hasSuffix(".") ? String(name.dropLast()) : name
        }
        var peers: [String: Bool] = [:]
        var onlineMacs: [String] = []
        let myUser = me["UserID"] as? Int
        for case let peer as [String: Any] in (root["Peer"] as? [String: Any] ?? [:]).values {
            guard let name = trimmed(peer["DNSName"]) else { continue }
            let online = peer["Online"] as? Bool ?? false
            peers[name] = online
            // Only the user's own Macs: devices shared in from other accounts never get the password proof.
            let sameUser = myUser == nil || (peer["UserID"] as? Int) == myUser
            if online, sameUser, (peer["OS"] as? String)?.lowercased() == "macos" { onlineMacs.append(name) }
        }
        var status = Status(
            backendState: root["BackendState"] as? String,
            dnsName: trimmed(me["DNSName"]),
            ips: me["TailscaleIPs"] as? [String] ?? [],
            peers: peers
        )
        status.onlineMacs = onlineMacs.sorted()
        return status
    }

    /// Whether the Tailscale app or CLI is on this Mac.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")
            || cliCandidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The CLI: the Mac App Store / standalone app bundle, or Homebrew / the open-source build.
    public static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    /// Runs `tailscale status --json` (blocking; call off the main thread). nil when Tailscale
    /// isn't installed or not running.
    public static func status(timeout: TimeInterval = 5) -> Status? {
        guard let cli = cliCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return parseStatus(data)
    }

    /// Tailscale IPs bound to this Mac's interfaces (works without the CLI).
    public static func interfaceAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = pointer.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if isTailscaleIP(ip), !result.contains(ip) { result.append(ip) }
        }
        return result
    }

    /// 100.64.0.0/10 (Tailscale's CGNAT range) or fd7a:115c:a1e0::/48.
    public static func isTailscaleIP(_ ip: String) -> Bool {
        let bare = ip.split(separator: "%").first.map(String.init) ?? ip
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            return value & 0xFFC0_0000 == 0x6440_0000
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, bare, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            // IPv4-mapped (::ffff:100.x.y.z): the listener reports v4 peers this way.
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return bytes[12] == 100 && bytes[13] & 0xC0 == 0x40
            }
            return bytes[0..<6] == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
        }
        return false
    }

    public static func isLoopback(_ ip: String) -> Bool {
        let bare = ip.split(separator: "%").first.map(String.init) ?? ip
        return bare == "::1" || bare.hasPrefix("127.") || bare == "::ffff:127.0.0.1"
    }
}

/// The macOS application firewall, read with `socketfilterfw` (no admin rights needed).
public enum Firewall {
    public struct Status: Sendable, Equatable {
        public var enabled: Bool
        /// "Block all incoming connections".
        public var blockAll: Bool
        /// This app explicitly blocked (nil when unknown / not listed).
        public var appBlocked: Bool?

        /// Incoming connections to the app can get through.
        public var allowsIncoming: Bool { !enabled || (!blockAll && appBlocked != true) }
    }

    static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    public static func parse(globalState: String, blockAll: String, app: String) -> Status {
        Status(
            enabled: globalState.contains("enabled"),
            blockAll: blockAll.contains("block all state set to enabled") || blockAll.contains("blockall state set to enabled"),
            appBlocked: app.contains("is blocked") ? true : app.contains("is permitted") ? false : nil
        )
    }

    /// Blocking; call off the main thread.
    public static func status(appPath: String) -> Status? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        func run(_ args: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        return parse(globalState: run(["--getglobalstate"]), blockAll: run(["--getblockall"]), app: run(["--getappblocked", appPath]))
    }
}
