import Foundation
import Darwin

// iCloud Drive sync of the project list and groups between the user's Macs.
//
// The shared file (`projects.json`) holds the union of every Mac's projects and groups,
// each with a `modifiedAt` stamp. Merging is last-writer-wins per item (projects keyed by
// path, groups by id). Deletions never propagate: a Mac only ever *adds* or *updates* items
// from the file, and the file only ever grows. Items deleted on this Mac are remembered as
// local tombstones so an older copy in the file doesn't bring them back.

/// The synced fields of a project. `path` is stored home-relative (`~/…`) in the file.
public struct SyncedProject: Codable, Sendable, Equatable {
    public var path: String
    public var name: String
    public var groupID: UUID?
    public var pinned: Bool
    public var modifiedAt: Date

    public init(path: String, name: String, groupID: UUID?, pinned: Bool, modifiedAt: Date) {
        self.path = path
        self.name = name
        self.groupID = groupID
        self.pinned = pinned
        self.modifiedAt = modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? URL(fileURLWithPath: path).lastPathComponent
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .distantPast
    }

    /// Same synced content (ignoring the stamp).
    func sameContent(_ other: SyncedProject) -> Bool {
        path == other.path && name == other.name && groupID == other.groupID && pinned == other.pinned
    }

    /// Deterministic tie-breaker for equal stamps.
    var contentKey: String { "\(path)\u{1}\(name)\u{1}\(groupID?.uuidString ?? "")\u{1}\(pinned)" }
}

/// The synced fields of a group (`collapsed` is per-Mac).
public struct SyncedGroup: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var colorIndex: Int
    public var modifiedAt: Date

    public init(id: UUID, name: String, colorIndex: Int, modifiedAt: Date) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.modifiedAt = modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .distantPast
    }

    func sameContent(_ other: SyncedGroup) -> Bool {
        id == other.id && name == other.name && colorIndex == other.colorIndex
    }

    var contentKey: String { "\(id.uuidString)\u{1}\(name)\u{1}\(colorIndex)" }
}

/// Contents of the shared `projects.json`.
public struct SyncPayload: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = SyncPayload.currentVersion
    public var groups: [SyncedGroup] = []
    public var projects: [SyncedProject] = []

    public init(groups: [SyncedGroup] = [], projects: [SyncedProject] = []) {
        self.groups = groups
        self.projects = projects
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        groups = try c.decodeIfPresent([SyncedGroup].self, forKey: .groups) ?? []
        projects = try c.decodeIfPresent([SyncedProject].self, forKey: .projects) ?? []
    }

    /// Canonical order so identical content always encodes to identical bytes.
    public var canonical: SyncPayload {
        var p = self
        p.version = SyncPayload.currentVersion
        p.groups.sort { $0.id.uuidString < $1.id.uuidString }
        p.projects.sort { $0.path < $1.path }
        return p
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(canonical)) ?? Data()
    }

    /// Returns nil for garbage or a payload written by a newer, incompatible version.
    public static func decode(_ data: Data) -> SyncPayload? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let payload = try? decoder.decode(SyncPayload.self, from: data),
              payload.version <= currentVersion else { return nil }
        return payload
    }
}

/// Per-Mac bookkeeping kept in `DeckData`: the last synced value of every item (with its
/// stamp) and tombstones of items deleted on this Mac. Keys: absolute project path / group id.
public struct DeckSyncState: Codable, Sendable, Equatable {
    public var projects: [String: SyncedProject] = [:]
    public var groups: [String: SyncedGroup] = [:]
    public var deletedProjects: [String: Date] = [:]
    public var deletedGroups: [String: Date] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([String: SyncedProject].self, forKey: .projects) ?? [:]
        groups = try c.decodeIfPresent([String: SyncedGroup].self, forKey: .groups) ?? [:]
        deletedProjects = try c.decodeIfPresent([String: Date].self, forKey: .deletedProjects) ?? [:]
        deletedGroups = try c.decodeIfPresent([String: Date].self, forKey: .deletedGroups) ?? [:]
    }
}

public enum DeckSync {
    public static let fileName = "projects.json"

    /// Stamps are kept at millisecond precision so they survive JSON round trips unchanged.
    static func round(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// `/Users/me/x` → `~/x` so the same folder matches on Macs with different user names.
    static func portable(_ path: String, home: String) -> String {
        let home = normalize(home)
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func expand(_ path: String, home: String) -> String {
        if path == "~" { return normalize(home) }
        if path.hasPrefix("~/") { return normalize(home + path.dropFirst(1)) }
        return normalize(path)
    }

    // MARK: Stamping

    /// Records local edits: items whose synced fields differ from the last known value get
    /// `modifiedAt = now`; items that disappeared become local tombstones.
    public static func stamp(_ deck: inout DeckData, now: Date = Date()) {
        let now = round(now)
        var state = deck.syncState
        var seenProjects = Set<String>()
        for p in deck.projects {
            let key = normalize(p.path)
            seenProjects.insert(key)
            let current = SyncedProject(path: key, name: p.name, groupID: p.groupID, pinned: p.pinned, modifiedAt: now)
            if let known = state.projects[key], known.sameContent(current) { continue }
            state.projects[key] = current
            state.deletedProjects[key] = nil
        }
        for key in state.projects.keys where !seenProjects.contains(key) {
            state.projects[key] = nil
            state.deletedProjects[key] = now
        }
        var seenGroups = Set<String>()
        for g in deck.groups {
            let key = g.id.uuidString
            seenGroups.insert(key)
            let current = SyncedGroup(id: g.id, name: g.name, colorIndex: g.colorIndex, modifiedAt: now)
            if let known = state.groups[key], known.sameContent(current) { continue }
            state.groups[key] = current
            state.deletedGroups[key] = nil
        }
        for key in state.groups.keys where !seenGroups.contains(key) {
            state.groups[key] = nil
            state.deletedGroups[key] = now
        }
        if state != deck.syncState { deck.syncState = state }
    }

    // MARK: Payload

    /// This Mac's projects and groups with their stamps (local edits since the last stamp get `now`).
    public static func payload(from deck: DeckData, now: Date = Date(), home: String = NSHomeDirectory()) -> SyncPayload {
        var deck = deck
        stamp(&deck, now: now)
        let projects = deck.projects.compactMap { p -> SyncedProject? in
            guard var s = deck.syncState.projects[normalize(p.path)] else { return nil }
            s.path = portable(s.path, home: home)
            return s
        }
        let groups = deck.groups.compactMap { deck.syncState.groups[$0.id.uuidString] }
        return SyncPayload(groups: groups, projects: projects).canonical
    }

    /// True when `a` should replace `b` (newer stamp; content order breaks ties).
    static func wins(_ a: SyncedProject, over b: SyncedProject) -> Bool {
        a.modifiedAt != b.modifiedAt ? a.modifiedAt > b.modifiedAt : a.contentKey > b.contentKey
    }

    static func wins(_ a: SyncedGroup, over b: SyncedGroup) -> Bool {
        a.modifiedAt != b.modifiedAt ? a.modifiedAt > b.modifiedAt : a.contentKey > b.contentKey
    }

    /// Per-item last-writer-wins union of two payloads (what gets written to the file, so
    /// items this Mac doesn't have — e.g. deleted here — stay in the file for the other Macs).
    public static func combine(_ a: SyncPayload, _ b: SyncPayload) -> SyncPayload {
        var projects: [String: SyncedProject] = [:]
        for p in a.projects + b.projects {
            if let existing = projects[p.path], !wins(p, over: existing) { continue }
            projects[p.path] = p
        }
        var groups: [UUID: SyncedGroup] = [:]
        for g in a.groups + b.groups {
            if let existing = groups[g.id], !wins(g, over: existing) { continue }
            groups[g.id] = g
        }
        return SyncPayload(groups: Array(groups.values), projects: Array(projects.values)).canonical
    }

    // MARK: Merge

    /// Applies a remote payload to the local deck: adds missing projects/groups, updates items
    /// whose remote stamp is newer. Never removes anything and never touches sessions, panes,
    /// selection, settings or per-Mac fields (`collapsed`, project ids).
    public static func merge(local: DeckData, remote: SyncPayload, now: Date = Date(), home: String = NSHomeDirectory()) -> DeckData {
        var deck = local
        stamp(&deck, now: now)
        var state = deck.syncState

        for r in remote.groups {
            let key = r.id.uuidString
            if let i = deck.groups.firstIndex(where: { $0.id == r.id }) {
                guard let known = state.groups[key], wins(r, over: known) else { continue }
                deck.groups[i].name = r.name
                deck.groups[i].colorIndex = r.colorIndex
                state.groups[key] = r
            } else {
                if let deletedAt = state.deletedGroups[key], deletedAt >= r.modifiedAt { continue }
                deck.groups.append(ProjectGroup(id: r.id, name: r.name, colorIndex: r.colorIndex))
                state.groups[key] = r
                state.deletedGroups[key] = nil
            }
        }

        for var r in remote.projects {
            let key = expand(r.path, home: home)
            r.path = key
            if let i = deck.projects.firstIndex(where: { normalize($0.path) == key }) {
                guard let known = state.projects[key], wins(r, over: known) else { continue }
                deck.projects[i].name = r.name
                deck.projects[i].groupID = r.groupID
                deck.projects[i].pinned = r.pinned
                state.projects[key] = r
            } else {
                if let deletedAt = state.deletedProjects[key], deletedAt >= r.modifiedAt { continue }
                deck.projects.append(Project(path: key, name: r.name, groupID: r.groupID, pinned: r.pinned))
                state.projects[key] = r
                state.deletedProjects[key] = nil
            }
        }

        if state != deck.syncState { deck.syncState = state }
        return deck
    }
}

/// Reads / atomically writes the shared sync file in a (injectable) folder.
public struct DeckSyncFile: Sendable {
    public enum ReadResult: Equatable, Sendable {
        /// No file yet (first Mac to enable sync).
        case missing
        /// iCloud evicted the file (only `.projects.json.icloud` is present): don't overwrite it.
        case notDownloaded
        /// Present but not decodable (partial write, newer format…): don't overwrite it.
        case unreadable
        case ok(Data, SyncPayload)
    }

    public let folder: URL
    public var url: URL { folder.appending(path: DeckSync.fileName) }
    var placeholderURL: URL { folder.appending(path: ".\(DeckSync.fileName).icloud") }

    public init(folder: URL) { self.folder = folder }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs` — iCloud Drive's local root.
    public static func iCloudDriveRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
    }

    public static func iCloudDriveAvailable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: iCloudDriveRoot(home: home).path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The ClaudeDeck folder in iCloud Drive (nil when iCloud Drive isn't set up).
    public static func defaultFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        iCloudDriveAvailable(home: home) ? iCloudDriveRoot(home: home).appending(path: "ClaudeDeck") : nil
    }

    public func read() -> ReadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            if fm.fileExists(atPath: placeholderURL.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                return .notDownloaded
            }
            return .missing
        }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        guard let payload = SyncPayload.decode(data) else { return .unreadable }
        return .ok(data, payload)
    }

    /// Writes to a temp file in the same folder, then renames it over the target (atomic).
    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appending(path: ".\(DeckSync.fileName).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp)
            guard Darwin.rename(temp.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
