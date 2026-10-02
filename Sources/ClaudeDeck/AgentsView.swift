import ClaudeDeckCore
import SwiftUI

/// The inspector's Agents page: what the selected Claude session's subagents are doing — a tree,
/// a timeline and a live log, read from its transcript (AgentActivity.swift).
struct AgentsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.selectedSessionID.flatMap { model.deck.session($0) }
        if let session, session.kind == .claude {
            AgentsSessionView(session: session, transcriptPath: model.deck.transcriptPath(for: session.id))
                // Fresh state per session: never show the previous session's agents during a switch.
                .id(session.id)
        } else if session != nil {
            ContentUnavailableView("Not a Claude Session", systemImage: "terminal",
                                   description: Text("Shell terminals don’t run agents."))
        } else {
            ContentUnavailableView("No Session Selected", systemImage: "person.2",
                                   description: Text("Select a Claude session to see its agents."))
        }
    }
}

private struct AgentsSessionView: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession
    let transcriptPath: String?

    @State private var snapshot: AgentActivitySnapshot?
    @State private var polled = false
    @State private var expanded: Set<String> = []
    @AppStorage("agentsShowTree", store: .windowState) private var showTree = true
    @AppStorage("agentsShowTimeline", store: .windowState) private var showTimeline = true
    @AppStorage("agentsShowLog", store: .windowState) private var showLog = true

    var body: some View {
        let live = model.terminals.isRunning(session.id)
        VStack(spacing: 0) {
            header
            Divider()
            if let snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        DisclosureGroup(isExpanded: $showTree) {
                            tree(snapshot, live: live)
                        } label: {
                            sectionLabel("Agents", count: snapshot.nodes.count)
                        }
                        DisclosureGroup(isExpanded: $showTimeline) {
                            AgentTimeline(snapshot: snapshot, live: live)
                                .padding(.top, 4)
                        } label: {
                            sectionLabel("Timeline", count: nil)
                        }
                    }
                    .padding(10)
                }
                Divider()
                DisclosureGroup(isExpanded: $showLog) {
                    AgentLog(snapshot: snapshot)
                } label: {
                    sectionLabel("Activity", count: nil)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else if polled || transcriptPath == nil {
                ContentUnavailableView("Waiting for Transcript", systemImage: "text.page",
                                       description: Text("Agents appear once Claude writes its first message."))
                    .frame(maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: transcriptPath) {
            snapshot = nil
            polled = false
            guard let transcriptPath else { return }
            let tracker = AgentActivityTracker(transcriptURL: URL(fileURLWithPath: transcriptPath))
            while !Task.isCancelled {
                let next = await tracker.poll()
                if next != snapshot { snapshot = next }
                polled = true
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name).font(.callout.weight(.semibold)).lineLimit(1)
                if let model = snapshot?.model {
                    Text(model).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            StatusPill(display: model.status(of: session.id).display)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func sectionLabel(_ title: LocalizedStringKey, count: Int?) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let count, count > 0 {
                Text(verbatim: "\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func tree(_ snapshot: AgentActivitySnapshot, live: Bool) -> some View {
        if snapshot.nodes.isEmpty {
            Text("No subagents yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(snapshot.nodes) { node in
                    AgentRow(node: node, live: live, expanded: expanded.contains(node.id))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
                        }
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Tree row

/// How an agent's state is shown; a "running" agent of a session that is no longer running never
/// reported back, so it's shown as unfinished instead of spinning forever.
enum AgentStatusStyle {
    static func effective(_ status: AgentRunStatus, live: Bool) -> AgentRunStatus? {
        status == .running && !live ? nil : status
    }

    static func color(_ status: AgentRunStatus?) -> Color {
        switch status {
        case .running: StatusStyle.color(for: .activity(.running))
        case .done: .green
        case .failed: .red
        case .stopped, .unknown, nil: .secondary
        }
    }

    static func label(_ status: AgentRunStatus?) -> LocalizedStringKey {
        switch status {
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .unknown: "Unknown"
        case nil: "Not finished"
        }
    }

    static func symbol(_ status: AgentRunStatus?) -> String {
        switch status {
        case .running: "play.circle.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .stopped: "stop.circle"
        case .unknown: "questionmark.circle"
        case nil: "circle.dashed"
        }
    }
}

private struct AgentRow: View {
    let node: AgentNode
    let live: Bool
    let expanded: Bool

    var body: some View {
        let status = AgentStatusStyle.effective(node.status, live: live)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: AgentStatusStyle.symbol(status))
                    .font(.caption2)
                    .foregroundStyle(AgentStatusStyle.color(status))
                    .help(Text(AgentStatusStyle.label(status)))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if let type = node.agentType {
                            Text(type).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(node.label).font(.callout).lineLimit(1)
                    }
                    metrics(status)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    if let prompt = node.promptPreview {
                        Text(prompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 6) {
                        if let model = node.model { Text(model) }
                        if node.isBackground { Text("Background") }
                        if let id = node.agentID { Text(id).textSelection(.enabled) }
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                }
                .padding(.leading, 16)
                .padding(.bottom, 2)
            }
        }
        .padding(.leading, CGFloat(node.depth) * 14)
        .padding(.vertical, 3)
    }

    private func metrics(_ status: AgentRunStatus?) -> some View {
        HStack(spacing: 4) {
            Text(AgentStatusStyle.label(status))
            if status == .running {
                Text(verbatim: "·")
                Text(timerInterval: node.startedAt...Date.distantFuture, countsDown: false)
            } else if let duration = duration {
                Text(verbatim: "·")
                Text(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
            }
            if let tools = node.toolUses {
                Text(verbatim: "·")
                Text("\(tools) tools")
            }
            if let tokens = node.reportedTokens {
                Text(verbatim: "·")
                Text("\(tokens.formatted(.number.notation(.compactName))) tokens")
            }
        }
    }

    private var duration: TimeInterval? {
        if let ms = node.reportedDurationMs { return TimeInterval(ms) / 1000 }
        return node.endedAt.map { $0.timeIntervalSince(node.startedAt) }
    }
}

// MARK: - Timeline

private struct AgentTimeline: View {
    let snapshot: AgentActivitySnapshot
    let live: Bool
    static let window: TimeInterval = 30 * 60

    var body: some View {
        // Advances the window every few seconds; the data itself changes only with the transcript.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let now = context.date
            let start = now.addingTimeInterval(-Self.window)
            let nodes = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
            let lanes = snapshot.lanes.filter { lane in
                lane.id == AgentLane.mainID || (lane.segments.last?.end ?? .distantPast) >= start
                    || nodes[lane.id]?.status == .running
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(lanes) { lane in
                    let node = nodes[lane.id]
                    HStack(spacing: 6) {
                        Text(verbatim: node.map { $0.agentType ?? $0.label } ?? String(localized: "agents.mainSession", defaultValue: "Main"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, CGFloat(node.map { $0.depth + 1 } ?? 0) * 6)
                            .frame(width: 80, alignment: .leading)
                        bars(lane, node: node, start: start, now: now)
                            .frame(height: 9)
                    }
                    .help(node.map { Text(verbatim: $0.label) } ?? Text("Main session"))
                }
                HStack {
                    Text("−30 min")
                    Spacer()
                    Text("now")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 86)
            }
        }
    }

    private func bars(_ lane: AgentLane, node: AgentNode?, start: Date, now: Date) -> some View {
        let status = node.map { AgentStatusStyle.effective($0.status, live: live) } ?? .running
        let color = node == nil ? Color.accentColor : AgentStatusStyle.color(status)
        let running = node?.status == .running && live
        return Canvas { context, size in
            let span = Self.window
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2), with: .color(.secondary.opacity(0.08)))
            for (index, segment) in lane.segments.enumerated() {
                var end = segment.end
                if running, index == lane.segments.count - 1 { end = now }
                guard end >= start else { continue }
                let x0 = max(0, segment.start.timeIntervalSince(start) / span) * size.width
                let x1 = min(1, end.timeIntervalSince(start) / span) * size.width
                let rect = CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(0.75)))
            }
        }
    }
}

// MARK: - Log

private struct AgentLog: View {
    let snapshot: AgentActivitySnapshot
    @State private var atBottom = true
    private static let shown = 20

    var body: some View {
        let events = Array(snapshot.events.suffix(Self.shown))
        let nodes = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if events.isEmpty {
                        Text("No activity yet").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(events) { event in
                        row(event, node: event.agent.flatMap { nodes[$0] }).id(event.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 200)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 12
            } action: { _, bottom in
                atBottom = bottom
            }
            .onAppear { proxy.scrollTo(events.last?.id, anchor: .bottom) }
            .onChange(of: events.last?.id) { _, last in
                // Follow new events only while the user is at the bottom.
                guard atBottom, let last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    private func row(_ event: AgentEvent, node: AgentNode?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(event.at, format: .dateTime.hour().minute().second())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Group {
                if let node { Text(node.agentType ?? node.label) } else { Text(String(localized: "agents.mainSession", defaultValue: "Main")) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: 70, alignment: .leading)
            Group {
                switch event.kind {
                case let .tool(name, target):
                    Text(AgentActivityParser.displayToolName(name)).fontWeight(.medium)
                        + Text(target.map { " " + $0 } ?? "").foregroundStyle(.secondary)
                case .started:
                    Text("Started: \(node?.label ?? "")")
                case let .finished(status):
                    Text(AgentStatusStyle.label(status)).foregroundStyle(AgentStatusStyle.color(status))
                }
            }
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }
}
