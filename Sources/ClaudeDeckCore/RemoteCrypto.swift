import CryptoKit
import Foundation

// Encryption of a remote connection after the handshake. Tailscale already encrypts its tunnel,
// but on the local network the connection is plain TCP: everything after the handshake (screens,
// keystrokes, prompts) goes in sealed frames on every path, so there is a single protocol.
//
// Keys: HKDF-SHA256 of the pairing key, salted with both handshake nonces (fresh per connection),
// one key per direction. Nonce: a per-direction frame counter, so frames can't be replayed,
// dropped or reordered without the next one failing to open.

public struct RemoteCipher: Sendable {
    public enum Role: Sendable { case host, remote }
    public enum CipherError: Error, Equatable { case sealFailed, openFailed }

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    public init(pairingKey: Data, remoteNonce: Data, hostNonce: Data, role: Role) {
        let salt = remoteNonce + hostNonce
        func key(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: pairingKey), salt: salt,
                info: Data("claudedeck-v2 \(label)".utf8), outputByteCount: 32
            )
        }
        let hostToRemote = key("host->remote")
        let remoteToHost = key("remote->host")
        sendKey = role == .host ? hostToRemote : remoteToHost
        receiveKey = role == .host ? remoteToHost : hostToRemote
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// The inner frame (kind + payload) sealed into a `.sealed` frame.
    public mutating func seal(_ frame: RemoteFrame) throws -> RemoteFrame {
        var plain = Data([frame.kind])
        plain.append(frame.payload)
        guard let box = try? ChaChaPoly.seal(plain, using: sendKey, nonce: Self.nonce(sendCounter)) else { throw CipherError.sealFailed }
        sendCounter += 1
        return RemoteFrame(kind: RemoteFrameKind.sealed.rawValue, payload: box.ciphertext + box.tag)
    }

    public mutating func open(_ frame: RemoteFrame) throws -> RemoteFrame {
        guard frame.kind == RemoteFrameKind.sealed.rawValue, frame.payload.count >= 17 else { throw CipherError.openFailed }
        let payload = frame.payload
        let tagStart = payload.endIndex - 16
        guard let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(receiveCounter), ciphertext: payload[payload.startIndex..<tagStart], tag: payload[tagStart...]),
              let plain = try? ChaChaPoly.open(box, using: receiveKey), let kind = plain.first
        else { throw CipherError.openFailed }
        receiveCounter += 1
        return RemoteFrame(kind: kind, payload: Data(plain.dropFirst()))
    }
}
