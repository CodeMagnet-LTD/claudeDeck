import ClaudeDeckCore
import SwiftUI

enum StatusStyle {
    static let running = Color.green
    static let blocked = Color.red
    static let idle = Color.yellow
    static let inactive = Color.secondary.opacity(0.5)

    static func color(for display: DisplayState) -> Color {
        switch display {
        case .activity(.running): running
        case .activity(.needsPermission), .activity(.needsAnswer): blocked
        case .activity(.idle): idle
        case .starting: running.opacity(0.5)
        case .notStarted, .activity(.ended): inactive
        }
    }
}

struct StatusDot: View {
    let display: DisplayState
    var unseen = false
    @State private var pulse = false

    var body: some View {
        let color = StatusStyle.color(for: display)
        ZStack {
            if display.isBlocked || display.isRunning {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1 : 0.5)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: display.isBlocked ? 1.0 : 1.6).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay {
                    if display.isIdle && !unseen {
                        Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 3, height: 3)
                    }
                }
        }
        .frame(width: 14, height: 14)
        .onAppear { pulse = true }
        .accessibilityLabel(Text(accessibility))
    }

    private var accessibility: String {
        switch display {
        case .activity(.running): "Çalışıyor"
        case .activity(.needsPermission): "İzin bekliyor"
        case .activity(.needsAnswer): "Cevap bekliyor"
        case .activity(.idle): "Sıra sende"
        case .activity(.ended), .notStarted: "Durdu"
        case .starting: "Başlıyor"
        }
    }
}

/// Worst state among sessions: red > green > unseen yellow.
struct AggregateBadge: View {
    @Environment(AppModel.self) private var model
    let sessionIDs: [UUID]

    var body: some View {
        let blocked = sessionIDs.filter { model.status(of: $0).display.isBlocked }.count
        let running = sessionIDs.filter { model.status(of: $0).display.isRunning }.count
        let unseen = sessionIDs.filter { model.isUnseenIdle($0) }.count
        HStack(spacing: 4) {
            if blocked > 0 { pill(blocked, StatusStyle.blocked) }
            if running > 0 { pill(running, StatusStyle.running) }
            if unseen > 0 { pill(unseen, StatusStyle.idle) }
        }
    }

    private func pill(_ n: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(n)").font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.secondary)
    }
}

enum GroupPalette {
    static let colors: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .teal]
    static let names = ["Mavi", "Mor", "Pembe", "Kırmızı", "Turuncu", "Sarı", "Yeşil", "Turkuaz"]
    static var count: Int { colors.count }
    static func color(_ i: Int) -> Color { colors[((i % count) + count) % count] }
}

enum RelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<10: return "şimdi"
        case ..<60: return "\(s) sn"
        case ..<3600: return "\(s / 60) dk"
        case ..<86400: return "\(s / 3600) sa"
        default: return "\(s / 86400) g"
        }
    }
}
