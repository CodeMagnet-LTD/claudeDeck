import AppKit
import ClaudeDeckCore
import UserNotifications

/// Notifications, Dock badge and Dock bounce for session state changes.
@MainActor
final class AttentionCenter: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let permissionCategory = "permission"
    nonisolated static let approveAction = "approve"
    nonisolated static let denyAction = "deny"
    private let model: AppModel
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        center?.delegate = self
        // Answered in place: the keystroke goes into the terminal, no need to bring the app up.
        center?.setNotificationCategories([UNNotificationCategory(
            identifier: Self.permissionCategory,
            actions: [
                UNNotificationAction(identifier: Self.approveAction, title: String(localized: "Allow"), options: []),
                UNNotificationAction(identifier: Self.denyAction, title: String(localized: "Deny"), options: [.destructive]),
            ],
            intentIdentifiers: []
        )])
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        model.onAttention = { [weak self] event in self?.handle(event) }
        model.remote.onAttention = { [weak self] session, hostName in self?.handleRemote(session, hostName: hostName) }
        model.remote.onAttentionCleared = { [weak self] ids in
            self?.center?.removeDeliveredNotifications(withIdentifiers: ids.map { "remote-\($0.uuidString)" })
        }
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
        // The stamp ties the actions to this prompt; a later one must not be answered by them.
        if event.activity == .needsPermission, let stamp = model.pendingPermissionStamp(event.sessionID) {
            content.categoryIdentifier = Self.permissionCategory
            content.userInfo["stamp"] = stamp.timeIntervalSince1970
        }
        content.threadIdentifier = event.sessionID.uuidString
        content.interruptionLevel = event.activity.isBlocked ? .timeSensitive : .active
        // One notification per session: a newer state replaces the older one.
        let request = UNNotificationRequest(identifier: event.sessionID.uuidString, content: content, trigger: nil)
        center.add(request)
    }

    /// A session on the paired Mac needs the user. Answers go back over the connection.
    private func handleRemote(_ session: RemoteSession, hostName: String) {
        updateBadge()
        let settings = model.deck.settings
        if settings.bounceDock, !NSApp.isActive {
            NSApp.requestUserAttention(session.state.isBlocked ? .criticalRequest : .informationalRequest)
        }
        guard settings.notifications, let center else { return }
        let content = UNMutableNotificationContent()
        let name = session.name == session.project || session.project.isEmpty ? session.name : "\(session.name) — \(session.project)"
        content.title = "\(name) · \(hostName)"
        content.body = switch session.state {
        case .needsPermission: String(localized: "Needs permission") + (session.detail.map { ": \($0)" } ?? "")
        case .needsAnswer: String(localized: "Asking a question") + (session.detail.map { ": \($0)" } ?? "")
        default: session.detail.map { String(localized: "Done — \($0)") } ?? String(localized: "Done — your turn")
        }
        content.sound = session.state.isBlocked ? .default : nil
        content.userInfo = ["sessionID": session.id.uuidString, "remote": true]
        if let stamp = session.permissionStamp {
            content.categoryIdentifier = Self.permissionCategory
            content.userInfo["stamp"] = stamp
        }
        content.threadIdentifier = "remote-\(session.id.uuidString)"
        content.interruptionLevel = session.state.isBlocked ? .timeSensitive : .active
        center.add(UNNotificationRequest(identifier: "remote-\(session.id.uuidString)", content: content, trigger: nil))
    }

    func updateBadge() {
        let counts = model.counts
        let waiting = counts.blocked + counts.unseen + model.remote.attentionCount
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
        let seen = model.deck.visiblePanes.filter { model.isVisible($0) && !model.needsAttention($0) }
        if !seen.isEmpty { center?.removeDeliveredNotifications(withIdentifiers: seen.map(\.uuidString)) }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let raw = userInfo["sessionID"] as? String
        guard let raw, let id = UUID(uuidString: raw) else { return }
        let action = response.actionIdentifier
        let rawStamp = userInfo["stamp"] as? Double
        let stamp = rawStamp.map { Date(timeIntervalSince1970: $0) }
        let remote = userInfo["remote"] as? Bool ?? false
        await MainActor.run {
            if remote {
                let approve = action == Self.approveAction
                if action == Self.approveAction || action == Self.denyAction,
                   self.model.remote.answer(id, stamp: rawStamp, approve: approve) { return }
                self.model.openMainWindow?()
                NSApp.activate()
                return
            }
            // Only if that same prompt is still open; otherwise show the session instead.
            if action == Self.approveAction, self.model.approvePermission(id, expectedAt: stamp) { return }
            if action == Self.denyAction, self.model.denyPermission(id, expectedAt: stamp) { return }
            self.model.openMainWindow?()
            self.model.reveal(id)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // App in front but a different session selected: still show the banner.
        [.banner, .sound, .list]
    }
}
