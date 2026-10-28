import CommonCrypto
import CryptoKit
import Foundation

// Remote mode: one Mac (the host) runs the sessions, another ClaudeDeck (the remote) shows their
// status, gets the notifications and answers permission prompts. The connection is plain TCP over
// Tailscale (WireGuard already encrypts it); both sides prove they hold the pairing key with an
// HMAC challenge before anything else is sent.
//
// Wire format: frames of [kind: UInt8][length: UInt32 big-endian][payload]. Control messages are
// JSON (`RemoteMessage`) in `.message` frames; later frame kinds can carry raw terminal bytes.

public enum RemoteFrameKind: UInt8, Sendable {
    case message = 1
    /// Raw pty output of one session (`RemoteTerminalOutput`).
    case terminalOutput = 2
    /// Any frame, encrypted (RemoteCrypto.swift). Everything after the handshake is sealed.
    case sealed = 3
}

public struct RemoteFrame: Sendable, Equatable {
    public var kind: UInt8
    public var payload: Data

    public init(kind: UInt8, payload: Data) {
        self.kind = kind
        self.payload = payload
    }

    public static let headerSize = 5
    /// Larger frames are a protocol error (a snapshot is a few KB).
    public static let maxPayload = 8 << 20

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(kind)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
}

/// Splits a byte stream into frames; bytes of an unfinished frame wait for the next `append`.
public struct RemoteFrameDecoder: Sendable {
    public enum DecodeError: Error, Equatable { case frameTooLarge(Int) }

    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [RemoteFrame] {
        buffer.append(bytes)
        var frames: [RemoteFrame] = []
        while buffer.count >= RemoteFrame.headerSize {
            let start = buffer.startIndex
            let length = buffer[(start + 1)..<(start + 5)].reduce(0) { $0 << 8 | Int($1) }
            guard length <= RemoteFrame.maxPayload else { throw DecodeError.frameTooLarge(length) }
            guard buffer.count >= RemoteFrame.headerSize + length else { break }
            let payloadStart = start + RemoteFrame.headerSize
            frames.append(RemoteFrame(kind: buffer[start], payload: Data(buffer[payloadStart..<(payloadStart + length)])))
            buffer = Data(buffer[(payloadStart + length)...])
        }
        return frames
    }
}

// MARK: Messages

public enum RemoteMessage: Codable, Sendable, Equatable {
    /// Remote → host, first message.
    case hello(version: Int, nonce: Data, deviceName: String)
    /// Host → remote: its own nonce.
    case challenge(nonce: Data)
    /// Remote → host: the remote's proof of the key (first, so the host can count wrong
    /// passwords and nobody learns anything from the host before proving the key).
    case auth(proof: Data)
    /// Host → remote, after a valid `auth`: the host's proof of the key.
    case welcome(proof: Data)
    /// Host → remote: every session's state; sent after auth and on every change.
    case snapshot(RemoteSnapshot)
    /// Remote → host: answer the permission prompt identified by `stamp` (the hook timestamp the
    /// remote saw). The host ignores it if a different prompt is showing by now.
    case permission(sessionID: UUID, stamp: Double, approve: Bool)
    /// Host → remote: whether the keystroke was sent.
    case permissionResult(sessionID: UUID, approve: Bool, applied: Bool)
    /// Remote → host: answer the AskUserQuestion prompt of tool call `toolUseID` (one answer per
    /// question); the host types the keys. Answered with `permissionResult(approve: true)`.
    case answerQuestion(sessionID: UUID, toolUseID: String, answers: [QuestionAnswer])
    /// Remote → host: start watching a session's terminal.
    case terminalOpen(sessionID: UUID)
    /// Remote → host: stop watching.
    case terminalClose(sessionID: UUID)
    /// Remote → host: keystrokes / paste, typed into the session as if on the host.
    case terminalInput(sessionID: UUID, data: Data)
    /// Host → remote: the terminal's size and current screen (ANSI); output frames follow.
    /// Sent again after a resize or when the remote fell behind.
    case terminalStart(sessionID: UUID, cols: Int, rows: Int, screen: Data)
    /// Remote → host: size the session's terminal to this grid while watched (a phone fits it to
    /// its screen); `cols == 0` gives the size back to the host's window.
    case terminalFit(sessionID: UUID, cols: Int, rows: Int)
    /// Host → remote: the session isn't running (any more).
    case terminalEnded(sessionID: UUID)
    /// Remote → host: a page of a session's conversation (ConversationLog.swift): the latest
    /// `limit` entries, the ones before `before`, or the ones after `after`.
    case historyRequest(sessionID: UUID, before: String?, after: String?, limit: Int)
    /// Host → remote: the answer.
    case history(sessionID: UUID, page: ChatPage)
    /// Remote → host: start a Claude session in a project (and type `prompt` once it's ready).
    case startSession(projectID: UUID, prompt: String?)
    /// Host → remote: the session `startSession` created (the phone opens it).
    case sessionStarted(sessionID: UUID)
    /// Remote → host: a plain terminal in a project, optionally running `command`.
    case startShell(projectID: UUID, command: String?)
    /// Remote → host: the project's past Claude conversations (like the Mac's Resume window).
    case pastConversationsRequest(projectID: UUID)
    case pastConversations(projectID: UUID, items: [RemotePastConversation])
    /// Remote → host: a new session resuming one of those conversations.
    case resumeConversation(projectID: UUID, conversationID: String)
    /// Remote → host: a folder of a project (path relative to the project, "" = its root).
    case listDirectory(projectID: UUID, path: String)
    case directory(projectID: UUID, path: String, entries: [RemoteFileEntry], error: String?)
    /// Remote → host: a text file of a project (at most `RemoteFiles.maxFileSize`).
    case readFile(projectID: UUID, path: String)
    case file(projectID: UUID, path: String, text: String?, size: Int, error: String?)
    /// Remote → host: press Esc in a working session (interrupts Claude).
    case interrupt(sessionID: UUID)
    /// Remote → host: end a running session / resume a closed one.
    case stopSession(sessionID: UUID)
    case resumeSession(sessionID: UUID)
    /// Remote → host: the user looked at this session (clears "your turn").
    case markSeen(sessionID: UUID)
    /// Remote → host: type this message into the session and press Enter.
    case sendPrompt(sessionID: UUID, text: String)
    /// Remote → host: a message with files. The host saves them and puts them in with the text
    /// (images as pasted images, other files as @mentions). Answered with `promptResult`.
    case sendPromptWithFiles(sessionID: UUID, text: String, files: [RemoteUpload])
    /// Remote → host: files dropped / pasted into a watched terminal (another Mac). The host saves
    /// them and pastes them in like `sendPromptWithFiles`, without Enter. Answered with `promptResult`.
    case pasteFiles(sessionID: UUID, files: [RemoteUpload])
    /// Host → remote: whether the message with files went in (nil) or why not.
    case promptResult(sessionID: UUID, error: String?)
    /// Phone → host: send push notifications to this device (APNs.swift).
    case registerPush(token: Data, topic: String, environment: String, deviceName: String)
    case ping
    case pong
    /// Either side, before closing.
    case refused(reason: String)

    /// 2: frames after the handshake are encrypted; the remote proves the key first.
    public static let protocolVersion = 2

    public func frame() throws -> RemoteFrame {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return RemoteFrame(kind: RemoteFrameKind.message.rawValue, payload: try encoder.encode(self))
    }

    public static func decode(_ frame: RemoteFrame) throws -> RemoteMessage? {
        guard frame.kind == RemoteFrameKind.message.rawValue else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(RemoteMessage.self, from: frame.payload)
    }
}

/// A file the phone attaches to a message (photos are resized and made JPEG on the phone).
public struct RemoteUpload: Codable, Sendable, Equatable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    /// For all files of one message: base64 in JSON must stay under `RemoteFrame.maxPayload`.
    public static let maxTotalBytes = 5 << 20

    /// The host's folder for them (in its temporary folder).
    public static let folderName = "ClaudeDeckUploads"

    /// Pasted into Claude Code, a path with one of these extensions becomes an attached image.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// A file name safe to type into a prompt: no spaces (they end an @mention) or odd characters.
    public static func safeName(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var safe = String(name.map { allowed.contains($0) ? $0 : "-" }.prefix(80))
        while safe.hasPrefix(".") || safe.hasPrefix("-") { safe.removeFirst() }
        return safe.isEmpty ? "file" : safe
    }
}

/// The host's sessions as the remote shows them.
public struct RemoteSnapshot: Codable, Sendable, Equatable {
    public var hostName: String
    public var sessions: [RemoteSession]
    /// Projects a remote can start sessions in.
    public var projects: [RemoteProject]?
    /// The plan's usage meter (Settings › usage on the Mac), when known.
    public var usage: RemoteUsage?
    /// The host's stable id (matches its Bonjour TXT record) and Tailscale addresses: a phone
    /// paired on the local network learns how to reach the host when away.
    public var hostID: UUID?
    public var addresses: [String]?

    public init(hostName: String, sessions: [RemoteSession], hostID: UUID? = nil, addresses: [String]? = nil) {
        self.hostName = hostName
        self.sessions = sessions
        self.hostID = hostID
        self.addresses = addresses
    }

    public func session(_ id: UUID) -> RemoteSession? { sessions.first { $0.id == id } }
}

public struct RemoteUsage: Codable, Sendable, Equatable {
    public var fiveHour: Double?
    public var fiveHourResetsAt: Date?
    public var week: Double?
    public var weekResetsAt: Date?
    public init(fiveHour: Double?, fiveHourResetsAt: Date?, week: Double?, weekResetsAt: Date?) {
        self.fiveHour = fiveHour
        self.fiveHourResetsAt = fiveHourResetsAt
        self.week = week
        self.weekResetsAt = weekResetsAt
    }
}

public struct RemoteFileEntry: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int
    public var id: String { name }
    /// Dot-file hidden by default on the phone (except the useful ones, as on the Mac).
    public var isHidden: Bool { name.hasPrefix(".") && name != ".claude" && name != ".github" }
    public init(name: String, isDirectory: Bool, size: Int) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }
}

public struct RemotePastConversation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var modifiedAt: Date
    public init(id: String, title: String, modifiedAt: Date) {
        self.id = id
        self.title = title
        self.modifiedAt = modifiedAt
    }
}

public struct RemoteProject: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct RemoteSession: Codable, Sendable, Equatable, Identifiable {
    /// Mirrors the host sidebar's display state.
    public enum State: String, Codable, Sendable {
        case notStarted, starting, shell, running, needsPermission, needsAnswer, idle, ended

        public var isBlocked: Bool { self == .needsPermission || self == .needsAnswer }
    }

    public var id: UUID
    public var name: String
    public var project: String
    public var state: State
    public var detail: String?
    public var updatedAt: Date?
    /// Finished and not yet looked at on the host.
    public var unseen: Bool
    /// Set while a permission prompt can be answered with Allow / Deny (see `pendingPermissionStamp`).
    public var permissionStamp: Double?

    public init(
        id: UUID, name: String, project: String, state: State, detail: String? = nil,
        updatedAt: Date? = nil, unseen: Bool = false, permissionStamp: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.project = project
        self.state = state
        self.detail = detail
        self.updatedAt = updatedAt
        self.unseen = unseen
        self.permissionStamp = permissionStamp
    }

    public var needsAttention: Bool { state.isBlocked || (state == .idle && unseen) }

    /// Identifies one attention-worthy moment: a second permission request in the same turn has
    /// a new timestamp and notifies again. nil when nothing needs the user.
    public var attentionKey: String? {
        guard needsAttention else { return nil }
        return "\(state.rawValue)|\(updatedAt?.timeIntervalSince1970 ?? 0)"
    }
}

extension RemoteSnapshot {
    /// Sessions that need the user in `new` and didn't (for the same reason) in `old`.
    /// The first snapshot after connecting (`old == nil`) is a baseline: nothing to announce.
    public static func newAttention(from old: RemoteSnapshot?, to new: RemoteSnapshot) -> [RemoteSession] {
        guard let old else { return [] }
        return new.sessions.filter { session in
            guard let key = session.attentionKey else { return false }
            return old.session(session.id)?.attentionKey != key
        }
    }
}

// MARK: Handshake

/// Mutual proof of the pairing key. Each side signs both nonces with its own role label, so a
/// proof can't be replayed in the other direction or in another connection.
public enum RemoteHandshake {
    public static func makeNonce() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    public static func proof(key: Data, role: String, first: Data, second: Data) -> Data {
        var message = Data(role.utf8)
        message.append(0)
        message.append(first)
        message.append(second)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    public static func hostProof(key: Data, remoteNonce: Data, hostNonce: Data) -> Data {
        proof(key: key, role: "claudedeck-host", first: remoteNonce, second: hostNonce)
    }

    public static func remoteProof(key: Data, remoteNonce: Data, hostNonce: Data) -> Data {
        proof(key: key, role: "claudedeck-remote", first: hostNonce, second: remoteNonce)
    }

    /// The pairing key for a password typed on both Macs (PBKDF2-SHA256). The salt is fixed so
    /// both sides derive the same key without talking first; the connection only exists inside
    /// the tailnet, and the host throttles wrong guesses.
    public static func key(fromPassword password: String, rounds: UInt32 = 300_000) -> Data {
        let salt = Data("claudedeck-remote-v1".utf8)
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8).map { CChar(bitPattern: $0) }
        var key = Data(count: 32)
        let keyCount = key.count
        let status = key.withUnsafeMutableBytes { keyBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, passwordBytes.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                    keyBuffer.bindMemory(to: UInt8.self).baseAddress, keyCount
                )
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return key
    }

    public static let minimumPasswordLength = 8

    /// Constant-time comparison.
    public static func matches(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

// MARK: Pairing

/// Everything a remote needs to reach a host: shared through iCloud Drive, or as a QR code /
/// copyable `claudedeck://pair?…` link.
public struct RemotePairing: Codable, Sendable, Equatable, Identifiable {
    /// Stable id of the host Mac (survives renames and key changes).
    public var id: UUID
    public var hostName: String
    /// Tailscale MagicDNS name first, then Tailscale IPs.
    public var addresses: [String]
    public var port: UInt16
    public var key: Data
    public var updatedAt: Date

    public init(id: UUID, hostName: String, addresses: [String], port: UInt16, key: Data, updatedAt: Date) {
        self.id = id
        self.hostName = hostName
        self.addresses = addresses
        self.port = port
        self.key = key
        self.updatedAt = updatedAt
    }

    public static let defaultPort: UInt16 = 47821

    public static func makeKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> RemotePairing {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(RemotePairing.self, from: data)
    }

    /// `claudedeck://pair?d=<base64url JSON>` — the QR code's and the copy button's content.
    public func link() throws -> String {
        let encoded = try encoded().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "claudedeck://pair?d=\(encoded)"
    }

    /// Accepts the link, with surrounding whitespace (pasted text).
    public static func parse(link: String) -> RemotePairing? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme == "claudedeck",
              components.host == "pair",
              var base64 = components.queryItems?.first(where: { $0.name == "d" })?.value
        else { return nil }
        base64 = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let pairing = try? decode(data),
              !pairing.key.isEmpty, !pairing.addresses.isEmpty
        else { return nil }
        return pairing
    }
}

// MARK: Local state

/// This Mac's remote-mode identity and pairing, in `remote.json` next to `deck.json` (0600; it
/// holds keys, so it is kept out of deck.json).
public struct RemoteLocalState: Codable, Sendable, Equatable {
    /// Stable id of this Mac as a host.
    public var hostID = UUID()
    /// The key remotes must prove (host side). Replaced by "New key".
    public var hostKey = RemotePairing.makeKey()
    /// Host chosen among the ones found in iCloud Drive (remote side).
    public var pairedHostID: UUID?
    /// Pairing pasted from a link / QR code; wins over iCloud Drive.
    public var manualPairing: RemotePairing?
    /// Host side: `hostKey` was derived from a password the user chose.
    public var hostUsesPassword = false
    /// Remote side: key derived from the password typed here (finds the host through Tailscale).
    public var passwordKey: Data?
    /// Remote side: the address the password-found host answered on last time (tried first).
    public var lastHostAddress: String?
    /// Host side: the APNs auth key for iPhone pushes, and the phones that registered.
    public var apns: APNsCredentials?
    public var pushDevices: [PushDevice] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RemoteLocalState()
        hostID = try c.decodeIfPresent(UUID.self, forKey: .hostID) ?? d.hostID
        hostKey = try c.decodeIfPresent(Data.self, forKey: .hostKey).flatMap { $0.isEmpty ? nil : $0 } ?? d.hostKey
        pairedHostID = try c.decodeIfPresent(UUID.self, forKey: .pairedHostID)
        manualPairing = try c.decodeIfPresent(RemotePairing.self, forKey: .manualPairing)
        hostUsesPassword = try c.decodeIfPresent(Bool.self, forKey: .hostUsesPassword) ?? false
        passwordKey = try c.decodeIfPresent(Data.self, forKey: .passwordKey)
        lastHostAddress = try c.decodeIfPresent(String.self, forKey: .lastHostAddress)
        apns = try c.decodeIfPresent(APNsCredentials.self, forKey: .apns)
        pushDevices = try c.decodeIfPresent([PushDevice].self, forKey: .pushDevices) ?? []
    }

    /// Loads the file, or creates (and saves) a fresh identity. The key stays the same across
    /// launches; only "New Key" replaces it. An unreadable file is kept aside, not overwritten silently.
    public static func load(from url: URL) -> RemoteLocalState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: url) {
            if let state = try? decoder.decode(RemoteLocalState.self, from: data) { return state }
            let broken = url.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: broken)
        }
        let state = RemoteLocalState()
        try? state.save(to: url)
        return state
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

#if os(macOS)
/// Pairing records in a shared folder (iCloud Drive `ClaudeDeck/Remote/<host id>.json`).
public enum RemotePairingFolder {
    public static func defaultFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard DeckSyncFile.iCloudDriveAvailable(home: home) else { return nil }
        return DeckSyncFile.iCloudDriveRoot(home: home).appending(path: "ClaudeDeck/Remote")
    }

    public static func readAll(in folder: URL) -> [RemotePairing] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            // Not downloaded yet (".<id>.json.icloud"): ask for it; the folder watcher fires when it lands.
            if url.lastPathComponent.hasPrefix("."), url.pathExtension == "icloud" {
                let name = String(url.deletingPathExtension().lastPathComponent.dropFirst())
                try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appending(path: name))
                return nil
            }
            guard url.pathExtension == "json", !url.lastPathComponent.hasPrefix("."),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? RemotePairing.decode(data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func url(for id: UUID, in folder: URL) -> URL {
        folder.appending(path: "\(id.uuidString).json")
    }

    /// Writes only when the content changed (an iCloud upload per write).
    public static func write(_ pairing: RemotePairing, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = url(for: pairing.id, in: folder)
        if let data = try? Data(contentsOf: url), var existing = try? RemotePairing.decode(data) {
            existing.updatedAt = pairing.updatedAt
            if existing == pairing { return }
        }
        try pairing.encoded().write(to: url, options: .atomic)
    }

    public static func remove(_ id: UUID, in folder: URL) {
        try? FileManager.default.removeItem(at: url(for: id, in: folder))
    }
}
#endif
