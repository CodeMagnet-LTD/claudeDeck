import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct WidgetSnapshotTests {
    let sample = WidgetSnapshot(
        blocked: 2, running: 3, unseen: 1,
        items: [
            .init(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, name: "api", project: "api",
                  state: .needsPermission, detail: "Bash: npm test", updatedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            .init(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, name: "web · 2", project: "web", state: .idle),
        ],
        generatedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )

    @Test func roundTrip() throws {
        let decoded = try WidgetSnapshot.decode(sample.encoded())
        #expect(decoded == sample)
    }

    @Test func writeAndRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(WidgetSnapshot.fileName)
        try sample.write(to: url)
        #expect(WidgetSnapshot.read(from: url) == sample)
        #expect(WidgetSnapshot.read(from: dir.appendingPathComponent("missing.json")) == nil)
    }

    @Test func decodesSchema() throws {
        let json = """
        {"appRunning":true,"blocked":1,"generatedAt":1700000000,"running":0,"unseen":0,
         "items":[{"id":"11111111-2222-3333-4444-555555555555","name":"n","project":"p","state":"needsAnswer"}]}
        """
        let s = try WidgetSnapshot.decode(Data(json.utf8))
        #expect(s.blocked == 1)
        #expect(s.generatedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(s.items.first?.state == .needsAnswer)
        #expect(s.items.first?.detail == nil)
        #expect(s.items.first?.state.label == "Asking a question")
    }

    @Test func sameContentIgnoresTimestamp() {
        var other = sample
        other.generatedAt = Date()
        #expect(sample.sameContent(as: other))
        other.running = 0
        #expect(!sample.sameContent(as: other))
    }

    @Test func sessionURLRoundTrip() {
        let id = UUID()
        let url = WidgetSnapshot.sessionURL(id)
        #expect(url.absoluteString == "claudedeck://session/\(id.uuidString)")
        #expect(WidgetSnapshot.sessionID(from: url) == id)
        #expect(WidgetSnapshot.sessionID(from: URL(string: "claudedeck://other/\(id.uuidString)")!) == nil)
        #expect(WidgetSnapshot.sessionID(from: URL(string: "https://session/\(id.uuidString)")!) == nil)
    }

    @Test func noSharedURLWithoutEntitlement() {
        // The test runner isn't entitled to the App Group.
        #expect(WidgetSnapshot.sharedFileURL() == nil)
    }
}
