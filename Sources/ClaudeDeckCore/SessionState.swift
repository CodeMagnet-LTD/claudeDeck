import Foundation

public enum SessionActivity: String, Codable, Sendable, CaseIterable {
    case running
    case needsPermission
    case needsAnswer
    case idle
    case ended

    /// The user has to do something (red badge).
    public var isBlocked: Bool { self == .needsPermission || self == .needsAnswer }

    /// Worth a notification when a session enters this state.
    public var isAttention: Bool { isBlocked || self == .idle }
}

/// Contents of `~/.claude/deck/sessions/<session_id>.json`, written by the hook script.
public struct HookStatus: Codable, Sendable, Equatable {
    public var sessionID: String
    public var terminalID: String?
    public var pid: Int32?
    public var cwd: String?
    public var transcriptPath: String?
    public var state: SessionActivity
    public var event: String
    public var detail: String?
    public var toolName: String?
    public var notificationType: String?
    public var source: String?
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case terminalID = "terminal_id"
        case pid, cwd
        case transcriptPath = "transcript_path"
        case state, event, detail
        case toolName = "tool_name"
        case notificationType = "notification_type"
        case source
        case updatedAt = "updated_at"
    }

    public init(
        sessionID: String, terminalID: String?, pid: Int32? = nil, cwd: String? = nil,
        transcriptPath: String? = nil, state: SessionActivity, event: String, detail: String? = nil,
        toolName: String? = nil, notificationType: String? = nil, source: String? = nil, updatedAt: Date
    ) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.pid = pid
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.state = state
        self.event = event
        self.detail = detail
        self.toolName = toolName
        self.notificationType = notificationType
        self.source = source
        self.updatedAt = updatedAt
    }

    public static func decode(_ data: Data) throws -> HookStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(HookStatus.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }
}

/// Something the transcript said that hooks don't report (Esc, permission denied).
public struct TranscriptSignal: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case interrupted
        case toolDenied
    }
    public var kind: Kind
    public var at: Date

    public init(kind: Kind, at: Date) {
        self.kind = kind
        self.at = at
    }
}

/// The state shown in the UI for one ClaudeDeck terminal.
public struct EffectiveStatus: Sendable, Equatable {
    public var activity: SessionActivity
    public var detail: String?
    public var updatedAt: Date
    public var claudeSessionID: String?
    public var transcriptPath: String?

    public init(activity: SessionActivity, detail: String?, updatedAt: Date, claudeSessionID: String?, transcriptPath: String?) {
        self.activity = activity
        self.detail = detail
        self.updatedAt = updatedAt
        self.claudeSessionID = claudeSessionID
        self.transcriptPath = transcriptPath
    }

    /// Combines the latest hook status, the latest transcript signal and process liveness.
    /// Only concrete events change the state — never timers or guesses.
    /// - Parameter answeredAt: when the user last submitted input (Enter / choice) in the terminal.
    ///   Approving a permission fires no hook until the tool finishes, so an answer given after
    ///   the blocking event means Claude is running again.
    public static func resolve(
        hook: HookStatus?,
        transcript: TranscriptSignal?,
        answeredAt: Date? = nil,
        processAlive: Bool
    ) -> EffectiveStatus? {
        guard let hook else { return nil }
        var status = EffectiveStatus(
            activity: hook.state,
            detail: hook.detail,
            updatedAt: hook.updatedAt,
            claudeSessionID: hook.sessionID,
            transcriptPath: hook.transcriptPath
        )
        if let answeredAt, answeredAt > hook.updatedAt, hook.state.isBlocked {
            status.activity = .running
            status.updatedAt = answeredAt
        }
        if let transcript, transcript.at > hook.updatedAt, hook.state != .idle, hook.state != .ended {
            status.activity = .idle
            status.updatedAt = transcript.at
            status.detail = switch transcript.kind {
            case .interrupted: "Kesildi — sıra sende"
            case .toolDenied: "İzin reddedildi — sıra sende"
            }
        }
        if !processAlive, status.activity != .ended {
            status.activity = .ended
        }
        return status
    }
}
