import ClaudeDeckCore
import SwiftUI

enum StatusStyle {
    static let running = Color.green
    static let blocked = Color.red
    static let idle = Color.yellow
    static let inactive = Color.secondary.opacity(0.5)

    static func label(for display: DisplayState) -> String {
        switch display {
        case .notStarted, .activity(.ended): String(localized: "Stopped")
        case .starting: String(localized: "Starting")
        case .shell: String(localized: "Terminal")
        case .activity(.running): String(localized: "Running")
        case .activity(.needsPermission): String(localized: "Needs permission")
        case .activity(.needsAnswer): String(localized: "Asking a question")
        case .activity(.idle): String(localized: "Your turn")
        }
    }

    static func pillText(for display: DisplayState) -> Color {
        display.isIdle ? .black.opacity(0.8) : .white
    }

    static func color(for display: DisplayState) -> Color {
        switch display {
        case .activity(.running): running
        case .activity(.needsPermission), .activity(.needsAnswer): blocked
        case .activity(.idle): idle
        case .starting: running.opacity(0.5)
        case .shell: .blue
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
        case .activity(.running): String(localized: "Running")
        case .activity(.needsPermission): String(localized: "Needs permission")
        case .activity(.needsAnswer): String(localized: "Waiting for an answer")
        case .activity(.idle): String(localized: "Your turn")
        case .activity(.ended), .notStarted: String(localized: "Stopped")
        case .starting: String(localized: "Starting")
        case .shell: String(localized: "Terminal")
        }
    }
}

/// Colored, labeled status chip — readable at a glance, not just a dot.
/// Running shows flowing dots, waiting-for-you pulses.
struct StatusPill: View {
    let display: DisplayState
    var unseen = false
    @State private var pulse = false

    var body: some View {
        let inactive = display == .notStarted || display == .activity(.ended)
        // Seen "your turn" stays yellow but softer than a fresh one.
        let fill: Color = inactive ? Color.secondary.opacity(0.18)
            : display.isIdle && !unseen ? StatusStyle.idle.opacity(0.45)
            : StatusStyle.color(for: display)
        HStack(spacing: 0) {
            Text(StatusStyle.label(for: display))
            if display.isRunning || display == .starting {
                TimelineView(.periodic(from: .now, by: 0.35)) { context in
                    let step = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 4
                    Text(String(repeating: "·", count: step) + String(repeating: " ", count: 3 - step))
                        .monospaced()
                }
            }
        }
        .font(.caption2.weight(.bold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(inactive ? AnyShapeStyle(.secondary) : AnyShapeStyle(StatusStyle.pillText(for: display)))
        .background(Capsule().fill(fill))
        .overlay {
            if display.isBlocked {
                Capsule()
                    .stroke(StatusStyle.blocked, lineWidth: 2)
                    .scaleEffect(pulse ? 1.25 : 1)
                    .opacity(pulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
            }
        }
        .fixedSize()
        .animation(.snappy, value: display)
        .onAppear { pulse = true }
    }
}

/// Briefly lights up a row when its state changes.
struct StateChangeFlash: ViewModifier {
    let display: DisplayState
    @State private var flash = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(StatusStyle.color(for: display).opacity(flash ? 0.22 : 0))
                    .padding(.horizontal, -4)
            )
            .onChange(of: display) { _, _ in
                withAnimation(.easeIn(duration: 0.15)) { flash = true }
                withAnimation(.easeOut(duration: 1.2).delay(0.25)) { flash = false }
            }
    }
}

extension View {
    func flashOnStateChange(_ display: DisplayState) -> some View { modifier(StateChangeFlash(display: display)) }
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
    static let names = [String(localized: "Blue"), String(localized: "Purple"), String(localized: "Pink"), String(localized: "Red"),
                         String(localized: "Orange"), String(localized: "Yellow"), String(localized: "Green"), String(localized: "Teal")]
    static var count: Int { colors.count }
    static func color(_ i: Int) -> Color { colors[((i % count) + count) % count] }
}

enum RelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<10: return String(localized: "now")
        case ..<60: return String(localized: "\(s)s")
        case ..<3600: return String(localized: "\(s / 60)m")
        case ..<86400: return String(localized: "\(s / 3600)h")
        default: return String(localized: "\(s / 86400)d")
        }
    }
}

/// How a terminal session starts: ⚡ auto-starts with the app (startup command), ▶︎ has a startup
/// command but starts only when opened. Plain terminals and Claude sessions show nothing.
struct ShellStartBadge: View {
    let session: DeckSession

    var body: some View {
        if session.kind == .shell, let command = session.startupCommand {
            let auto = session.autoStart
            Label(auto ? String(localized: "Auto") : String(localized: "Command"), systemImage: auto ? "bolt.fill" : "play.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .foregroundStyle(auto ? Color.orange : Color.secondary)
                .background(Capsule().strokeBorder(auto ? Color.orange.opacity(0.7) : Color.secondary.opacity(0.5), lineWidth: 1))
                .fixedSize()
                .help(auto ? String(localized: "Starts automatically when the app launches: \(command)") : String(localized: "Runs when opened: \(command)"))
        }
    }
}
