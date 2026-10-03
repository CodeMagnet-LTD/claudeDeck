import Foundation

/// Sends this phone's APNs token to the Mac after every connect; the Mac pushes alerts with it
/// while the app is closed (APNs.swift on the Mac).
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()
    var token: Data?
    /// Why APNs gave no token (diagnostics).
    var lastError: String?

    func register(with store: RemoteStore) {
        guard let token, let topic = Bundle.main.bundleIdentifier else { return }
        _ = store.send(.registerPush(token: token, topic: topic, environment: Self.environment, deviceName: RemoteStore.deviceName))
    }

    /// The APNs environment this build is signed for: Xcode builds get development (sandbox),
    /// TestFlight / App Store production. Read from the provisioning profile; App Store builds
    /// carry none and are production.
    static let environment: String = {
        #if targetEnvironment(simulator)
        return "development"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return "production" }
        // The profile is a CMS blob with a plist inside.
        guard let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String
        else { return "development" }
        return environment
        #endif
    }()
}
