import Foundation
import Security

/// What the desktop widget shows: written by the app into the shared App Group container,
/// read by the widget extension. Keep it small — the widget only needs counts and a few rows.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case needsPermission
        case needsAnswer
        case idle
        case running

        public var label: String {
            switch self {
            case .needsPermission: String(localized: "Needs permission")
            case .needsAnswer: String(localized: "Asking a question")
            case .idle: String(localized: "Your turn")
            case .running: String(localized: "Running")
            }
        }

        public var isBlocked: Bool { self == .needsPermission || self == .needsAnswer }
    }

    public struct Item: Codable, Sendable, Equatable, Identifiable {
        /// ClaudeDeck session id (`claudedeck://session/<id>` opens it).
        public var id: UUID
        public var name: String
        public var project: String
        public var state: State
        public var detail: String?
        public var updatedAt: Date?

        public init(id: UUID, name: String, project: String, state: State, detail: String? = nil, updatedAt: Date? = nil) {
            self.id = id
            self.name = name
            self.project = project
            self.state = state
            self.detail = detail
            self.updatedAt = updatedAt
        }

        public var url: URL { WidgetSnapshot.sessionURL(id) }
    }

    /// Sessions waiting on a permission or a question (red).
    public var blocked: Int
    /// Sessions working (green).
    public var running: Int
    /// Finished and not yet looked at (yellow).
    public var unseen: Int
    /// Sessions needing attention, most urgent first (at most a handful).
    public var items: [Item]
    /// False once the app has quit (all terminals are gone).
    public var appRunning: Bool
    public var generatedAt: Date

    public init(blocked: Int = 0, running: Int = 0, unseen: Int = 0, items: [Item] = [], appRunning: Bool = true, generatedAt: Date = Date()) {
        self.blocked = blocked
        self.running = running
        self.unseen = unseen
        self.items = items
        self.appRunning = appRunning
        self.generatedAt = generatedAt
    }

    public static let empty = WidgetSnapshot(appRunning: false, generatedAt: .distantPast)

    /// Same content, ignoring when it was generated (to skip redundant writes).
    public func sameContent(as other: WidgetSnapshot) -> Bool {
        var a = self, b = other
        a.generatedAt = .distantPast
        b.generatedAt = .distantPast
        return a == b
    }

    // MARK: URLs

    public static let urlScheme = "claudedeck"

    public static func sessionURL(_ id: UUID) -> URL {
        URL(string: "\(urlScheme)://session/\(id.uuidString)")!
    }

    /// The session id in `claudedeck://session/<uuid>`, if that's what `url` is.
    public static func sessionID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == urlScheme, url.host()?.lowercased() == "session" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    // MARK: Encoding

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> WidgetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(WidgetSnapshot.self, from: data)
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    // MARK: Shared container

    /// macOS team-prefixed App Group shared by the app and the widget extension. Read from this
    /// process's own entitlements (set from DECK_APP_GROUP at build time), so a build signed with
    /// another team just works; nil when not entitled (e.g. the SwiftPM build).
    public static let appGroupID: String? = {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
        return (value as? [String])?.first
    }()
    public static let fileName = "widget-snapshot.json"

    /// The snapshot file in the App Group container, or nil when this process isn't entitled
    /// to a group. On macOS `containerURL` returns a path even without the entitlement and
    /// touching it can trigger a privacy prompt, so check the entitlement first.
    public static func sharedFileURL() -> URL? {
        guard let appGroupID else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }
}
