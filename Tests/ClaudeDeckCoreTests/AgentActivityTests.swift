import Foundation
import Testing
@testable import ClaudeDeckCore

/// Synthetic transcript lines in Claude Code's JSONL shape.
private enum Line {
    static func ts(_ s: Int) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(s)))
    }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func assistant(_ s: Int, model: String = "claude-test-1", tools: [[String: Any]] = [], sidechain: Bool = false) -> String {
        let content: [[String: Any]] = tools.isEmpty ? [["type": "text", "text": "ok"]] : tools
        return json(["type": "assistant", "timestamp": ts(s), "isSidechain": sidechain,
                     "message": ["model": model, "role": "assistant", "content": content]])
    }

    static func tool(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    static func agent(_ id: String, type: String? = "Explore", description: String = "Find things",
                      background: Bool = false) -> [String: Any] {
        var input: [String: Any] = ["description": description, "prompt": "Look around\nsecond line"]
        if let type { input["subagent_type"] = type }
        if background { input["run_in_background"] = true }
        return tool(id, "Agent", input)
    }

    static func result(_ s: Int, toolID: String, toolUseResult: [String: Any]? = nil, isError: Bool = false) -> String {
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": toolID, "content": "x"]
        if isError { block["is_error"] = true }
        var object: [String: Any] = ["type": "user", "timestamp": ts(s), "message": ["role": "user", "content": [block]]]
        if let toolUseResult { object["toolUseResult"] = toolUseResult }
        return json(object)
    }

    static func notification(_ s: Int, toolID: String, agentID: String, status: String) -> String {
        let text = "<task-notification><task-id>\(agentID)</task-id><tool-use-id>\(toolID)</tool-use-id>"
            + "<status>\(status)</status><summary>s</summary><usage><subagent_tokens>1234</subagent_tokens>"
            + "<tool_uses>7</tool_uses><duration_ms>9000</duration_ms></usage></task-notification>"
        return json(["type": "user", "timestamp": ts(s), "message": ["role": "user", "content": text]])
    }

    static func queueCopy(_ s: Int, toolID: String) -> String {
        json(["type": "queue-operation", "operation": "enqueue", "timestamp": ts(s),
              "content": "<task-notification><tool-use-id>\(toolID)</tool-use-id><status>failed</status></task-notification>"])
    }
}

private func parse(_ lines: [String], owner: String? = nil, into parser: inout AgentActivityParser) {
    for line in lines { parser.ingest(line: Substring(line), owner: owner) }
}

private func parse(_ lines: [String]) -> AgentActivitySnapshot {
    var parser = AgentActivityParser()
    parse(lines, into: &parser)
    return parser.snapshot()
}

@Suite struct AgentActivityTests {
    @Test func foregroundAgentCompletes() {
        let snap = parse([
            Line.assistant(0, model: "claude-main"),
            Line.assistant(10, tools: [Line.agent("t1")]),
            Line.result(70, toolID: "t1", toolUseResult: [
                "status": "completed", "agentId": "a1", "totalTokens": 5000, "totalToolUseCount": 12, "totalDurationMs": 60000,
            ]),
        ])
        #expect(snap.model == "claude-test-1")
        #expect(snap.nodes.count == 1)
        let node = snap.nodes[0]
        #expect(node.status == .done)
        #expect(node.agentType == "Explore")
        #expect(node.label == "Find things")
        #expect(node.promptPreview == "Look around\nsecond line")
        #expect(node.reportedTokens == 5000)
        #expect(node.toolUses == 12)
        #expect(node.agentID == "a1")
        #expect(node.endedAt == Date(timeIntervalSince1970: 1_800_000_070))
        #expect(snap.events.map(\.kind) == [.started, .finished(.done)])
    }

    @Test func backgroundAgentFinishesViaNotificationNotQueueCopy() {
        let snap = parse([
            Line.assistant(0, tools: [Line.agent("t1", background: true)]),
            Line.result(1, toolID: "t1", toolUseResult: ["status": "async_launched", "agentId": "a1", "resolvedModel": "claude-sub"]),
            Line.queueCopy(50, toolID: "t1"),
        ])
        #expect(snap.nodes[0].status == .running)
        #expect(snap.nodes[0].isBackground)
        #expect(snap.nodes[0].model == "claude-sub")

        var parser = AgentActivityParser()
        parse([
            Line.assistant(0, tools: [Line.agent("t1", background: true)]),
            Line.result(1, toolID: "t1", toolUseResult: ["status": "async_launched", "agentId": "a1"]),
            Line.notification(60, toolID: "t1", agentID: "a1", status: "completed"),
            Line.notification(61, toolID: "t1", agentID: "a1", status: "completed"),
        ], into: &parser)
        let node = parser.snapshot().nodes[0]
        #expect(node.status == .done)
        #expect(node.reportedTokens == 1234)
        #expect(node.reportedToolUses == 7)
        #expect(node.reportedDurationMs == 9000)
        // Repeated notification is idempotent: one finished event.
        #expect(parser.snapshot().events.filter { $0.kind == .finished(.done) }.count == 1)
    }

    @Test func failedAndStoppedAgents() {
        let snap = parse([
            Line.assistant(0, tools: [Line.agent("t1"), Line.agent("t2", background: true), Line.agent("t3", background: true)]),
            Line.result(1, toolID: "t1", isError: true),
            Line.result(1, toolID: "t2", toolUseResult: ["status": "async_launched", "agentId": "a2"]),
            Line.result(1, toolID: "t3", toolUseResult: ["status": "async_launched", "agentId": "a3"]),
            Line.notification(20, toolID: "t2", agentID: "a2", status: "killed"),
            Line.notification(30, toolID: "t3", agentID: "a3", status: "failed"),
        ])
        let byID = Dictionary(uniqueKeysWithValues: snap.nodes.map { ($0.id, $0.status) })
        #expect(byID == ["t1": .failed, "t2": .stopped, "t3": .failed])
    }

    @Test func notificationForUnknownToolIsIgnored() {
        // Background shell commands use the same envelope.
        let snap = parse([Line.notification(5, toolID: "bash1", agentID: "b1", status: "completed")])
        #expect(snap.nodes.isEmpty)
        #expect(snap.events.isEmpty)
    }

    @Test func nestedAgentsFromSubagentTranscript() {
        var parser = AgentActivityParser()
        parse([
            Line.assistant(0, tools: [Line.agent("t1", type: "general-purpose", background: true)]),
            Line.result(1, toolID: "t1", toolUseResult: ["status": "async_launched", "agentId": "a1"]),
            Line.assistant(100, tools: [Line.agent("t0", description: "Later sibling")]),
        ], into: &parser)
        parse([
            Line.assistant(5, model: "claude-sub", tools: [Line.tool("x1", "Read", ["file_path": "/tmp/project/Sources/App.swift"])]),
            Line.assistant(6, model: "claude-sub", tools: [Line.agent("t2", type: nil, description: "Inner")]),
            Line.result(40, toolID: "t2", toolUseResult: ["status": "completed", "agentId": "a2", "totalTokens": 10]),
        ], owner: "a1", into: &parser)
        let snap = parser.snapshot()
        #expect(snap.nodes.map(\.id) == ["t1", "t2", "t0"])
        #expect(snap.nodes.map(\.depth) == [0, 1, 0])
        #expect(snap.nodes[1].parentID == "t1")
        #expect(snap.nodes[1].label == "Inner")
        #expect(snap.nodes[0].countedToolUses == 2)
        #expect(snap.nodes[0].toolUses == 2)
        #expect(snap.nodes[0].model == "claude-sub")
        // Main session model isn't overwritten by subagent replies.
        #expect(snap.model == "claude-test-1")
        let read = snap.events.first { if case .tool = $0.kind { true } else { false } }
        #expect(read?.kind == .tool(name: "Read", target: "App.swift"))
        #expect(read?.agent == "t1")
    }

    @Test func metaPlaceholderAndLaterLaunch() {
        var parser = AgentActivityParser()
        let meta = Data(#"{"agentType":"Explore","description":"From meta","toolUseId":"t9"}"#.utf8)
        parser.ingestMeta(agentID: "a9", data: meta, firstSeen: Date(timeIntervalSince1970: 1_800_000_000))
        parse([Line.assistant(20)], owner: "a9", into: &parser)
        var snap = parser.snapshot()
        #expect(snap.nodes.count == 1)
        #expect(snap.nodes[0].status == .unknown)
        #expect(snap.nodes[0].label == "From meta")
        #expect(snap.nodes[0].startedAt == Date(timeIntervalSince1970: 1_800_000_020))

        parse([Line.assistant(10, tools: [Line.agent("t9", description: "Real")])], into: &parser)
        snap = parser.snapshot()
        #expect(snap.nodes.count == 1)
        #expect(snap.nodes[0].status == .running)
        #expect(snap.nodes[0].label == "Real")
    }

    @Test func lanesMergeNearbyActivity() {
        var parser = AgentActivityParser()
        parser.mergeGap = 30
        parse([Line.assistant(0), Line.assistant(20), Line.assistant(45), Line.assistant(200), Line.assistant(210)], into: &parser)
        let main = parser.snapshot().lanes.first { $0.id == AgentLane.mainID }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(main?.segments == [
            AgentSegment(start: base, end: base + 45),
            AgentSegment(start: base + 200, end: base + 210),
        ])
    }

    @Test func sidechainLinesInMainFileAreIgnored() {
        let snap = parse([Line.assistant(0, model: "claude-old", tools: [Line.agent("t1")], sidechain: true)])
        #expect(snap.nodes.isEmpty)
        #expect(snap.model == nil)
    }

    @Test func eventsAreCapped() {
        var parser = AgentActivityParser()
        parser.maxEvents = 10
        parser.snapshotEvents = 5
        let lines = (0..<50).map { Line.assistant($0, tools: [Line.tool("x\($0)", "Bash", ["command": "echo \($0)\nmore"])]) }
        parse(lines, into: &parser)
        let events = parser.snapshot().events
        #expect(events.count == 5)
        #expect(events.last?.kind == .tool(name: "Bash", target: "echo 49"))
    }

    @Test func toolNamesAndTargets() {
        #expect(AgentActivityParser.displayToolName("mcp__github__get_issue") == "github · get_issue")
        #expect(AgentActivityParser.displayToolName("Bash") == "Bash")
        #expect(AgentActivityParser.shortTarget(["pattern": "foo"]) == "foo")
        #expect(AgentActivityParser.shortTarget([:]) == nil)
        let long = String(repeating: "a", count: 100)
        #expect(AgentActivityParser.shortTarget(["command": long])?.count == 60)
    }

    // MARK: Tracker

    @Test func trackerFollowsTailAndSubagents() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "AgentActivityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = dir.appending(path: "session.jsonl")
        // A partial first line in the tail window must be skipped, not mis-parsed.
        let filler = Line.assistant(-100, model: "claude-filler") + "\n"
        let lines = [Line.assistant(0, tools: [Line.agent("t1", background: true)]),
                     Line.result(1, toolID: "t1", toolUseResult: ["status": "async_launched", "agentId": "a1"])]
        try (filler + lines.joined(separator: "\n") + "\n").write(to: main, atomically: true, encoding: .utf8)

        let tail = lines.joined(separator: "\n").utf8.count + 20
        let tracker = AgentActivityTracker(transcriptURL: main, mainTailBytes: tail, subagentRecency: .infinity)
        var snap = try #require(await tracker.poll())
        #expect(snap.nodes.map(\.status) == [.running])
        #expect(snap.model == "claude-test-1")

        let subDir = dir.appending(path: "session/subagents")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try Data(#"{"agentType":"Explore","toolUseId":"t1"}"#.utf8).write(to: subDir.appending(path: "agent-a1.meta.json"))
        try (Line.assistant(3, tools: [Line.tool("x", "Grep", ["pattern": "TODO"])]) + "\n")
            .write(to: subDir.appending(path: "agent-a1.jsonl"), atomically: true, encoding: .utf8)
        snap = try #require(await tracker.poll())
        #expect(snap.nodes[0].countedToolUses == 1)

        let handle = try FileHandle(forWritingTo: main)
        try handle.seekToEnd()
        // Appended in two pieces: the half line waits for its newline.
        let finish = Line.notification(90, toolID: "t1", agentID: "a1", status: "completed")
        let split = finish.index(finish.startIndex, offsetBy: 30)
        try handle.write(contentsOf: Data(finish[..<split].utf8))
        snap = try #require(await tracker.poll())
        #expect(snap.nodes[0].status == .running)
        try handle.write(contentsOf: Data((finish[split...] + "\n").utf8))
        try handle.close()
        snap = try #require(await tracker.poll())
        #expect(snap.nodes[0].status == .done)
    }

    @Test func trackerWithoutTranscriptReturnsNil() async {
        let tracker = AgentActivityTracker(transcriptURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl"))
        #expect(await tracker.poll() == nil)
    }
}
