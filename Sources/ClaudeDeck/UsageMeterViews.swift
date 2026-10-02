import ClaudeDeckCore
import SwiftUI

// The Claude plan usage meter: sidebar footer (details in a popover) and the menu bar window.
// Hidden while the usage is unknown or unavailable (not signed in, expired token).

private func usageColor(_ window: UsageWindow) -> Color {
    switch window.usedPercent {
    case ..<70: .green
    case ..<90: .orange
    default: .red
    }
}

/// A thin capsule filled to the window's used percentage.
struct UsageBar: View {
    let window: UsageWindow
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(usageColor(window))
                    .frame(width: max(height, geo.size.width * window.usedPercent / 100))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// "5h ━━━━──── 62% · 1h 20m"
private struct UsageMeterRow: View {
    let label: LocalizedStringKey
    let window: UsageWindow
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 30, alignment: .leading).foregroundStyle(.secondary)
            UsageBar(window: window)
            Text(UsageFormat.percent(window)).monospacedDigit().frame(width: 34, alignment: .trailing)
            if let reset = window.resetsAt {
                Text(UsageFormat.countdown(to: reset, now: now))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
        }
        .font(.caption2)
    }
}

/// Sidebar footer: the 5-hour and weekly windows; click for details.
struct UsageMeterFooter: View {
    @Environment(AppModel.self) private var model
    @State private var showDetails = false

    var body: some View {
        if let usage = model.usage.state.usage, !usage.isEmpty {
            Button { showDetails.toggle() } label: {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 3) {
                        if let window = usage.fiveHour { UsageMeterRow(label: "5h", window: window, now: context.date) }
                        if let window = usage.sevenDay { UsageMeterRow(label: "Week", window: window, now: context.date) }
                    }
                    .opacity(isStale ? 0.55 : 1)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .background(.bar)
            .help("Claude plan usage — click for details")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(UsageSummary.accessibility(usage)))
            .popover(isPresented: $showDetails, arrowEdge: .trailing) {
                UsageDetailsView().environment(model)
            }
        }
    }

    private var isStale: Bool {
        if case .failed = model.usage.state { true } else { false }
    }
}

/// Popover with both windows, reset times and the sessions waiting for the reset.
struct UsageDetailsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                Text("Claude Plan Usage").font(.headline)
                if let usage = model.usage.state.usage {
                    if let window = usage.fiveHour {
                        section("Current session (5 hours)", window, now: context.date)
                    }
                    if let window = usage.sevenDay {
                        section("This week", window, now: context.date)
                    }
                    if case .failed = model.usage.state {
                        Text("Couldn't update — showing values from \(usage.fetchedAt.formatted(date: .omitted, time: .shortened)).")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Updated \(usage.fetchedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Usage isn't available. Sign in to Claude Code with a Claude plan to see it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                waitingSessions(now: context.date)
            }
        }
        .padding(14)
        .frame(width: 280)
        .task { await model.usage.refresh() }
    }

    private func section(_ title: LocalizedStringKey, _ window: UsageWindow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(UsageFormat.percent(window)) used").monospacedDigit().font(.subheadline)
            }
            UsageBar(window: window, height: 6)
            if let reset = window.resetsAt {
                Text("Resets in \(UsageFormat.countdown(to: reset, now: now)) (\(reset.formatted(date: Calendar.current.isDateInToday(reset) ? .omitted : .abbreviated, time: .shortened)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func waitingSessions(now: Date) -> some View {
        let waiting = model.deck.sessions.filter { model.usageLimitHits[$0.id] != nil }
        if !waiting.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(model.deck.settings.continueAfterUsageLimit
                     ? "Stopped on the limit — continue when it resets:"
                     : "Stopped on the limit:")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(waiting) { session in
                    HStack {
                        Text(session.name).lineLimit(1)
                        Spacer()
                        if let reset = model.usageLimitReset(for: session.id) {
                            Text(UsageFormat.countdown(to: reset, now: now)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }
}

/// One line for the menu bar window: "5h 62% · 1h 20m   Week 18% · 4d 6h".
struct UsageMenuBarSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let usage = model.usage.state.usage, !usage.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 12) {
                    if let window = usage.fiveHour { item("5h", window, now: context.date) }
                    if let window = usage.sevenDay { item("Week", window, now: context.date) }
                    Spacer(minLength: 0)
                }
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .help("Claude plan usage")
            Divider()
        }
    }

    private func item(_ label: LocalizedStringKey, _ window: UsageWindow, now: Date) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            UsageBar(window: window, height: 4).frame(width: 36)
            Text(UsageFormat.percent(window)).monospacedDigit()
            if let reset = window.resetsAt {
                Text(verbatim: "· " + UsageFormat.countdown(to: reset, now: now)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

enum UsageSummary {
    static func accessibility(_ usage: ClaudeUsage) -> String {
        var parts: [String] = []
        if let w = usage.fiveHour { parts.append(String(localized: "5-hour usage \(UsageFormat.percent(w))")) }
        if let w = usage.sevenDay { parts.append(String(localized: "Weekly usage \(UsageFormat.percent(w))")) }
        return parts.joined(separator: ", ")
    }
}
