import ClaudeDeckCore
import SwiftUI

/// Under a session's terminal: the messages waiting for its next turns, with edit, move up,
/// send now and remove.
struct QueueStrip: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward").foregroundStyle(.secondary)
                Text("Queue · \(session.queue.count)").font(.caption.weight(.semibold))
                Text("Sent one at a time, when it's your turn").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button { QueueStrip.askToQueue(session.id, model: model) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Queue a Message…")
            }
            ForEach(Array(session.queue.enumerated()), id: \.element.id) { index, prompt in
                HStack(spacing: 6) {
                    Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(prompt.text).font(.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Button { edit(prompt) } label: { Image(systemName: "pencil") }
                        .help("Edit")
                    if index > 0 {
                        Button { model.queueAction(session.id, prompt: prompt.id, action: .moveUp) } label: { Image(systemName: "arrow.up") }
                            .help("Move Up")
                    }
                    Button { model.queueAction(session.id, prompt: prompt.id, action: .sendNow) } label: { Image(systemName: "paperplane") }
                        .help("Send Now (Claude takes it in while working)")
                    Button { model.queueAction(session.id, prompt: prompt.id, action: .remove) } label: { Image(systemName: "xmark") }
                        .help("Remove")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func edit(_ prompt: QueuedPrompt) {
        if let text = TextPrompt.ask(title: String(localized: "Edit Queued Message"), placeholder: String(localized: "Message"), initial: prompt.text) {
            model.queueAction(session.id, prompt: prompt.id, action: .edit(text))
        }
    }

    /// A message for the queue (it goes in at once when it's already the user's turn).
    static func askToQueue(_ id: UUID, model: AppModel) {
        if let text = TextPrompt.ask(title: String(localized: "Queue a Message"), placeholder: String(localized: "Sent when it's your turn")) {
            model.enqueue(id, text: text)
        }
    }
}
