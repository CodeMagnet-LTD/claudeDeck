import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct KodBridgeTests {
    @Test func settingsStayOffUntilTurnedOn() throws {
        let settings = try JSONDecoder().decode(DeckSettings.self, from: Data("{}".utf8))
        #expect(!settings.kodBridgeEnabled)
        #expect(settings.kodWebhookURL.isEmpty)
        #expect(settings.kodBridgePort == KodBridge.defaultPort)
    }

    @Test func portRejectsTheRemoteListener() {
        #expect(KodBridge.portProblem(Int(RemotePairing.defaultPort)) == .remoteMode)
        #expect(KodBridge.sanitizedPort(Int(RemotePairing.defaultPort)) == nil)
        #expect(KodBridge.sanitizedPort(80) == nil)
        #expect(KodBridge.sanitizedPort(KodBridge.defaultPort) == UInt16(KodBridge.defaultPort))
    }

    @Test func webhookURLNeedsHTTP() {
        #expect(KodBridge.webhookURL("https://example.com/hooks/kod")?.host == "example.com")
        #expect(KodBridge.webhookURL(" http://127.0.0.1:9/hook ")?.port == 9)
        #expect(KodBridge.webhookURL("ftp://example.com/hook") == nil)
        #expect(KodBridge.webhookURL("not a url") == nil)
        #expect(KodBridge.webhookURL("") == nil)
    }

    @Test func eventNamesAndFlags() {
        #expect(KodBridge.eventName(for: .idle) == "session.idle")
        #expect(KodBridge.eventName(for: .needsPermission) == "session.needs_permission")
        #expect(KodBridge.eventName(for: .needsAnswer) == "session.needs_answer")
        #expect(KodBridge.eventName(for: .running) == nil)
        #expect(KodBridge.finished(.idle) && !KodBridge.waitingForInput(.idle))
        #expect(!KodBridge.finished(.needsPermission) && KodBridge.waitingForInput(.needsPermission))
        #expect(KodBridge.waitingForInput(.needsAnswer))
    }

    @Test func payloadUsesTheWireNamesAndTrimsTheReply() throws {
        let reply = String(repeating: "a", count: KodBridge.maxReplyCharacters + 5)
        let event = KodBridgeEvent(
            event: "session.idle",
            projectName: "claudeDeck",
            projectPath: "/Users/mustafa/claudeDeck",
            sessionID: "11111111-1111-1111-1111-111111111111",
            timestamp: Date(timeIntervalSince1970: 1_762_387_800),
            lastUserPrompt: "  look at the tests  ",
            lastAssistantReply: reply,
            finished: true,
            waitingForInput: false,
            transcriptPath: "/tmp/s.jsonl",
            detail: nil
        )
        let clipped = KodBridge.excerpt(from: [
            ChatEntry(id: "u", kind: .user, text: "  look at the tests  "),
            ChatEntry(id: "a", kind: .assistant, text: reply),
        ])
        #expect(clipped.prompt == "look at the tests")
        #expect(clipped.reply?.hasSuffix("…") == true)
        #expect(clipped.reply?.count == KodBridge.maxReplyCharacters + 1)

        let object = try json(event)
        #expect(object["event"] as? String == "session.idle")
        #expect(object["project_name"] as? String == "claudeDeck")
        #expect(object["project_path"] as? String == "/Users/mustafa/claudeDeck")
        #expect(object["session_id"] as? String == "11111111-1111-1111-1111-111111111111")
        #expect(object["finished"] as? Bool == true)
        #expect(object["waiting_for_input"] as? Bool == false)
        #expect(object["transcript_path"] as? String == "/tmp/s.jsonl")
        #expect(object["detail"] is NSNull)
        #expect((object["timestamp"] as? String)?.contains("T") == true)
        #expect(object["last_user_prompt"] as? String == "  look at the tests  ")
    }

    @Test func webhookRequestSendsTheAuthorizationValueVerbatim() throws {
        let event = KodBridgeEvent(
            event: KodBridge.testEvent, projectName: "", projectPath: "", sessionID: "x",
            timestamp: Date(timeIntervalSince1970: 0), lastUserPrompt: nil, lastAssistantReply: "Test event from ClaudeDeck.",
            finished: true, waitingForInput: false, transcriptPath: nil, detail: nil
        )
        let url = try #require(URL(string: "https://example.com/hook"))
        let request = try KodWebhook.makeRequest(event: event, url: url, authorization: "Bearer secret")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == KodWebhook.timeout)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let blank = try KodWebhook.makeRequest(event: event, url: url, authorization: "  ")
        #expect(blank.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func retriesTransportErrorsAndServerErrorsOnly() {
        #expect(KodWebhook.shouldRetry(statusCode: nil, transportFailed: true))
        #expect(KodWebhook.shouldRetry(statusCode: 503, transportFailed: false))
        #expect(KodWebhook.shouldRetry(statusCode: 429, transportFailed: false))
        #expect(!KodWebhook.shouldRetry(statusCode: 200, transportFailed: false))
        #expect(!KodWebhook.shouldRetry(statusCode: 404, transportFailed: false))
        #expect(KodWebhook.maxAttempts == 3)
    }

    @Test func bearerTokenIsRequired() {
        #expect(KodBearer.credential(from: "Bearer secret") == "secret")
        #expect(KodBearer.credential(from: "bearer\tsecret") == "secret")
        #expect(KodBearer.credential(from: "Basic secret") == nil)
        #expect(KodBearer.credential(from: "Bearer") == nil)
        #expect(KodBearer.credential(from: nil) == nil)
        #expect(KodBearer.matches("secret", expected: "secret"))
        #expect(!KodBearer.matches("secret", expected: "Secret"))
        #expect(!KodBearer.matches("secret", expected: "secrets"))
        #expect(!KodBearer.matches("", expected: ""))
    }

    @Test func routesMatchTheDocumentedPaths() {
        let session = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let project = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        #expect(KodBridge.match(method: "GET", path: "/v1/health") == .match(.health))
        #expect(KodBridge.match(method: "GET", path: "/v1/projects") == .match(.projects))
        #expect(KodBridge.match(method: "GET", path: "/v1/sessions/\(session.uuidString)/messages/") == .match(.messages(session)))
        #expect(KodBridge.match(method: "POST", path: "/v1/sessions/\(session.uuidString)/messages") == .match(.sendMessage(session)))
        #expect(KodBridge.match(method: "POST", path: "/v1/projects/\(project.uuidString)/sessions") == .match(.startSession(project)))
        #expect(KodBridge.match(method: "PUT", path: "/v1/projects") == .methodNotAllowed)
        #expect(KodBridge.match(method: "GET", path: "/v1/nope") == .notFound)
        #expect(KodBridge.match(method: "GET", path: "/v1/sessions/not-a-uuid/messages") == .notFound)
        #expect(KodBridge.limit(in: ["limit": "500"]) == 200)
        #expect(KodBridge.limit(in: [:]) == 40)
        #expect(KodBridge.limit(in: ["limit": "0"]) == 1)
    }

    @Test func httpRequestParsesBearerAndBody() throws {
        let body = Data(#"{"text":"please review"}"#.utf8)
        var raw = Data("POST /v1/sessions/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/messages?limit=10 HTTP/1.1\r\n".utf8)
        raw.append(Data("Host: 127.0.0.1:47647\r\nAuthorization: Bearer secret\r\nContent-Type: application/json\r\n".utf8))
        raw.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8))
        raw.append(body)
        #expect(KodHTTP.decode(Data(raw.prefix(8))) == .needMore)
        guard case .ready(let request) = KodHTTP.decode(raw) else { Issue.record("expected a request"); return }
        #expect(request.method == "POST")
        #expect(request.path == "/v1/sessions/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/messages")
        #expect(request.query["limit"] == "10")
        #expect(request.header("authorization") == "Bearer secret")
        #expect(request.body == body)
        let text = try JSONDecoder().decode(KodTextBody.self, from: request.body)
        #expect(text.text == "please review")
    }

    @Test func httpRejectsAHugeBodyAndChunkedEncoding() {
        let huge = "POST /v1/health HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n"
        #expect(KodHTTP.decode(Data(huge.utf8)) == .tooLarge)
        let chunked = "POST /v1/health HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        #expect(KodHTTP.decode(Data(chunked.utf8)) == .invalid)
    }

    @Test func unauthorizedResponseAsksForBearer() {
        let text = String(decoding: KodHTTPResponse.error(401, "unauthorized").encoded(), as: UTF8.self)
        #expect(text.contains("401 Unauthorized"))
        #expect(text.contains("WWW-Authenticate: Bearer"))
        #expect(text.contains("\"error\":\"unauthorized\""))
    }

    @Test func attributionBadgesOnlyTheMatchingUserLine() {
        let session = UUID()
        let records = [KodAttribution(sessionID: session, text: "please review", at: Date())]
        let entries = [
            ChatEntry(id: "1", kind: .user, text: "hello"),
            ChatEntry(id: "2", kind: .assistant, text: "please review"),
            ChatEntry(id: "3", kind: .user, text: "please   review"),
        ]
        let stamped = KodAttributions.stamp(entries, sessionID: session, records: records)
        #expect(stamped.map(\.source) == [nil, nil, ChatEntry.kodCheckerSource])
        let other = KodAttributions.stamp(entries, sessionID: UUID(), records: records)
        #expect(other.allSatisfy { $0.source == nil })
    }

    @Test func attributionMatchesTheClippedTranscriptLine() {
        let session = UUID()
        let full = String(repeating: "b", count: ConversationLog.maxText) + "MORE"
        let shown = String(repeating: "b", count: ConversationLog.maxText)
        let records = [KodAttribution(sessionID: session, text: full, at: Date())]
        let entries = [ChatEntry(id: "1", kind: .user, text: shown)]
        #expect(KodAttributions.stamp(entries, sessionID: session, records: records)[0].source == ChatEntry.kodCheckerSource)
    }

    @Test func chatEntryWithoutSourceStillDecodes() throws {
        let entry = try JSONDecoder().decode(ChatEntry.self, from: Data(#"{"id":"1","kind":"user","text":"hi","isError":false}"#.utf8))
        #expect(entry.source == nil)
        #expect(entry.text == "hi")
    }

    @Test func diskKeepsTheNewestEntries() {
        let session = UUID()
        let attributions = (0..<KodBridgeDisk.maxAttributions + 25).map {
            KodAttribution(id: UUID(), sessionID: session, text: "\($0)", at: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        let log = (0..<KodBridgeDisk.maxLog + 10).map {
            KodActivityEntry(id: UUID(), at: Date(timeIntervalSince1970: TimeInterval($0)), direction: .inbound, title: "\($0)", detail: "", ok: true)
        }
        let trimmed = KodBridgeDisk(attributions: attributions, log: log).trimmed()
        #expect(trimmed.attributions.count == KodBridgeDisk.maxAttributions)
        #expect(trimmed.attributions.last?.text == attributions.last?.text)
        #expect(trimmed.log.count == KodBridgeDisk.maxLog)
        #expect(trimmed.log.last?.title == log.last?.title)
    }

    private func json(_ event: KodBridgeEvent) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: KodJSON.encode(event))
        return try #require(object as? [String: Any])
    }
}
