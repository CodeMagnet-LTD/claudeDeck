import AppKit
import ClaudeDeckCore
import WidgetKit

/// Feeds the desktop widget: writes a small status snapshot into the App Group container
/// whenever the session counts change (debounced) and asks WidgetKit to reload.
/// Does nothing when the app isn't entitled to the App Group (SwiftPM build).
@MainActor
final class WidgetBridge {
    private let model: AppModel
    private let fileURL = WidgetSnapshot.sharedFileURL()
    private var pending: Task<Void, Never>?
    private var last: WidgetSnapshot?

    init(model: AppModel) {
        self.model = model
    }

    /// Chains onto `model.onCountsChanged` without replacing the existing handler.
    func attach() {
        guard fileURL != nil else { return }
        let previous = model.onCountsChanged
        model.onCountsChanged = { [weak self] in
            previous?()
            self?.schedule()
        }
        schedule()
    }

    func schedule() {
        guard fileURL != nil else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.publish(self?.makeSnapshot())
        }
    }

    /// On quit: the terminals are gone, so the widget should say so.
    func publishQuit() {
        pending?.cancel()
        publish(WidgetSnapshot(appRunning: false))
    }

    private func makeSnapshot() -> WidgetSnapshot {
        let counts = model.counts
        let items: [WidgetSnapshot.Item] = model.attentionSessions.prefix(4).compactMap { session in
            let status = model.status(of: session.id)
            guard let activity = status.display.activityValue, let state = WidgetSnapshot.State(activity) else { return nil }
            return WidgetSnapshot.Item(
                id: session.id,
                name: session.name,
                project: model.deck.project(session.projectID)?.name ?? "",
                state: state,
                detail: status.detail.map { String($0.prefix(120)) },
                updatedAt: status.updatedAt
            )
        }
        return WidgetSnapshot(blocked: counts.blocked, running: counts.running, unseen: counts.unseen, items: items)
    }

    private func publish(_ snapshot: WidgetSnapshot?) {
        guard let snapshot, let fileURL else { return }
        if let last, last.sameContent(as: snapshot) { return }
        do {
            try snapshot.write(to: fileURL)
            last = snapshot
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // The widget keeps showing the previous snapshot; nothing else to do.
        }
    }

    /// `claudedeck://session/<uuid>` (widget taps): bring that session forward.
    static func handle(_ url: URL, model: AppModel) {
        model.openMainWindow?()
        NSApp.activate()
        guard let id = WidgetSnapshot.sessionID(from: url), model.deck.session(id) != nil else { return }
        model.reveal(id)
    }
}

private extension WidgetSnapshot.State {
    init?(_ activity: SessionActivity) {
        switch activity {
        case .needsPermission: self = .needsPermission
        case .needsAnswer: self = .needsAnswer
        case .idle: self = .idle
        case .running: self = .running
        case .ended: return nil
        }
    }
}
