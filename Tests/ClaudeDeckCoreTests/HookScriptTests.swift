import Foundation
import Testing
@testable import ClaudeDeckCore

/// Runs the real hook script with /bin/sh and checks the files it writes.
@Suite struct HookScriptTests {
    let dir: URL
    let script: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "deck-hook-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        script = dir.appending(path: "deck-hook.sh")
        try Data(HookScript.source.utf8).write(to: script)
    }

    @discardableResult
    func run(_ json: String, terminal: String? = "T1") throws -> HookStatus? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        var env = ["PATH": "/usr/bin:/bin", "HOME": dir.path, "CLAUDEDECK_STATE_DIR": dir.appending(path: "st").path]
        if let terminal { env["CLAUDEDECK_TERMINAL_ID"] = terminal }
        p.environment = env
        let pipe = Pipe()
        p.standardInput = pipe
        try p.run()
        pipe.fileHandleForWriting.write(Data(json.utf8))
        try pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let file = dir.appending(path: "st/s1.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try HookStatus.decode(data)
    }

    @Test func ignoresNonDeckTerminals() throws {
        #expect(try run(#"{"session_id":"s1","hook_event_name":"Stop"}"#, terminal: nil) == nil)
    }

    @Test func fullLifecycle() throws {
        var s = try #require(try run(#"{"session_id":"s1","cwd":"/p","transcript_path":"/t.jsonl","hook_event_name":"SessionStart","source":"startup"}"#))
        #expect(s.state == .idle)
        #expect(s.terminalID == "T1")
        #expect(s.cwd == "/p")
        #expect(s.transcriptPath == "/t.jsonl")
        #expect((s.pid ?? 0) > 0)

        s = try #require(try run(#"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"fix it"}"#))
        #expect(s.state == .running)

        s = try #require(try run(#"{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#))
        #expect(s.state == .needsPermission)
        #expect(s.detail == "Bash: rm -rf build")

        // The generic notification keeps the specific detail.
        s = try #require(try run(#"{"session_id":"s1","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#))
        #expect(s.state == .needsPermission)
        #expect(s.detail == "Bash: rm -rf build")

        // idle_prompt must not hide a pending permission prompt.
        s = try #require(try run(#"{"session_id":"s1","hook_event_name":"Notification","notification_type":"idle_prompt","message":"waiting"}"#))
        #expect(s.state == .needsPermission)

        s = try #require(try run(#"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#))
        #expect(s.state == .running)

        s = try #require(try run(#"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which DB?"}]}}"#))
        #expect(s.state == .needsAnswer)
        #expect(s.detail == "Which DB?")

        s = try #require(try run(#"{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"Done."}"#))
        #expect(s.state == .idle)
        #expect(s.detail == "Done.")

        // Auto-compaction mid-session keeps the current state.
        s = try #require(try run(#"{"session_id":"s1","hook_event_name":"SessionStart","source":"compact"}"#))
        #expect(s.state == .idle)
        #expect(s.detail == "Done.")

        s = try #require(try run(#"{"session_id":"s1","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}"#))
        #expect(s.state == .ended)
    }

    @Test func unknownNotificationDoesNotWrite() throws {
        #expect(try run(#"{"session_id":"s1","hook_event_name":"Notification","notification_type":"auth_success"}"#) == nil)
    }

    @Test func rejectsPathTraversalSessionIDs() throws {
        try run(#"{"session_id":"../evil","hook_event_name":"Stop"}"#)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "evil.json").path))
    }

    @Test func clipsLongDetails() throws {
        let long = String(repeating: "x", count: 1000)
        let s = try #require(try run(#"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"\#(long)"}"#))
        #expect((s.detail?.count ?? 0) <= 201)
    }
}
