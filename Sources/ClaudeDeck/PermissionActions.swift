import ClaudeDeckCore
import Foundation
import SwiftUI

/// Stamps of prompts already denied from the app: Esc leaves the state blocked until the
/// transcript records the denial, and a second Esc at Claude's prompt would open the rewind picker.
@MainActor private var deniedStamps: [UUID: Date] = [:]

/// Approving / denying a permission prompt from a notification or a button. The app owns the pty,
/// so it types exactly what the user would: "1" (Yes) or Esc (No). State follows from the
/// existing paths — `userTyped` records the digit as an answer, the transcript records the denial.
extension AppModel {
    /// Hook timestamp of the permission prompt the session is showing right now, if it can be
    /// answered with a keystroke. Identifies that one prompt: a newer request gets a new stamp.
    func pendingPermissionStamp(_ id: UUID) -> Date? {
        guard deck.session(id)?.kind == .claude, terminals.isRunning(id),
              status(of: id).display == .activity(.needsPermission),
              let hook = hookStatuses[id]
        else { return nil }
        // Plan approval: option 1 also switches the permission mode — only in the terminal.
        // A later Notification event drops tool_name but keeps the detail ("ExitPlanMode…").
        if hook.toolName == "ExitPlanMode" || hook.detail?.hasPrefix("ExitPlanMode") == true { return nil }
        return hook.updatedAt
    }

    @discardableResult
    func approvePermission(_ id: UUID, expectedAt: Date?) -> Bool {
        guard matchingStamp(id, expectedAt) != nil else { return false }
        terminals.type("1", into: id)
        return true
    }

    @discardableResult
    func denyPermission(_ id: UUID, expectedAt: Date?) -> Bool {
        guard let stamp = matchingStamp(id, expectedAt), deniedStamps[id].map({ !Self.same($0, stamp) }) ?? true else {
            return false
        }
        deniedStamps[id] = stamp
        terminals.type("\u{1b}", into: id)
        return true
    }

    /// The pending stamp, only if it is the prompt the caller saw.
    private func matchingStamp(_ id: UUID, _ expectedAt: Date?) -> Date? {
        guard let expectedAt, let stamp = pendingPermissionStamp(id), Self.same(stamp, expectedAt) else { return nil }
        return stamp
    }

    /// Notification userInfo round-trips the stamp through a Double; allow for rounding.
    private static func same(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.001 }
}

/// "İzin ver" / "Reddet" for a session showing a permission prompt; empty otherwise.
struct PermissionButtons: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID

    var body: some View {
        if let stamp = model.pendingPermissionStamp(sessionID) {
            HStack(spacing: 6) {
                Button("İzin ver") { model.approvePermission(sessionID, expectedAt: stamp) }
                    .buttonStyle(.borderedProminent)
                    .help("Terminalde 1'e (Evet) basar")
                Button("Reddet", role: .destructive) { model.denyPermission(sessionID, expectedAt: stamp) }
                    .buttonStyle(.bordered)
                    .help("Terminalde Esc'ye basar")
            }
            .controlSize(.small)
        }
    }
}
