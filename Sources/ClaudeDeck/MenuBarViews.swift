import ClaudeDeckCore
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let c = model.counts
        HStack(spacing: 3) {
            Image(systemName: c.blocked > 0 ? "exclamationmark.bubble.fill" : "rectangle.stack")
            if c.blocked > 0 { Text("\(c.blocked)") }
            if c.running > 0 { Text("▶\(c.running)") }
            if c.unseen > 0 { Text("●\(c.unseen)") }
        }
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let c = model.counts
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ClaudeDeck").font(.headline)
                Spacer()
                counter(c.blocked, StatusStyle.blocked, "bekliyor")
                counter(c.running, StatusStyle.running, "çalışıyor")
                counter(c.unseen, StatusStyle.idle, "sıra sende")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let sessions = orderedSessions
                    if sessions.isEmpty {
                        Text("Oturum yok").foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(sessions) { session in
                        MenuSessionRow(session: session) {
                            model.openMainWindow?()
                            model.reveal(session.id)
                            dismiss()
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 420)
            Divider()
            HStack {
                Button("Pencereyi aç") {
                    openWindow(id: "main")
                    NSApp.activate()
                    dismiss()
                }
                Spacer()
                Button("Çık") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .frame(width: 340)
    }

    /// Needs-attention first, then running, then the rest by recent activity.
    private var orderedSessions: [DeckSession] {
        func rank(_ s: DeckSession) -> Int {
            let d = model.status(of: s.id).display
            if d.isBlocked { return 0 }
            if model.isUnseenIdle(s.id) { return 1 }
            if d.isRunning { return 2 }
            if d.isIdle || d == .starting { return 3 }
            return 4
        }
        return model.deck.sessions.sorted {
            let (a, b) = (rank($0), rank($1))
            if a != b { return a < b }
            return (model.status(of: $0.id).updatedAt ?? .distantPast) > (model.status(of: $1.id).updatedAt ?? .distantPast)
        }
    }

    private func counter(_ n: Int, _ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(n)").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(n > 0 ? .primary : .tertiary)
        .help(label)
    }
}

struct MenuSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let status = model.status(of: session.id)
        Button(action: action) {
            HStack(spacing: 8) {
                StatusDot(display: status.display, unseen: model.isUnseenIdle(session.id))
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name).lineLimit(1)
                    if let detail = status.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let at = status.updatedAt {
                    Text(RelativeTime.short(at)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
