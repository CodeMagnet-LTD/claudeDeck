import SwiftUI
import UserNotifications

@main
struct ClaudeDeckRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.store)
                .onOpenURL { url in delegate.store.pair(link: url.absoluteString) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Inactive (a system alert, Notification Center pulled down) still counts as in front.
                    delegate.store.setActive(phase != .background)
                }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = RemoteStore()
    private var debug: DebugHooks?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        LocalAlerts.registerCategories()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        // The token doesn't depend on the alert permission; the Mac needs it either way.
        application.registerForRemoteNotifications()
        store.onConnected = { [weak store] in
            guard let store else { return }
            PushRegistration.shared.register(with: store)
        }
        debug = DebugHooks.startIfRequested(store: store)
        return true
    }

    // MARK: Push registration (the Mac sends the pushes, see PushRegistration)

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistration.shared.token = deviceToken
        PushRegistration.shared.register(with: store)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushRegistration.shared.lastError = error.localizedDescription
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Allow / Deny on a notification: connect, answer, wait for the Mac (iOS gives us ~30 s).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info["sessionID"] as? String, let id = UUID(uuidString: raw) else { return }
        let stamp = (info["stamp"] as? String).flatMap(Double.init) ?? (info["stamp"] as? Double)
        let action = response.actionIdentifier
        await MainActor.run {
            if action == UNNotificationDefaultActionIdentifier { store.path = [id] }
        }
        guard action == LocalAlerts.approveAction || action == LocalAlerts.denyAction, let stamp else { return }
        let applied = await store.answerAndWait(id, stamp: stamp, approve: action == LocalAlerts.approveAction)
        if !applied {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Couldn't answer")
            content.body = String(localized: "That prompt was already answered or changed on the other Mac.")
            try? await center.add(UNNotificationRequest(identifier: "answer-failed-\(raw)", content: content, trigger: nil))
        }
    }
}
