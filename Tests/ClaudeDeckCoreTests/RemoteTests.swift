import Foundation
import CryptoKit
import Network
import Testing
@testable import ClaudeDeckCore

@Suite struct RemoteProtocolTests {
    @Test func framesSurviveArbitrarySplits() throws {
        let messages: [RemoteMessage] = [
            .hello(version: 1, nonce: Data([1, 2, 3]), deviceName: "Laptop"),
            .snapshot(RemoteSnapshot(hostName: "Home", sessions: [
                RemoteSession(id: UUID(), name: "api", project: "api", state: .needsPermission, detail: "Bash: ls", updatedAt: Date(timeIntervalSince1970: 1_700_000_000.123), permissionStamp: 1_700_000_000.123),
            ])),
            .ping,
        ]
        let stream = try messages.map { try $0.frame().encoded() }.reduce(Data(), +)
        for chunkSize in [1, 2, 7, 64, stream.count] {
            var decoder = RemoteFrameDecoder()
            var decoded: [RemoteMessage] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                decoded += try decoder.append(stream.subdata(in: offset..<end)).compactMap { try RemoteMessage.decode($0) }
                offset = end
            }
            #expect(decoded == messages)
        }
    }

    @Test func oversizedFrameIsRejected() {
        var decoder = RemoteFrameDecoder()
        let header = Data([1, 0x7F, 0xFF, 0xFF, 0xFF])
        #expect(throws: RemoteFrameDecoder.DecodeError.self) { try decoder.append(header) }
    }

    @Test func stampSurvivesJSON() throws {
        let stamp = Date().timeIntervalSince1970
        let message = RemoteMessage.permission(sessionID: UUID(), stamp: stamp, approve: true)
        let back = try RemoteMessage.decode(message.frame())
        guard case .permission(_, let decodedStamp, _) = back else { Issue.record("wrong case"); return }
        #expect(decodedStamp == stamp)
    }

    @Test func handshakeProofsAreDirectional() {
        let key = RemotePairing.makeKey()
        let (a, b) = (RemoteHandshake.makeNonce(), RemoteHandshake.makeNonce())
        let host = RemoteHandshake.hostProof(key: key, remoteNonce: a, hostNonce: b)
        let remote = RemoteHandshake.remoteProof(key: key, remoteNonce: a, hostNonce: b)
        #expect(!RemoteHandshake.matches(host, remote))
        #expect(RemoteHandshake.matches(host, RemoteHandshake.hostProof(key: key, remoteNonce: a, hostNonce: b)))
        #expect(!RemoteHandshake.matches(host, RemoteHandshake.hostProof(key: RemotePairing.makeKey(), remoteNonce: a, hostNonce: b)))
        #expect(!RemoteHandshake.matches(host, RemoteHandshake.hostProof(key: key, remoteNonce: b, hostNonce: a)))
    }

    @Test func pairingLinkRoundTrips() throws {
        let pairing = RemotePairing(id: UUID(), hostName: "Ev Mac'i", addresses: ["home.tail1234.ts.net", "100.101.102.103"], port: 47821, key: RemotePairing.makeKey(), updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let link = try pairing.link()
        let payload = try #require(link.components(separatedBy: "?d=").last)
        #expect(!payload.contains("+") && !payload.contains("/") && !payload.contains("="))
        #expect(RemotePairing.parse(link: "  \(link)\n") == pairing)
        #expect(RemotePairing.parse(link: "claudedeck://pair?d=garbage") == nil)
        #expect(RemotePairing.parse(link: "https://example.com") == nil)
    }

    @Test func tailscaleAddresses() {
        #expect(Tailscale.isTailscaleIP("100.64.0.1"))
        #expect(Tailscale.isTailscaleIP("100.127.255.254"))
        #expect(!Tailscale.isTailscaleIP("100.128.0.1"))
        #expect(!Tailscale.isTailscaleIP("100.63.255.255"))
        #expect(!Tailscale.isTailscaleIP("192.168.1.10"))
        #expect(Tailscale.isTailscaleIP("::ffff:100.100.1.2"))
        #expect(!Tailscale.isTailscaleIP("::ffff:192.168.1.2"))
        #expect(Tailscale.isTailscaleIP("fd7a:115c:a1e0:ab12::1"))
        #expect(Tailscale.isTailscaleIP("fd7a:115c:a1e0::1%utun4"))
        #expect(!Tailscale.isTailscaleIP("fd7a:115c:a1e1::1"))
        #expect(!Tailscale.isTailscaleIP("home.ts.net"))
        #expect(Tailscale.isLoopback("127.0.0.1") && Tailscale.isLoopback("::1"))
    }

    @Test func parsesTailscaleStatus() throws {
        let json = #"{"BackendState":"Running","Self":{"DNSName":"home-mac.tail1234.ts.net.","TailscaleIPs":["100.101.102.103","fd7a:115c:a1e0::1"]},"Peer":{"k1":{"DNSName":"laptop.tail1234.ts.net.","Online":false},"k2":{"DNSName":"nas.tail1234.ts.net.","Online":true}}}"#
        let status = try #require(Tailscale.parseStatus(Data(json.utf8)))
        #expect(status.isRunning)
        #expect(status.dnsName == "home-mac.tail1234.ts.net")
        #expect(status.ips == ["100.101.102.103", "fd7a:115c:a1e0::1"])
        #expect(status.peers == ["laptop.tail1234.ts.net": false, "nas.tail1234.ts.net": true])
        let loggedOut = try #require(Tailscale.parseStatus(Data(#"{"BackendState":"NeedsLogin","Self":{}}"#.utf8)))
        #expect(!loggedOut.isRunning && loggedOut.dnsName == nil)
        #expect(Tailscale.parseStatus(Data("{}".utf8)) == nil)
    }

    @Test func passwordKeyIsStableAndDistinct() {
        let a = RemoteHandshake.key(fromPassword: "correct horse", rounds: 1000)
        #expect(a.count == 32)
        #expect(a == RemoteHandshake.key(fromPassword: "correct horse", rounds: 1000))
        #expect(a != RemoteHandshake.key(fromPassword: "correct horsE", rounds: 1000))
        // Same text typed as composed or decomposed Unicode (ş, ö…) gives the same key.
        #expect(RemoteHandshake.key(fromPassword: "\u{015F}ifre", rounds: 1000) == RemoteHandshake.key(fromPassword: "s\u{0327}ifre", rounds: 1000))
    }

    @Test func listsOnlineMacPeers() throws {
        let json = #"{"BackendState":"Running","Self":{"DNSName":"laptop.ts.net.","UserID":1},"Peer":{"a":{"DNSName":"home.ts.net.","Online":true,"OS":"macOS","UserID":1},"b":{"DNSName":"old.ts.net.","Online":false,"OS":"macOS","UserID":1},"c":{"DNSName":"nas.ts.net.","Online":true,"OS":"linux","UserID":1},"d":{"DNSName":"friend.ts.net.","Online":true,"OS":"macOS","UserID":2}}}"#
        let status = try #require(Tailscale.parseStatus(Data(json.utf8)))
        #expect(status.onlineMacs == ["home.ts.net"])
    }

    @Test func parsesFirewall() {
        let on = "Firewall is enabled. (State = 1)"
        let off = "Firewall is disabled. (State = 0)"
        let noBlockAll = "Firewall has block all state set to disabled."
        let blockAll = "Firewall has block all state set to enabled."
        let permitted = "Incoming connection to /Applications/ClaudeDeck.app is permitted."
        let blocked = "Incoming connection to /Applications/ClaudeDeck.app is blocked."
        #expect(Firewall.parse(globalState: off, blockAll: blockAll, app: blocked).allowsIncoming)
        #expect(Firewall.parse(globalState: on, blockAll: noBlockAll, app: permitted).allowsIncoming)
        #expect(Firewall.parse(globalState: on, blockAll: noBlockAll, app: "").allowsIncoming)
        #expect(!Firewall.parse(globalState: on, blockAll: blockAll, app: permitted).allowsIncoming)
        #expect(!Firewall.parse(globalState: on, blockAll: noBlockAll, app: blocked).allowsIncoming)
    }

    @Test func newAttentionSkipsBaselineAndRepeats() {
        let id = UUID()
        func snap(_ state: RemoteSession.State, at s: TimeInterval, unseen: Bool = false) -> RemoteSnapshot {
            RemoteSnapshot(hostName: "h", sessions: [RemoteSession(id: id, name: "s", project: "p", state: state, updatedAt: Date(timeIntervalSince1970: s), unseen: unseen)])
        }
        #expect(RemoteSnapshot.newAttention(from: nil, to: snap(.needsPermission, at: 1)).isEmpty)
        #expect(RemoteSnapshot.newAttention(from: snap(.running, at: 1), to: snap(.needsPermission, at: 2)).count == 1)
        #expect(RemoteSnapshot.newAttention(from: snap(.needsPermission, at: 2), to: snap(.needsPermission, at: 2)).isEmpty)
        // A second prompt in the same turn has a new stamp.
        #expect(RemoteSnapshot.newAttention(from: snap(.needsPermission, at: 2), to: snap(.needsPermission, at: 3)).count == 1)
        #expect(RemoteSnapshot.newAttention(from: snap(.running, at: 3), to: snap(.idle, at: 4, unseen: true)).count == 1)
        #expect(RemoteSnapshot.newAttention(from: snap(.running, at: 3), to: snap(.idle, at: 4, unseen: false)).isEmpty)
    }
}

/// Real sockets on loopback: handshake, snapshot, permission round trip, wrong key.
@Suite(.serialized) struct RemoteLoopbackTests {
    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    /// Waits until the server listens and returns the port the system gave it.
    static func listeningPort(_ server: RemoteServer, queue: DispatchQueue) async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .listening(let port) = queue.sync(execute: { server.state }) { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("server didn't start")
        return 0
    }

    @Test func connectsAndAnswersPermission() async throws {
        let queue = DispatchQueue(label: "remote-test")
        let key = RemotePairing.makeKey()
                let sessionID = UUID()
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: Tailscale.isLoopback)
        let received = Box<[(UUID, Double, Bool)]>([])
        server.onPermission = { id, stamp, approve in
            received.value.append((id, stamp, approve))
            return true
        }
        queue.sync {
            server.snapshot = RemoteSnapshot(hostName: "Home", sessions: [RemoteSession(id: sessionID, name: "api", project: "api", state: .needsPermission, permissionStamp: 42.5)])
            server.start()
        }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)

        let pairing = RemotePairing(id: UUID(), hostName: "Home", addresses: ["127.0.0.1"], port: port, key: key, updatedAt: Date())
        let client = RemoteHostConnection(pairing: pairing, deviceName: "Laptop", queue: queue)
        let snapshot = Box<RemoteSnapshot?>(nil)
        let result = Box<Bool?>(nil)
        client.onSnapshot = { snapshot.value = $0 }
        client.onPermissionResult = { _, _, applied in result.value = applied }
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }

        try await waitUntil { queue.sync { snapshot.value != nil } }
        #expect(queue.sync { client.state } == .connected(hostName: "Home"))
        #expect(queue.sync { server.peerNames } == ["Laptop"])
        #expect(queue.sync { client.sendPermission(sessionID: sessionID, stamp: 42.5, approve: true) })
        try await waitUntil { queue.sync { result.value != nil } }
        #expect(result.value == true)
        #expect(received.value.first?.0 == sessionID && received.value.first?.1 == 42.5 && received.value.first?.2 == true)

        // A new snapshot reaches the remote.
        queue.sync { server.snapshot = RemoteSnapshot(hostName: "Home", sessions: []) }
        try await waitUntil { queue.sync { snapshot.value?.sessions.isEmpty == true } }
    }

    @Test func wrongKeyIsRefused() async throws {
        let queue = DispatchQueue(label: "remote-test-2")
                let server = RemoteServer(port: 0, queue: queue, key: { RemotePairing.makeKey() }, acceptsPeer: Tailscale.isLoopback)
        queue.sync { server.start() }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)
        let pairing = RemotePairing(id: UUID(), hostName: "Home", addresses: ["127.0.0.1"], port: port, key: RemotePairing.makeKey(), updatedAt: Date())
        let client = RemoteHostConnection(pairing: pairing, deviceName: "Laptop", queue: queue)
        queue.sync { client.start() }
        try await waitUntil {
            queue.sync { if case .refused = client.state { true } else { false } }
        }
        #expect(queue.sync { server.peerNames }.isEmpty)
    }

    @Test func nonTailscalePeerIsDropped() async throws {
        let queue = DispatchQueue(label: "remote-test-3")
                let key = RemotePairing.makeKey()
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: Tailscale.isTailscaleIP)
        queue.sync { server.start() }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)
        let pairing = RemotePairing(id: UUID(), hostName: "Home", addresses: ["127.0.0.1"], port: port, key: key, updatedAt: Date())
        let client = RemoteHostConnection(pairing: pairing, deviceName: "Laptop", queue: queue)
        queue.sync { client.start() }
        try await waitUntil {
            queue.sync { if case .disconnected = client.state { true } else { false } }
        }
    }

    @Test func silentAddressTimesOut() async throws {
        let queue = DispatchQueue(label: "remote-test-4")
                // Accepts TCP, never says a word.
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = Box<[NWConnection]>([])
        listener.newConnectionHandler = { connection in
            accepted.value.append(connection)
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        defer { listener.cancel(); queue.sync { accepted.value.forEach { $0.cancel() } } }
        try await waitUntil { queue.sync { listener.port?.rawValue ?? 0 } != 0 }
        let port = try #require(queue.sync { listener.port?.rawValue })
        let pairing = RemotePairing(id: UUID(), hostName: "Home", addresses: ["127.0.0.1"], port: port, key: RemotePairing.makeKey(), updatedAt: Date())
        let client = RemoteHostConnection(pairing: pairing, deviceName: "Laptop", queue: queue)
        client.handshakeTimeout = 0.5
        queue.sync { client.start() }
        try await waitUntil {
            queue.sync { if case .disconnected = client.state { true } else { false } }
        }
    }

    @Test func wrongPasswordsAreThrottled() async throws {
        let queue = DispatchQueue(label: "remote-test-5")
                let server = RemoteServer(port: 0, queue: queue, key: { RemoteHandshake.key(fromPassword: "home password", rounds: 1000) }, acceptsPeer: Tailscale.isLoopback)
        queue.sync { server.start() }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)
        func attempt(_ password: String) async throws -> RemoteHostConnection.State {
            let pairing = RemotePairing(id: UUID(), hostName: "Home", addresses: ["127.0.0.1"], port: port, key: RemoteHandshake.key(fromPassword: password, rounds: 1000), updatedAt: Date())
            let client = RemoteHostConnection(pairing: pairing, deviceName: "Laptop", queue: queue)
            client.handshakeTimeout = 1
            queue.sync { client.start() }
            defer { queue.sync { client.close() } }
            try await waitUntil {
                queue.sync { if case .connecting = client.state { false } else { true } }
            }
            return queue.sync { client.state }
        }
        for _ in 0..<RemoteServer.maxFailures {
            guard case .refused = try await attempt("wrong guess") else { Issue.record("expected refusal"); return }
        }
        // Now even the right password is dropped for a while.
        guard case .disconnected = try await attempt("home password") else { Issue.record("expected throttling"); return }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Suite struct RemoteScreenTests {
    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func plainScreenRoundsTrip() {
        let lines: [[TermCell]] = [
            "hello".map { TermCell(text: String($0)) } + [TermCell(text: " "), TermCell(text: " ")],
            [],
            "> ".map { TermCell(text: String($0)) },
        ]
        let screen = TermScreen(cols: 10, rows: 3, lines: lines, cursorX: 2, cursorY: 2)
        #expect(text(screen.ansi()) == "\u{1b}[0m\u{1b}[H\u{1b}[2J\u{1b}[3Jhello\r\n\r\n>\u{1b}[0m\u{1b}[3;3H")
    }

    @Test func colorsAndStylesBecomeSGR() {
        let red = TermCell(text: "E", fg: .ansi(1), style: [.bold])
        let bright = TermCell(text: "w", fg: .ansi(9))
        let palette = TermCell(text: "p", fg: .ansi(208), bg: .rgb(1, 2, 3))
        let selected = TermCell(text: " ", style: [.inverse]) // kept: inverse blank is visible
        let screen = TermScreen(cols: 10, rows: 1, lines: [[red, bright, palette, selected]], cursorX: 99, cursorY: 0)
        let out = text(screen.ansi())
        #expect(out.contains("\u{1b}[0;1;31mE\u{1b}[0;91mw\u{1b}[0;38;5;208;48;2;1;2;3mp\u{1b}[0;7m \u{1b}[0m"))
        // Cursor clamped to the last column.
        #expect(out.hasSuffix("\u{1b}[1;10H"))
    }

    @Test func wideCharactersSkipTheirPlaceholder() {
        let line = [TermCell(text: "界", width: 2), TermCell(text: "", width: 0), TermCell(text: "!")]
        let out = text(TermScreen(cols: 4, rows: 1, lines: [line], cursorX: 0, cursorY: 0).ansi())
        #expect(out.contains("界!"))
    }

    @Test func modesAndShortScreens() {
        var screen = TermScreen(cols: 5, rows: 3, lines: [[TermCell(text: "a")]], cursorX: 0, cursorY: 0)
        screen.alternateBuffer = true
        screen.applicationCursor = true
        screen.bracketedPaste = true
        let out = text(screen.ansi())
        #expect(out.hasPrefix("\u{1b}[?1049h"))
        #expect(out.contains("a\r\n\r\n"))
        #expect(out.hasSuffix("\u{1b}[?1h\u{1b}[?2004h"))
    }

    @Test func outputFrameRoundTrips() throws {
        let id = UUID()
        let frame = RemoteTerminalOutput.frame(sessionID: id, bytes: Data("\u{1b}[31mhi".utf8))
        var decoder = RemoteFrameDecoder()
        let back = try #require(try decoder.append(frame.encoded()).first)
        let output = try #require(RemoteTerminalOutput.decode(back))
        #expect(output.sessionID == id && output.bytes == Data("\u{1b}[31mhi".utf8))
    }
}

@Suite(.serialized) struct RemoteTerminalLoopbackTests {
    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    @Test func watchStreamTypeAndClose() async throws {
        let queue = DispatchQueue(label: "remote-term-test")
        let key = RemotePairing.makeKey()
                let sessionID = UUID()
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: Tailscale.isLoopback)
        let typed = Box<Data>(Data())
        let watched = Box<Set<UUID>>([])
        server.onTerminalOpen = { id in id == sessionID ? .init(cols: 80, rows: 24, screen: Data("SCREEN".utf8)) : nil }
        server.onTerminalInput = { _, data in typed.value.append(data) }
        server.onWatchedChanged = { watched.value = $0 }
        queue.sync { server.start() }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)

        let client = RemoteHostConnection(pairing: RemotePairing(id: UUID(), hostName: "Home", addresses: ["127.0.0.1"], port: port, key: key, updatedAt: Date()), deviceName: "Laptop", queue: queue)
        let started = Box<(Int, Int, Data)?>(nil)
        let received = Box<Data>(Data())
        let ended = Box<[UUID]>([])
        client.onTerminalStart = { _, cols, rows, screen in started.value = (cols, rows, screen) }
        client.onTerminalOutput = { _, bytes in received.value.append(bytes) }
        client.onTerminalEnded = { ended.value.append($0) }
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { queue.sync { if case .connected = client.state { true } else { false } } }

        queue.sync { _ = client.openTerminal(sessionID) }
        try await waitUntil { queue.sync { started.value != nil } }
        #expect(started.value?.0 == 80 && started.value?.1 == 24 && started.value?.2 == Data("SCREEN".utf8))
        #expect(queue.sync { watched.value } == [sessionID])

        queue.sync { server.sendOutput(sessionID: sessionID, bytes: Data("abc".utf8)) }
        queue.sync { server.sendOutput(sessionID: UUID(), bytes: Data("not watched".utf8)) }
        try await waitUntil { queue.sync { received.value == Data("abc".utf8) } }

        queue.sync { _ = client.sendInput(sessionID, data: Data("1".utf8)) }
        try await waitUntil { queue.sync { typed.value == Data("1".utf8) } }

        // A session that isn't running answers with "ended".
        let other = UUID()
        queue.sync { _ = client.openTerminal(other) }
        try await waitUntil { queue.sync { ended.value == [other] } }

        queue.sync { _ = client.closeTerminal(sessionID) }
        try await waitUntil { queue.sync { watched.value.isEmpty } }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Suite struct APNsTests {
    @Test func providerTokenVerifiesWithTheKey() throws {
        let key = P256.Signing.PrivateKey()
        let credentials = APNsCredentials(keyID: "ABC123DEFG", teamID: "V6G4B5T63L", keyPEM: key.pemRepresentation)
        #expect(credentials.isValid)
        let token = try APNs.token(credentials, issuedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        func decode(_ s: String) -> Data {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            b += String(repeating: "=", count: (4 - b.count % 4) % 4)
            return Data(base64Encoded: b)!
        }
        #expect(String(decoding: decode(parts[0]), as: UTF8.self) == #"{"alg":"ES256","kid":"ABC123DEFG"}"#)
        #expect(String(decoding: decode(parts[1]), as: UTF8.self) == #"{"iss":"V6G4B5T63L","iat":1700000000}"#)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
        #expect(!APNsCredentials(keyID: "x", teamID: "y", keyPEM: "not a key").isValid)
    }

    @Test func payloadCarriesTheStampAsAString() throws {
        let id = UUID()
        let data = APNs.payload(title: "api", subtitle: "Home", body: "Needs permission: Bash", sessionID: id, permissionStamp: 1_790_000_000.123456, blocked: true)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aps = try #require(root["aps"] as? [String: Any])
        #expect(aps["category"] as? String == "permission")
        #expect(aps["sound"] as? String == "default")
        #expect(root["sessionID"] as? String == id.uuidString)
        #expect((root["stamp"] as? String).flatMap(Double.init) == 1_790_000_000.123456)
        let idle = try #require(try JSONSerialization.jsonObject(with: APNs.payload(title: "a", subtitle: nil, body: "Done", sessionID: id, permissionStamp: nil, blocked: false)) as? [String: Any])
        #expect((idle["aps"] as? [String: Any])?["category"] == nil && idle["stamp"] == nil)
        #expect(APNs.host(for: "production") == "api.push.apple.com" && APNs.host(for: "development") == "api.sandbox.push.apple.com")
    }
}

@Suite struct RemoteCryptoTests {
    func pair(_ key: Data = RemotePairing.makeKey()) -> (host: RemoteCipher, remote: RemoteCipher) {
        let (a, b) = (RemoteHandshake.makeNonce(), RemoteHandshake.makeNonce())
        return (RemoteCipher(pairingKey: key, remoteNonce: a, hostNonce: b, role: .host),
                RemoteCipher(pairingKey: key, remoteNonce: a, hostNonce: b, role: .remote))
    }

    @Test func roundTripsBothWaysAndHidesThePayload() throws {
        var (host, remote) = pair()
        for i in 0..<5 {
            let frame = RemoteFrame(kind: 2, payload: Data("secret screen \(i)".utf8))
            let sealed = try host.seal(frame)
            #expect(sealed.kind == RemoteFrameKind.sealed.rawValue)
            #expect(sealed.payload.range(of: Data("secret".utf8)) == nil)
            #expect(try remote.open(sealed) == frame)
            let back = RemoteFrame(kind: 1, payload: Data("keys \(i)".utf8))
            #expect(try host.open(remote.seal(back)) == back)
        }
    }

    @Test func rejectsTamperingReplayReorderAndWrongKey() throws {
        var (host, remote) = pair()
        let first = try host.seal(RemoteFrame(kind: 1, payload: Data("one".utf8)))
        let second = try host.seal(RemoteFrame(kind: 1, payload: Data("two".utf8)))
        // Reordered: the second frame can't be opened first.
        var r1 = remote
        #expect(throws: RemoteCipher.CipherError.self) { try r1.open(second) }
        // Tampered.
        var bad = first
        bad.payload[bad.payload.startIndex] ^= 1
        var r2 = remote
        #expect(throws: RemoteCipher.CipherError.self) { try r2.open(bad) }
        // In order works; a replay of the first then fails.
        _ = try remote.open(first)
        _ = try remote.open(second)
        #expect(throws: RemoteCipher.CipherError.self) { try remote.open(first) }
        // Own direction / other key can't open.
        var hostCopy = host
        #expect(throws: RemoteCipher.CipherError.self) { try hostCopy.open(first) }
        var (_, stranger) = pair()
        #expect(throws: RemoteCipher.CipherError.self) { try stranger.open(first) }
    }
}

@Suite(.serialized) struct RemoteLANTests {
    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    @Test func privateLANAddresses() {
        for ip in ["192.168.1.93", "10.0.0.5", "172.16.0.1", "172.31.255.1", "169.254.3.4", "fe80::1%en0", "fd12:3456::1", "::ffff:192.168.1.2"] {
            #expect(Tailscale.isPrivateLAN(ip), "\(ip)")
        }
        for ip in ["8.8.8.8", "172.32.0.1", "100.81.1.3", "2001:4860::8888", "::ffff:8.8.8.8", "mac.local"] {
            #expect(!Tailscale.isPrivateLAN(ip), "\(ip)")
        }
    }

    /// Advertise, discover, connect through the Bonjour service, all encrypted.
    @Test func findsAndConnectsOverBonjour() async throws {
        RemoteBonjour.serviceType = "_cdtest._tcp"
        defer { RemoteBonjour.serviceType = "_claudedeck._tcp" }
        let queue = DispatchQueue(label: "lan-test")
        let key = RemotePairing.makeKey()
        let hostID = UUID()
        let name = "ClaudeDeck Test \(UInt16.random(in: 1000...9999))"
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: { Tailscale.isLoopback($0) || Tailscale.isPrivateLAN($0) })
        server.bonjour = (name, hostID)
        queue.sync {
            server.snapshot = RemoteSnapshot(hostName: "LAN Host", sessions: [])
            server.start()
        }
        defer { queue.sync { server.stop() } }
        let discovery = RemoteDiscovery(queue: queue)
        let found = Box<[DiscoveredHost]>([])
        discovery.onChange = { found.value = $0 }
        queue.sync { discovery.start() }
        defer { queue.sync { discovery.stop() } }
        try await waitUntil(timeout: 10) { queue.sync { found.value.contains { $0.name == name } } }
        let host = try #require(queue.sync { found.value.first { $0.name == name } })
        #expect(host.hostID == hostID)

        let pairing = RemotePairing(id: hostID, hostName: name, addresses: [host.address], port: 1, key: key, updatedAt: Date())
        let client = RemoteHostConnection(pairing: pairing, deviceName: "Phone", queue: queue)
        let snapshot = Box<RemoteSnapshot?>(nil)
        client.onSnapshot = { snapshot.value = $0 }
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil(timeout: 10) { queue.sync { snapshot.value != nil } }
        #expect(snapshot.value?.hostName == "LAN Host")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
