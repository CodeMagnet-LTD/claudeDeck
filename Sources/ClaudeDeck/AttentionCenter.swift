import AppKit
import ClaudeDeckCore
import UserNotifications

/// Notifications, Dock badge and Dock bounce for session state changes.
@MainActor
final class AttentionCenter: NSObject, UNUserNotificationCenterDelegate {
    private let model: AppModel
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        model.onAttention = { [weak self] event in self?.handle(event) }
        model.onCountsChanged = { [weak self] in self?.updateBadge() }
    }

    private func handle(_ event: AttentionEvent) {
        updateBadge()
        // The user is already looking at this terminal (it's in a visible pane).
        if model.isVisible(event.sessionID) { return }
        let settings = model.deck.settings

        if settings.bounceDock, !NSApp.isActive {
            NSApp.requestUserAttention(event.activity.isBlocked ? .criticalRequest : .informationalRequest)
        }
        guard settings.notifications, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = event.activity.isBlocked ? .default : nil
        content.userInfo = ["sessionID": event.sessionID.uuidString]
        content.threadIdentifier = event.sessionID.uuidString
        content.interruptionLevel = event.activity.isBlocked ? .timeSensitive : .active
        // One notification per session: a newer state replaces the older one.
        let request = UNNotificationRequest(identifier: event.sessionID.uuidString, content: content, trigger: nil)
        center.add(request)
    }

    func updateBadge() {
        let counts = model.counts
        let waiting = counts.blocked + counts.unseen
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
        let seen = model.deck.visiblePanes.filter { model.isVisible($0) && !model.needsAttention($0) }
        if !seen.isEmpty { center?.removeDeliveredNotifications(withIdentifiers: seen.map(\.uuidString)) }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["sessionID"] as? String
        guard let raw, let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            self.model.openMainWindow?()
            self.model.reveal(id)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // App in front but a different session selected: still show the banner.
        [.banner, .sound, .list]
    }
}
