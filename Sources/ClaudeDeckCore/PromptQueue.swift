import Foundation

/// A message for a Claude session that goes in when it's the user's turn (the prompt queue).
public struct QueuedPrompt: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// What can be done to a queued message.
public enum QueueAction: Codable, Sendable, Equatable {
    case remove
    case edit(String)
    /// Typed in now, while Claude works (Claude Code takes it in at its next step).
    case sendNow
    case moveUp
}

extension [QueuedPrompt] {
    /// The queue after `action` on `id`; `sent` is the message to type in now (`sendNow`).
    public func applying(_ action: QueueAction, to id: UUID) -> (queue: [QueuedPrompt], sent: QueuedPrompt?) {
        guard let index = firstIndex(where: { $0.id == id }) else { return (self, nil) }
        var queue = self
        switch action {
        case .remove:
            queue.remove(at: index)
        case .edit(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { queue.remove(at: index) } else { queue[index].text = trimmed }
        case .sendNow:
            let sent = queue.remove(at: index)
            return (queue, sent)
        case .moveUp:
            if index > 0 { queue.swapAt(index, index - 1) }
        }
        return (queue, nil)
    }
}
