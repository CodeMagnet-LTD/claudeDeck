import ClaudeDeckCore
import Foundation

/// The prompt queue: messages for a Claude session that go in one per turn, when it's the user's
/// turn ("your turn"), oldest first. Kept in the deck, so the Mac and remotes see the same queue.
extension AppModel {
    /// A message for the queue. It's the user's turn already and nothing is queued: it goes in now.
    func enqueue(_ id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, deck.session(id)?.kind == .claude else { return }
        mutate(userInitiated: false) { $0.updateSession(id) { $0.queue.append(QueuedPrompt(text: trimmed)) } }
        drainQueues()
    }

    func queueAction(_ id: UUID, prompt: UUID, action: QueueAction) {
        guard let session = deck.session(id) else { return }
        // Not into a permission prompt or a question: it stays queued.
        if action == .sendNow, !terminals.isRunning(id) || status(of: id).display.isBlocked { return }
        let result = session.queue.applying(action, to: prompt)
        mutate(userInitiated: false) { $0.updateSession(id) { $0.queue = result.queue } }
        if let sent = result.sent { typePrompt(sent.text, into: id) }
    }

    /// Sends the next queued message of each session whose turn it is. Called on every status
    /// change; a message that went in holds the next one until Claude starts on it (or 45 s pass,
    /// in case it never showed as working).
    func drainQueues() {
        for session in deck.sessions where !session.queue.isEmpty && session.kind == .claude {
            let id = session.id
            guard terminals.isRunning(id) else { continue }
            let display = status(of: id).display
            if let sentAt = queueAwaiting[id] {
                if display.isRunning || display.isBlocked || Date().timeIntervalSince(sentAt) > 45 {
                    queueAwaiting[id] = nil
                } else {
                    continue
                }
            }
            guard display.isIdle, let next = session.queue.first else { continue }
            mutate(userInitiated: false) { $0.updateSession(id) { $0.queue.removeFirst() } }
            queueAwaiting[id] = Date()
            typePrompt(next.text, into: id)
        }
    }

    /// Types a message and presses Return (Claude Code queues it itself while working).
    func typePrompt(_ text: String, into id: UUID) {
        guard terminals.isRunning(id), !status(of: id).display.isBlocked else { return }
        terminals.type(text + "\r", into: id)
        markSeen(id)
    }
}
