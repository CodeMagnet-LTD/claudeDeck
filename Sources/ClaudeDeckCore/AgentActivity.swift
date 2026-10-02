import Foundation

// The Agents inspector: what a Claude session's subagents are doing, read from its transcript.
//
// Formats (Claude Code transcripts, `~/.claude/projects/<cwd>/<session>.jsonl`):
// - A subagent starts with an assistant `tool_use` named `Agent` (older versions: `Task`) whose input
//   has `description`, `prompt` and usually `subagent_type`.
// - Its `tool_result` comes back in a `user` entry whose top-level `toolUseResult` holds `agentId` and a
//   `status`: "completed" (foreground; with `totalTokens`, `totalToolUseCount`, `totalDurationMs`) or
//   "async_launched" (background). `is_error` on the result block means the launch failed.
// - Background agents finish with a `user` entry whose string content is a `<task-notification>` naming
//   the `<tool-use-id>`, a `<status>` and `<usage>` (`subagent_tokens`, `tool_uses`, `duration_ms`).
//   (`queue-operation` entries carry a copy of it and are ignored.)
// - Each subagent writes its own transcript to `<session>/subagents/agent-<agentId>.jsonl`, next to an
//   `agent-<agentId>.meta.json` with `toolUseId`, `agentType` and `description`. Subagents may launch
//   agents of their own, recorded in their transcript the same way.

public enum AgentRunStatus: String, Sendable, Equatable {
    case running, done, failed, stopped
    /// Known only from its own transcript; the launch and its outcome are outside what was read.
    case unknown
}

public struct AgentNode: Identifiable, Sendable, Equatable {
    /// The `tool_use` id that launched the agent.
    public var id: String
    /// Parent agent's node id; nil for agents launched by the main session.
    public var parentID: String?
    public var depth: Int
    public var agentType: String?
    public var label: String
    /// Start of the prompt it was given (truncated).
    public var promptPreview: String?
    public var model: String?
    public var agentID: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var status: AgentRunStatus
    public var isBackground: Bool
    /// Tool calls counted in the agent's own transcript.
    public var countedToolUses: Int
    /// Totals Claude reported when the agent finished.
    public var reportedToolUses: Int?
    public var reportedTokens: Int?
    public var reportedDurationMs: Int?
    public var lastActivityAt: Date?

    public init(id: String, parentID: String? = nil, depth: Int = 0, agentType: String? = nil, label: String,
                promptPreview: String? = nil, model: String? = nil, agentID: String? = nil, startedAt: Date,
                endedAt: Date? = nil, status: AgentRunStatus = .running, isBackground: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.depth = depth
        self.agentType = agentType
        self.label = label
        self.promptPreview = promptPreview
        self.model = model
        self.agentID = agentID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.isBackground = isBackground
        self.countedToolUses = 0
    }

    /// Reported total if the agent finished, otherwise what its transcript shows so far (nil if unseen).
    public var toolUses: Int? { reportedToolUses ?? (countedToolUses > 0 ? countedToolUses : nil) }
}

public struct AgentEvent: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case tool(name: String, target: String?)
        case started
        case finished(AgentRunStatus)
    }

    public var id: Int
    public var at: Date
    /// Node id of the agent the event belongs to (for `.started`/`.finished`: the agent itself);
    /// nil for the main session.
    public var agent: String?
    public var kind: Kind
}

public struct AgentSegment: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// One timeline row: the main session (`id == AgentLane.mainID`) or an agent node.
public struct AgentLane: Identifiable, Sendable, Equatable {
    public static let mainID = "main"
    public var id: String
    public var segments: [AgentSegment]
}

public struct AgentActivitySnapshot: Sendable, Equatable {
    /// Model of the main session's latest reply.
    public var model: String?
    /// Agents in tree order (depth-first, siblings by start time).
    public var nodes: [AgentNode]
    public var lanes: [AgentLane]
    /// Newest last.
    public var events: [AgentEvent]

    public init(model: String? = nil, nodes: [AgentNode] = [], lanes: [AgentLane] = [], events: [AgentEvent] = []) {
        self.model = model
        self.nodes = nodes
        self.lanes = lanes
        self.events = events
    }
}

// MARK: - Parser

/// Incremental transcript parser; feed it complete JSONL lines in file order (per file).
public struct AgentActivityParser: Sendable {
    public static let agentToolNames: Set<String> = ["Agent", "Task"]
    /// Points closer than this join one timeline bar.
    public var mergeGap: TimeInterval = 60
    public var maxNodes = 200
    public var maxEvents = 200
    public var maxSegmentsPerLane = 300
    public var snapshotEvents = 50

    private struct Node: Sendable {
        var node: AgentNode
        /// agentId of the agent whose transcript launched it (nil = main).
        var parentAgentID: String?
    }

    private var nodes: [String: Node] = [:]
    private var nodeForAgent: [String: String] = [:]
    private var activity: [String: [AgentSegment]] = [:]
    private var toolCounts: [String: Int] = [:]
    private var models: [String: String] = [:]
    private var events: [AgentEvent] = []
    private var nextEventID = 0
    private var mainModel: String?

    public init() {}

    private static let mainKey = ""

    // MARK: Lines

    /// `owner`: the agentId whose transcript the line comes from; nil for the main transcript.
    public mutating func ingest(line: Substring, owner: String? = nil) {
        guard line.contains("\"type\":\"assistant\"") || line.contains("\"type\":\"user\"")
              || line.contains("\"type\": \"assistant\"") || line.contains("\"type\": \"user\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String, type == "assistant" || type == "user",
              let at = (object["timestamp"] as? String).flatMap(Self.parseDate)
        else { return }
        // Very old versions wrote subagent turns into the main file; they can't be attributed.
        if owner == nil, object["isSidechain"] as? Bool == true { return }
        let key = owner ?? Self.mainKey
        addActivity(key, at)
        guard let message = object["message"] as? [String: Any] else { return }

        if type == "assistant" {
            if let model = message["model"] as? String, !model.hasPrefix("<") {
                if owner == nil { mainModel = model } else { models[key] = model }
            }
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String, let toolID = block["id"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                toolCounts[key, default: 0] += 1
                if Self.agentToolNames.contains(name) {
                    startAgent(toolID: toolID, input: input, owner: owner, at: at)
                } else {
                    appendEvent(at: at, agent: owner, kind: .tool(name: name, target: Self.shortTarget(input)))
                }
            }
            return
        }

        // user
        if let text = message["content"] as? String {
            if text.contains("<task-notification>") { applyNotification(text, at: at) }
            return
        }
        for block in message["content"] as? [[String: Any]] ?? [] {
            if block["type"] as? String == "text", let text = block["text"] as? String,
               text.contains("<task-notification>") {
                applyNotification(text, at: at)
                continue
            }
            guard block["type"] as? String == "tool_result",
                  let toolID = block["tool_use_id"] as? String, nodes[toolID] != nil else { continue }
            let result = object["toolUseResult"] as? [String: Any]
            if let agentID = result?["agentId"] as? String { link(agentID: agentID, toNode: toolID) }
            if block["is_error"] as? Bool == true {
                finish(toolID, .failed, at: at)
                continue
            }
            switch result?["status"] as? String {
            case "async_launched":
                nodes[toolID]?.node.isBackground = true
                if let model = result?["resolvedModel"] as? String, !model.isEmpty { nodes[toolID]?.node.model = model }
            case "completed":
                finish(toolID, .done, at: at, tokens: result?["totalTokens"] as? Int,
                       tools: result?["totalToolUseCount"] as? Int, durationMs: result?["totalDurationMs"] as? Int)
            default:
                break
            }
        }
    }

    /// `agent-<id>.meta.json` of a subagent transcript.
    public mutating func ingestMeta(agentID: String, data: Data, firstSeen: Date) {
        guard let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolID = meta["toolUseId"] as? String else { return }
        if nodes[toolID] == nil {
            guard nodes.count < maxNodes * 2 else { return }
            let type = meta["agentType"] as? String
            let label = (meta["description"] as? String) ?? (meta["name"] as? String) ?? type ?? "Agent"
            nodes[toolID] = Node(node: AgentNode(id: toolID, agentType: type, label: Self.oneLine(label, max: 120),
                                                 startedAt: firstSeen, status: .unknown), parentAgentID: nil)
        } else if nodes[toolID]?.node.agentType == nil {
            nodes[toolID]?.node.agentType = meta["agentType"] as? String
        }
        link(agentID: agentID, toNode: toolID)
    }

    // MARK: Snapshot

    public func snapshot() -> AgentActivitySnapshot {
        var children: [String: [AgentNode]] = [:]
        for entry in nodes.values {
            var node = entry.node
            let parent = entry.parentAgentID.flatMap { nodeForAgent[$0] }.flatMap { $0 == node.id ? nil : $0 }
            node.parentID = parent.flatMap { nodes[$0] != nil ? $0 : nil }
            if let agentID = node.agentID {
                node.countedToolUses = toolCounts[agentID] ?? 0
                node.lastActivityAt = activity[agentID]?.last?.end
                if node.model == nil { node.model = models[agentID] }
                // Placeholder from meta.json: its own transcript tells when it really started.
                if node.status == .unknown, let first = activity[agentID]?.first?.start { node.startedAt = first }
            }
            children[node.parentID ?? Self.mainKey, default: []].append(node)
        }
        var ordered: [AgentNode] = []
        var visited: Set<String> = []
        func walk(_ parent: String, depth: Int) {
            let kids = (children[parent] ?? []).sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
            for var kid in kids where visited.insert(kid.id).inserted {
                kid.depth = depth
                ordered.append(kid)
                walk(kid.id, depth: depth + 1)
            }
        }
        walk(Self.mainKey, depth: 0)
        if ordered.count > maxNodes {
            // Keep the newest trees whole: drop from the front (oldest roots first).
            ordered = Array(ordered.suffix(maxNodes))
            if let first = ordered.first, first.depth > 0 {
                ordered = Array(ordered.drop { $0.depth > 0 })
            }
        }

        var lanes = [AgentLane(id: AgentLane.mainID, segments: activity[Self.mainKey] ?? [])]
        for node in ordered {
            var segments = node.agentID.flatMap { activity[$0] } ?? []
            if segments.isEmpty {
                let end = node.endedAt ?? node.lastActivityAt ?? node.startedAt
                segments = [AgentSegment(start: node.startedAt, end: max(end, node.startedAt))]
            }
            lanes.append(AgentLane(id: node.id, segments: segments))
        }
        let recent = events.sorted { ($0.at, $0.id) < ($1.at, $1.id) }.suffix(snapshotEvents)
        return AgentActivitySnapshot(model: mainModel, nodes: ordered, lanes: lanes, events: Array(recent))
    }

    // MARK: Helpers

    private mutating func startAgent(toolID: String, input: [String: Any], owner: String?, at: Date) {
        let type = input["subagent_type"] as? String
        let described = (input["description"] as? String) ?? (input["name"] as? String) ?? type ?? "Agent"
        let prompt = (input["prompt"] as? String).map { Self.truncate($0, max: 400) }
        if var existing = nodes[toolID] {
            // Created from meta.json before its launch was read.
            existing.node.startedAt = at
            existing.node.agentType = existing.node.agentType ?? type
            existing.node.label = Self.oneLine(described, max: 120)
            existing.node.promptPreview = prompt
            existing.node.isBackground = input["run_in_background"] as? Bool == true
            if existing.node.status == .unknown { existing.node.status = .running }
            existing.parentAgentID = owner
            nodes[toolID] = existing
            appendEvent(at: at, agent: toolID, kind: .started)
            return
        }
        guard nodes.count < maxNodes * 2 else { return }
        var node = AgentNode(id: toolID, agentType: type, label: Self.oneLine(described, max: 120),
                             promptPreview: prompt, model: input["model"] as? String, startedAt: at,
                             isBackground: input["run_in_background"] as? Bool == true)
        node.status = .running
        nodes[toolID] = Node(node: node, parentAgentID: owner)
        appendEvent(at: at, agent: toolID, kind: .started)
    }

    private mutating func link(agentID: String, toNode toolID: String) {
        guard nodes[toolID] != nil else { return }
        nodes[toolID]?.node.agentID = agentID
        nodeForAgent[agentID] = toolID
    }

    private mutating func finish(_ toolID: String, _ status: AgentRunStatus, at: Date,
                                 tokens: Int? = nil, tools: Int? = nil, durationMs: Int? = nil) {
        guard var entry = nodes[toolID] else { return }
        let wasOpen = entry.node.status == .running || entry.node.status == .unknown
        if wasOpen || entry.node.status == status {
            entry.node.status = status
            if entry.node.endedAt == nil { entry.node.endedAt = at }
        }
        if let tokens { entry.node.reportedTokens = tokens }
        if let tools { entry.node.reportedToolUses = tools }
        if let durationMs { entry.node.reportedDurationMs = durationMs }
        nodes[toolID] = entry
        if wasOpen { appendEvent(at: at, agent: toolID, kind: .finished(status)) }
    }

    private mutating func applyNotification(_ text: String, at: Date) {
        guard let toolID = Self.tag("tool-use-id", in: text), nodes[toolID] != nil else { return }
        let status: AgentRunStatus
        switch Self.tag("status", in: text) {
        case "completed": status = .done
        case "failed": status = .failed
        case "stopped", "killed": status = .stopped
        default: return
        }
        if let agentID = Self.tag("task-id", in: text) { link(agentID: agentID, toNode: toolID) }
        let usage = Self.tag("usage", in: text) ?? ""
        finish(toolID, status, at: at,
               tokens: Self.tag("subagent_tokens", in: usage).flatMap { Int($0) },
               tools: Self.tag("tool_uses", in: usage).flatMap { Int($0) },
               durationMs: Self.tag("duration_ms", in: usage).flatMap { Int($0) })
    }

    private mutating func addActivity(_ key: String, _ at: Date) {
        var segments = activity[key] ?? []
        if let last = segments.last, at >= last.start, at.timeIntervalSince(last.end) <= mergeGap {
            segments[segments.count - 1].end = max(last.end, at)
        } else if !segments.contains(where: { $0.start <= at && at <= $0.end }) {
            segments.append(AgentSegment(start: at, end: at))
            if segments.count > 1, segments[segments.count - 2].start > at {
                segments.sort { $0.start < $1.start }
            }
            if segments.count > maxSegmentsPerLane { segments.removeFirst(segments.count - maxSegmentsPerLane) }
        }
        activity[key] = segments
    }

    private mutating func appendEvent(at: Date, agent: String?, kind: AgentEvent.Kind) {
        let owner = agent.flatMap { nodes[$0] != nil ? $0 : nodeForAgent[$0] }
        events.append(AgentEvent(id: nextEventID, at: at, agent: owner, kind: kind))
        nextEventID += 1
        if events.count > maxEvents * 2 {
            events.sort { ($0.at, $0.id) < ($1.at, $1.id) }
            events.removeFirst(events.count - maxEvents)
        }
    }

    // MARK: Static helpers

    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()

    static func parseDate(_ string: String) -> Date? {
        (try? isoFractional.parse(string)) ?? (try? isoPlain.parse(string))
    }

    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A short hint of what a tool call works on: a file name, the first line of a command, a pattern…
    public static func shortTarget(_ input: [String: Any]) -> String? {
        for key in ["file_path", "notebook_path", "path"] {
            if let path = input[key] as? String, !path.isEmpty {
                return truncate((path as NSString).lastPathComponent, max: 60)
            }
        }
        for key in ["command", "pattern", "url", "query", "skill", "description"] {
            if let value = input[key] as? String, !value.isEmpty { return oneLine(value, max: 60) }
        }
        return nil
    }

    /// `mcp__server__tool` → `server · tool`.
    public static func displayToolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        return name.dropFirst(5).components(separatedBy: "__").joined(separator: " · ")
    }

    static func oneLine(_ text: String, max: Int) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return truncate(first.trimmingCharacters(in: .whitespaces), max: max)
    }

    static func truncate(_ text: String, max: Int) -> String {
        text.count > max ? String(text.prefix(max - 1)) + "…" : text
    }
}

// MARK: - Tracker

/// Follows a session transcript and its subagent transcripts with bounded reads; call `poll()`
/// periodically. Only new bytes are read after the first poll.
public actor AgentActivityTracker {
    public let transcriptURL: URL
    private var parser = AgentActivityParser()
    private var cursors: [String: Cursor] = [:]
    private var metasRead: Set<String> = []
    private let mainTailBytes: Int
    private let subagentTailBytes: Int
    private let maxReadPerPoll: Int
    private let maxSubagentFiles: Int
    /// Subagent transcripts untouched for longer than this (and not linked to a known agent) are skipped.
    private let subagentRecency: TimeInterval
    private var lastSnapshot: AgentActivitySnapshot?

    private struct Cursor {
        var offset: UInt64
        var remainder = Data()
        var skipPartialLine: Bool
    }

    public init(transcriptURL: URL, mainTailBytes: Int = 4 << 20, subagentTailBytes: Int = 512 << 10,
                maxReadPerPoll: Int = 8 << 20, maxSubagentFiles: Int = 64, subagentRecency: TimeInterval = 2 * 3600) {
        self.transcriptURL = transcriptURL
        self.mainTailBytes = mainTailBytes
        self.subagentTailBytes = subagentTailBytes
        self.maxReadPerPoll = maxReadPerPoll
        self.maxSubagentFiles = maxSubagentFiles
        self.subagentRecency = subagentRecency
    }

    /// `<session>/subagents` next to `<session>.jsonl`.
    public nonisolated var subagentsDirectory: URL {
        transcriptURL.deletingPathExtension().appending(path: "subagents")
    }

    /// Reads what's new. Nil while the transcript doesn't exist yet.
    public func poll(now: Date = Date()) -> AgentActivitySnapshot? {
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else { return nil }
        var changed = lastSnapshot == nil
        changed = read(transcriptURL, owner: nil, tail: mainTailBytes) || changed
        changed = readSubagents(now: now) || changed
        if changed { lastSnapshot = parser.snapshot() }
        return lastSnapshot
    }

    private func readSubagents(now: Date) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: subagentsDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey]
        ) else { return false }
        var metas: [String: URL] = [:]
        var transcripts: [(url: URL, agentID: String, modified: Date, created: Date)] = []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("agent-") else { continue }
            if name.hasSuffix(".meta.json") {
                metas[String(name.dropFirst(6).dropLast(10))] = url
            } else if name.hasSuffix(".jsonl") {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                let modified = values?.contentModificationDate ?? .distantPast
                transcripts.append((url, String(name.dropFirst(6).dropLast(6)), modified, values?.creationDate ?? modified))
            }
        }
        let recent = transcripts
            .filter { cursors[$0.url.path] != nil || now.timeIntervalSince($0.modified) < subagentRecency }
            .sorted { $0.modified > $1.modified }
            .prefix(maxSubagentFiles)
        var changed = false
        for file in recent where !metasRead.contains(file.agentID) {
            metasRead.insert(file.agentID)
            guard let url = metas[file.agentID], let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = (try? handle.read(upToCount: 64 << 10)) ?? Data()
            try? handle.close()
            parser.ingestMeta(agentID: file.agentID, data: data, firstSeen: file.created)
            changed = true
        }
        for file in recent {
            changed = read(file.url, owner: file.agentID, tail: subagentTailBytes) || changed
        }
        return changed
    }

    /// Feeds new complete lines of a file to the parser; returns whether anything was read.
    private func read(_ url: URL, owner: String?, tail: Int) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var cursor = cursors[url.path] ?? {
            let start = size > UInt64(tail) ? size - UInt64(tail) : 0
            return Cursor(offset: start, skipPartialLine: start > 0)
        }()
        if size < cursor.offset {
            // Rewritten from scratch: start over from its tail.
            let start = size > UInt64(tail) ? size - UInt64(tail) : 0
            cursor = Cursor(offset: start, skipPartialLine: start > 0)
        }
        guard size > cursor.offset else {
            cursors[url.path] = cursor
            return false
        }
        try? handle.seek(toOffset: cursor.offset)
        let count = Int(min(size - cursor.offset, UInt64(maxReadPerPoll)))
        guard let data = try? handle.read(upToCount: count), !data.isEmpty else { return false }
        cursor.offset += UInt64(data.count)
        var chunk = cursor.remainder + data
        if cursor.skipPartialLine {
            guard let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) else {
                cursors[url.path] = cursor
                return false
            }
            chunk = chunk[(newline + 1)...]
            cursor.skipPartialLine = false
        }
        if let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) {
            cursor.remainder = Data(chunk[(lastNewline + 1)...])
            let text = String(decoding: chunk[..<lastNewline], as: UTF8.self)
            for line in text.split(separator: "\n") { parser.ingest(line: line, owner: owner) }
        } else {
            cursor.remainder = Data(chunk)
        }
        // A runaway line without newlines: don't let it grow without bound.
        if cursor.remainder.count > 16 << 20 { cursor.remainder = Data(); cursor.skipPartialLine = true }
        cursors[url.path] = cursor
        return true
    }
}
