import CryptoKit
import Foundation

// Push notifications to the iPhone app, sent by the hosting Mac straight to Apple (no server).
// The user adds their APNs auth key (.p8) in Settings › Remote; the phone registers its device
// token over the remote connection (`RemoteMessage.registerPush`).

/// A phone that wants pushes.
public struct PushDevice: Codable, Sendable, Equatable, Identifiable {
    public var token: Data
    /// The iPhone app's bundle id (`apns-topic`).
    public var topic: String
    /// "development" (Xcode builds) or "production" (TestFlight / App Store).
    public var environment: String
    public var name: String
    public var addedAt: Date

    public var id: Data { token }

    public init(token: Data, topic: String, environment: String, name: String, addedAt: Date) {
        self.token = token
        self.topic = topic
        self.environment = environment
        self.name = name
        self.addedAt = addedAt
    }

    public var tokenHex: String { token.map { String(format: "%02x", $0) }.joined() }
}

/// The APNs auth key from the Apple Developer account.
public struct APNsCredentials: Codable, Sendable, Equatable {
    public var keyID: String
    public var teamID: String
    /// Contents of the .p8 file (PKCS#8 PEM).
    public var keyPEM: String

    public init(keyID: String, teamID: String, keyPEM: String) {
        self.keyID = keyID
        self.teamID = teamID
        self.keyPEM = keyPEM
    }

    public var isValid: Bool { (try? P256.Signing.PrivateKey(pemRepresentation: keyPEM)) != nil && !keyID.isEmpty && !teamID.isEmpty }
}

public enum APNs {
    /// ES256 provider token (header.claims.signature, base64url).
    public static func token(_ credentials: APNsCredentials, issuedAt: Date) throws -> String {
        let key = try P256.Signing.PrivateKey(pemRepresentation: credentials.keyPEM)
        let header = #"{"alg":"ES256","kid":"\#(credentials.keyID)"}"#
        let claims = #"{"iss":"\#(credentials.teamID)","iat":\#(Int(issuedAt.timeIntervalSince1970))}"#
        let signingInput = base64url(Data(header.utf8)) + "." + base64url(Data(claims.utf8))
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64url(signature.rawRepresentation)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The alert for a session that needs the user. `stamp` (a string: the payload goes through
    /// APNs as JSON) lets the phone's Allow / Deny answer exactly that prompt.
    public static func payload(title: String, subtitle: String?, body: String, sessionID: UUID, permissionStamp: Double?, blocked: Bool) -> Data {
        var alert: [String: Any] = ["title": title, "body": body]
        if let subtitle { alert["subtitle"] = subtitle }
        var aps: [String: Any] = ["alert": alert, "thread-id": sessionID.uuidString]
        if blocked { aps["sound"] = "default" }
        var root: [String: Any] = ["sessionID": sessionID.uuidString]
        if let permissionStamp {
            aps["category"] = "permission"
            root["stamp"] = String(permissionStamp)
        }
        root["aps"] = aps
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }

    public static func host(for environment: String) -> String {
        environment == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
    }

    public enum Result: Sendable, Equatable {
        case sent
        /// The device token is gone (app removed, token changed): forget the device.
        case unregistered
        case failed(String)
    }

    /// One push over HTTP/2. `collapseID` replaces an older alert of the same session.
    public static func send(_ payload: Data, to device: PushDevice, token: String, collapseID: String, session: URLSession = .shared) async -> Result {
        guard let url = URL(string: "https://\(host(for: device.environment))/3/device/\(device.tokenHex)") else { return .failed("bad url") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(device.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(String(collapseID.prefix(64)), forHTTPHeaderField: "apns-collapse-id")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return .sent }
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String ?? "HTTP \(status)"
            if status == 410 || reason == "BadDeviceToken" || reason == "Unregistered" || reason == "DeviceTokenNotForTopic" { return .unregistered }
            return .failed(reason)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
