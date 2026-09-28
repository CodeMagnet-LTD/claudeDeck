import Foundation

public struct ProjectGroup: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var collapsed: Bool
    public var colorIndex: Int

    public init(id: UUID = UUID(), name: String, collapsed: Bool = false, colorIndex: Int = 0) {
        self.id = id
        self.name = name
        self.collapsed = collapsed
        self.colorIndex = colorIndex
    }
}

public struct Project: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var path: String
    public var name: String
    public var groupID: UUID?
    public var pinned: Bool
    public var collapsed: Bool

    public init(id: UUID = UUID(), path: String, name: String? = nil, groupID: UUID? = nil, pinned: Bool = false, collapsed: Bool = false) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.groupID = groupID
        self.pinned = pinned
        self.collapsed = collapsed
    }
}

public enum SessionKind: String, Codable, Sendable {
    /// Runs `claude` (status via hooks).
    case claude
    /// A plain login shell in the project folder.
    case shell
}

/// A ClaudeDeck terminal slot. Its `id` is the `CLAUDEDECK_TERMINAL_ID`, stable across
/// app restarts so the hook files keep mapping to it after `claude --resume`.
public struct DeckSession: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var projectID: UUID
    public var name: String
    public var kind: SessionKind
    /// Last known Claude `session_id` (from hooks) — used for `--resume` on relaunch.
    public var claudeSessionID: String?
    /// Transcript of `claudeSessionID`; resume is only possible once it exists on disk.
    public var transcriptPath: String?
    public var createdAt: Date
    public var lastActivityAt: Date?
    /// Whether the terminal was running when the app last saved; such sessions are resumed on launch.
    public var isOpen: Bool
    /// Shell sessions: typed into the shell every time it starts (e.g. "yarn start").
    public var startupCommand: String?
    /// Shell sessions: start whenever the app launches, even if closed at quit.
    public var autoStart: Bool

    public init(id: UUID = UUID(), projectID: UUID, name: String, kind: SessionKind = .claude, claudeSessionID: String? = nil,
                createdAt: Date = Date(), lastActivityAt: Date? = nil, isOpen: Bool = true) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.kind = kind
        self.claudeSessionID = claudeSessionID
        self.transcriptPath = nil
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.isOpen = isOpen
        self.startupCommand = nil
        self.autoStart = false
    }
    /// Tolerant decoding: files written by older versions lack newer keys (e.g. `kind`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .claude
        claudeSessionID = try c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }
}

public struct DeckSettings: Codable, Sendable, Equatable {
    public var resumeOnLaunch = true
    public var compactOnResume = true
    /// Transcripts bigger than this get `/compact` after an automatic resume.
    public var compactThresholdKB = 800
    public var notifications = true
    public var bounceDock = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeckSettings()
        resumeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .resumeOnLaunch) ?? d.resumeOnLaunch
        compactOnResume = try c.decodeIfPresent(Bool.self, forKey: .compactOnResume) ?? d.compactOnResume
        compactThresholdKB = try c.decodeIfPresent(Int.self, forKey: .compactThresholdKB) ?? d.compactThresholdKB
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? d.notifications
        bounceDock = try c.decodeIfPresent(Bool.self, forKey: .bounceDock) ?? d.bounceDock
    }
}

/// Everything ClaudeDeck persists, stored as one JSON file in Application Support.
public struct DeckData: Codable, Sendable, Equatable {
    public var version = 1
    public var groups: [ProjectGroup] = []
    public var projects: [Project] = []
    public var sessions: [DeckSession] = []
    public var settings = DeckSettings()
    public var selectedSessionID: UUID?
    /// Sessions shown side by side in the detail area, left to right.
    public var panes: [UUID] = []

    public static let maxPanes = 4

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        groups = try c.decodeIfPresent([ProjectGroup].self, forKey: .groups) ?? []
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        sessions = try c.decodeIfPresent([DeckSession].self, forKey: .sessions) ?? []
        settings = try c.decodeIfPresent(DeckSettings.self, forKey: .settings) ?? DeckSettings()
        selectedSessionID = try c.decodeIfPresent(UUID.self, forKey: .selectedSessionID)
        panes = try c.decodeIfPresent([UUID].self, forKey: .panes) ?? []
    }

    // MARK: Mutations

    @discardableResult
    public mutating func addProject(path: String) -> Project {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == normalized }) { return existing }
        let project = Project(path: normalized)
        projects.append(project)
        return project
    }

    public mutating func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        sessions.removeAll { $0.projectID == id }
    }

    /// New session named after the project: "app", then "app · 2", "app · 3"…
    /// Shell sessions: "app · terminal", "app · terminal 2"…
    @discardableResult
    public mutating func addSession(to projectID: UUID, kind: SessionKind = .claude, claudeSessionID: String? = nil, name: String? = nil) -> DeckSession? {
        guard let project = projects.first(where: { $0.id == projectID }) else { return nil }
        let session = DeckSession(
            projectID: projectID,
            name: name ?? (kind == .shell ? nextShellName(for: project) : nextSessionName(for: project)),
            kind: kind,
            claudeSessionID: kind == .claude ? claudeSessionID : nil
        )
        sessions.append(session)
        return session
    }

    public func nextSessionName(for project: Project) -> String {
        let taken = Set(sessions.filter { $0.projectID == project.id }.map(\.name))
        if !taken.contains(project.name) { return project.name }
        var n = 2
        while taken.contains("\(project.name) · \(n)") { n += 1 }
        return "\(project.name) · \(n)"
    }

    /// The Claude session id to pass to `--resume`, if its transcript exists.
    public func resumableID(for id: UUID, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard let session = session(id), let sid = session.claudeSessionID else { return nil }
        let path = session.transcriptPath ?? project(session.projectID).map {
            TranscriptIndex.defaultRoot().appending(path: Transcript.projectDirectoryName(for: $0.path)).appending(path: "\(sid).jsonl").path
        }
        guard let path, fileExists(path) else { return nil }
        return sid
    }

    /// A terminal that runs `command` on start and auto-starts with the app: "app · yarn start".
    @discardableResult
    public mutating func addCommandShell(to projectID: UUID, command: String) -> DeckSession? {
        guard let project = project(projectID) else { return nil }
        let taken = Set(sessions.filter { $0.projectID == projectID }.map(\.name))
        var name = "\(project.name) · \(command.prefix(40))"
        var n = 2
        while taken.contains(name) { name = "\(project.name) · \(command.prefix(40)) \(n)"; n += 1 }
        guard var session = addSession(to: projectID, kind: .shell, name: name) else { return nil }
        updateSession(session.id) {
            $0.startupCommand = command
            $0.autoStart = true
        }
        session.startupCommand = command
        session.autoStart = true
        return session
    }

    /// Sessions to start when the app launches.
    public func sessionsToStartOnLaunch(resumeOpen: Bool) -> [DeckSession] {
        sessions.filter { s in
            (s.kind == .shell && s.autoStart && s.startupCommand != nil) || (resumeOpen && s.isOpen)
        }
    }

    public func nextShellName(for project: Project) -> String {
        let taken = Set(sessions.filter { $0.projectID == project.id }.map(\.name))
        let base = "\(project.name) · terminal"
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    public mutating func removeSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        closePane(id)
        if selectedSessionID == id { selectedSessionID = panes.first }
    }

    // MARK: Split panes

    /// Selecting a session: focus its pane if visible, else show it in the focused pane.
    public mutating func select(_ id: UUID?) {
        defer { selectedSessionID = id }
        guard let id else { return }
        if panes.contains(id) { return }
        if let focused = selectedSessionID, let i = panes.firstIndex(of: focused) {
            panes[i] = id
        } else if panes.isEmpty {
            panes = [id]
        } else {
            panes[panes.count - 1] = id
        }
    }

    /// Adds a pane next to `anchor` (default: the focused pane). Returns false when full.
    @discardableResult
    public mutating func openPane(_ id: UUID, besideOf anchor: UUID? = nil, before: Bool = false) -> Bool {
        if panes.isEmpty, let current = selectedSessionID, current != id { panes = [current] }
        if let existing = panes.firstIndex(of: id) {
            // Moving an already visible session next to another pane.
            guard let anchor, anchor != id, panes.contains(anchor) else { selectedSessionID = id; return true }
            panes.remove(at: existing)
            let a = panes.firstIndex(of: anchor)!
            panes.insert(id, at: before ? a : a + 1)
            selectedSessionID = id
            return true
        }
        guard panes.count < Self.maxPanes else { return false }
        let target = anchor ?? selectedSessionID
        if let target, let a = panes.firstIndex(of: target) {
            panes.insert(id, at: before ? a : a + 1)
        } else {
            panes.append(id)
        }
        selectedSessionID = id
        return true
    }

    public mutating func closePane(_ id: UUID) {
        guard let i = panes.firstIndex(of: id) else { return }
        panes.remove(at: i)
        if selectedSessionID == id {
            selectedSessionID = panes.isEmpty ? nil : panes[min(i, panes.count - 1)]
        }
    }

    /// Visible panes, dropping ids of sessions that no longer exist.
    public var visiblePanes: [UUID] {
        let valid = panes.filter { id in sessions.contains { $0.id == id } }
        if !valid.isEmpty { return valid }
        return selectedSessionID.map { [$0] } ?? []
    }

    public mutating func updateSession(_ id: UUID, _ change: (inout DeckSession) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[i])
    }

    public mutating func updateProject(_ id: UUID, _ change: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[i])
    }

    @discardableResult
    public mutating func addGroup(name: String) -> ProjectGroup {
        let group = ProjectGroup(name: name, colorIndex: groups.count % 8)
        groups.append(group)
        return group
    }

    public mutating func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        for i in projects.indices where projects[i].groupID == id { projects[i].groupID = nil }
    }

    public mutating func updateGroup(_ id: UUID, _ change: (inout ProjectGroup) -> Void) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        change(&groups[i])
    }

    public func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }
    public func session(_ id: UUID) -> DeckSession? { sessions.first { $0.id == id } }
    public func sessions(in projectID: UUID) -> [DeckSession] { sessions.filter { $0.projectID == projectID } }

    // MARK: Sidebar sections (MonoCode layout: Pinned / Groups / Projects)

    public struct Sections: Equatable, Sendable {
        public var pinned: [Project]
        public var groups: [(group: ProjectGroup, projects: [Project])]
        public var ungrouped: [Project]

        public static func == (a: Sections, b: Sections) -> Bool {
            a.pinned == b.pinned && a.ungrouped == b.ungrouped
                && a.groups.map(\.group) == b.groups.map(\.group)
                && a.groups.map(\.projects) == b.groups.map(\.projects)
        }
    }

    public var sections: Sections {
        let pinned = projects.filter(\.pinned)
        let rest = projects.filter { !$0.pinned }
        let groupIDs = Set(groups.map(\.id))
        return Sections(
            pinned: pinned,
            groups: groups.map { g in (g, rest.filter { $0.groupID == g.id }) },
            ungrouped: rest.filter { $0.groupID.map { !groupIDs.contains($0) } ?? true }
        )
    }
}

/// Loads / saves `DeckData` atomically.
public struct DeckDataStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func `default`() -> DeckDataStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DeckDataStore(url: base.appending(path: "ClaudeDeck/deck.json"))
    }

    public func load() -> DeckData {
        guard let data = try? Data(contentsOf: url) else { return DeckData() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let decoded = try? decoder.decode(DeckData.self, from: data) { return decoded }
        // Keep the unreadable file instead of silently overwriting the user's data.
        let broken = url.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: url, to: broken)
        return DeckData()
    }

    public func save(_ deck: DeckData) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(deck).write(to: url, options: .atomic)
    }
}
