import ClaudeDeckCore
import SwiftUI
import WidgetKit

// Desktop / Notification Center widget: session counts and the sessions waiting for the user.
// Data comes from the snapshot the app writes into the shared App Group container.

struct DeckEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
}

struct DeckProvider: TimelineProvider {
    func placeholder(in context: Context) -> DeckEntry {
        DeckEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (DeckEntry) -> Void) {
        completion(DeckEntry(date: Date(), snapshot: context.isPreview ? .preview : Self.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DeckEntry>) -> Void) {
        // The app reloads timelines on every change; the periodic refresh is only a safety net.
        let entry = DeckEntry(date: Date(), snapshot: Self.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    static func load() -> WidgetSnapshot {
        WidgetSnapshot.sharedFileURL().flatMap(WidgetSnapshot.read(from:)) ?? .empty
    }
}

@main
struct ClaudeDeckWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeDeckWidget()
    }
}

struct ClaudeDeckWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeDeckStatus", provider: DeckProvider()) { entry in
            DeckWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("ClaudeDeck")
        .description("Status of your Claude sessions: waiting, running and ready for you.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private enum Palette {
    static let blocked = Color.red
    static let running = Color.green
    static let unseen = Color.yellow

    static func color(_ state: WidgetSnapshot.State) -> Color {
        switch state {
        case .needsPermission, .needsAnswer: blocked
        case .idle: unseen
        case .running: running
        }
    }
}

struct DeckWidgetView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    private var appURL: URL { URL(string: "\(WidgetSnapshot.urlScheme)://open")! }

    var body: some View {
        switch family {
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                countsColumn.frame(width: 104)
                Divider()
                sessionList.frame(maxWidth: .infinity, alignment: .leading)
            }
            .widgetURL(snapshot.items.first?.url ?? appURL)
        default:
            countsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetURL(snapshot.items.first?.url ?? appURL)
        }
    }

    private var countsColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ClaudeDeck")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if snapshot.appRunning {
                CountRow(color: Palette.blocked, count: snapshot.blocked, label: "Waiting")
                CountRow(color: Palette.running, count: snapshot.running, label: "Running")
                CountRow(color: Palette.unseen, count: snapshot.unseen, label: "Your turn")
            } else {
                Text("App not running")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        if snapshot.items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)
                Text(snapshot.appRunning ? "No sessions waiting for you" : "Sessions stopped")
                    .font(.callout.weight(.medium))
                Text(snapshot.appRunning && snapshot.running > 0 ? "\(snapshot.running) running" : " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(snapshot.items.prefix(4)) { item in
                    Link(destination: item.url) { SessionRow(item: item) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct CountRow: View {
    let color: Color
    let count: Int
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count)")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(count > 0 ? .primary : .secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct SessionRow: View {
    let item: WidgetSnapshot.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(Palette.color(item.state))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(item.state.label)
                        .font(.caption2)
                        .foregroundStyle(Palette.color(item.state) == Palette.unseen ? .secondary : Palette.color(item.state))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Project name (when the session name doesn't already say it) and the short detail.
    private var subtitle: String? {
        let parts = [item.name.hasPrefix(item.project) ? nil : item.project, item.detail]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension WidgetSnapshot {
    static let preview = WidgetSnapshot(
        blocked: 1, running: 2, unseen: 1,
        items: [
            .init(id: UUID(), name: "api", project: "api", state: .needsPermission, detail: "Bash: npm test"),
            .init(id: UUID(), name: "web", project: "web", state: .idle, detail: "Done"),
        ]
    )
}
