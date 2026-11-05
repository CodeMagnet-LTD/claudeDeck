import ClaudeDeckCore
import Foundation
import Observation

/// Webhook posts and the loopback API. Status transitions come from `AppModel.emitAttentionChanges`.
/// Inbound text goes through `sendPrompt` / `typePrompt`, the same path as typing in the app.
@MainActor
@Observable
final class KodBridgeController {
    private(set) var listening = false
    private(set) var boundPort: UInt16 = UInt16(KodBridge.defaultPort)
    private(set) var listenError: String?
    private(set) var token = ""
    private(set) var log: [KodActivityEntry] = []
    private(set) var attributions: [KodAttribution] = []
    var showLog = false
    private(set) var lastDeliveryNote: String?

    @ObservationIgnored private let server = KodBridgeServer()
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var storageURL: URL?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var pendingPort: UInt16?
    @ObservationIgnored private let webhookSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = KodWebhook.timeout
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    func start(model: AppModel, storageDirectory: URL) {
        self.model = model
        storageURL = storageDirectory.appending(path: "kod-bridge.json")
        load()
        server.onState = { [weak self] state in
            Task { @MainActor in self?.applyListen(state) }
        }
        apply()
    }

    /// Quit: stop accepting calls. In-flight webhook posts may still finish.
    func shutdown() {
        stopped = true
        pendingPort = nil
        server.stop()
        listening = false
        save()
    }

    func apply() {
        guard let model, !stopped else { return }
        guard model.deck.settings.kodBridgeEnabled else {
            pendingPort = nil
            listenError = nil
            server.stop()
            listening = false
            return
        }
        ensureToken()
        let configured = model.deck.settings.kodBridgePort
        guard let port = KodBridge.sanitizedPort(configured) else {
            pendingPort = nil
            server.stop()
            listening = false
            listenError = switch KodBridge.portProblem(configured) {
            case .remoteMode: String(localized: "Port 47821 belongs to remote mode. Pick another port.")
            default: String(localized: "Choose a port from 1024 to 65535.")
            }
            return
        }
        if listening, boundPort == port { return }
        if pendingPort == port { return }
        pendingPort = port
        server.start(port: port) { [weak self] request in
            guard let self else { return .error(503, "unavailable") }
            return await self.handle(request)
        }
    }

    func regenerateToken() {
        let created = KodBridgeKeychain.makeToken()
        KodBridgeKeychain.setToken(created)
        token = created
    }

    func notes(for sessionID: UUID) -> [KodAttribution] {
        Array(attributions.filter { $0.sessionID == sessionID }.suffix(3))
    }

    func hasAttribution(_ sessionID: UUID) -> Bool {
        attributions.contains { $0.sessionID == sessionID }
    }

    func stamp(_ entries: [ChatEntry], sessionID: UUID) -> [ChatEntry] {
        KodAttributions.stamp(entries, sessionID: sessionID, records: attributions)
    }

    /// A finished turn, a permission prompt, or a question. Not called for SessionStart idle.
    func note(sessionID: UUID, activity: SessionActivity) {
        guard !stopped, let model, model.deck.settings.kodBridgeEnabled else { return }
        guard model.deck.session(sessionID)?.kind == .claude else { return }
        guard let name = KodBridge.eventName(for: activity) else { return }
        guard let url = KodBridge.webhookURL(model.deck.settings.kodWebhookURL) else { return }
        let sessionName = model.deck.session(sessionID)?.name ?? ""
        let project = model.deck.session(sessionID).flatMap { model.deck.project($0.projectID) }
        let path = model.hookStatuses[sessionID]?.transcriptPath ?? model.deck.transcriptPath(for: sessionID)
        let detail = KodBridge.clip(model.status(of: sessionID).detail, KodBridge.maxDetailCharacters)
        let projectName = project?.name ?? ""
        let projectPath = project?.path ?? ""
        let authorization = KodBridgeKeychain.authorization()
        Task {
            let entries: [ChatEntry]
            if let path {
                entries = await Task.detached { ConversationLog.entries(of: URL(fileURLWithPath: path)) }.value
            } else {
                entries = []
            }
            let excerpt = KodBridge.excerpt(from: entries)
            let event = KodBridgeEvent(
                event: name,
                projectName: projectName,
                projectPath: projectPath,
                sessionID: sessionID.uuidString,
                timestamp: Date(),
                lastUserPrompt: excerpt.prompt,
                lastAssistantReply: excerpt.reply,
                finished: KodBridge.finished(activity),
                waitingForInput: KodBridge.waitingForInput(activity),
                transcriptPath: path,
                detail: detail
            )
            let result = await KodWebhook.deliver(event, to: url, authorization: authorization, session: self.webhookSession)
            self.recordOutbound(event, result: result, sessionName: sessionName)
        }
    }

    func sendTest() {
        guard let model, model.deck.settings.kodBridgeEnabled else { return }
        guard let url = KodBridge.webhookURL(model.deck.settings.kodWebhookURL) else {
            let message = String(localized: "The webhook URL needs to start with http:// or https://.")
            lastDeliveryNote = message
            record(KodActivityEntry(direction: .outbound, title: String(localized: "Test event"), detail: message, ok: false))
            return
        }
        let session = model.deck.selectedSessionID.flatMap { model.deck.session($0) }
        let project = session.flatMap { model.deck.project($0.projectID) }
        let event = KodBridgeEvent(
            event: KodBridge.testEvent,
            projectName: project?.name ?? "",
            projectPath: project?.path ?? "",
            sessionID: session?.id.uuidString ?? "00000000-0000-0000-0000-000000000000",
            timestamp: Date(),
            lastUserPrompt: nil,
            lastAssistantReply: "Test event from ClaudeDeck.",
            finished: true,
            waitingForInput: false,
            transcriptPath: nil,
            detail: nil
        )
        let authorization = KodBridgeKeychain.authorization()
        let sessionName = session?.name ?? ""
        Task {
            let result = await KodWebhook.deliver(event, to: url, authorization: authorization, session: self.webhookSession)
            self.recordOutbound(event, result: result, sessionName: sessionName)
            self.lastDeliveryNote = result.delivered
                ? String(localized: "Test event sent.")
                : String(localized: "Test event was not delivered.")
        }
    }

    // MARK: HTTP

    private func handle(_ request: KodHTTPRequest) async -> KodHTTPResponse {
        let presented = KodBearer.credential(from: request.header("authorization"))
        guard let presented, KodBearer.matches(presented, expected: token) else {
            return .error(401, "unauthorized")
        }
        switch KodBridge.match(method: request.method, path: request.path) {
        case .notFound:
            return .error(404, "not_found")
        case .methodNotAllowed:
            return .error(405, "method_not_allowed")
        case .match(.health):
            return .json(200, KodHealth(ok: true))
        case .match(.projects):
            return .json(200, projectList())
        case .match(.messages(let id)):
            return await messages(id, limit: KodBridge.limit(in: request.query))
        case .match(.sendMessage(let id)):
            return send(id, body: request.body)
        case .match(.startSession(let id)):
            return start(id, body: request.body)
        }
    }

    private func projectList() -> KodProjectList {
        guard let model else { return KodProjectList(projects: []) }
        let projects = model.deck.projects.map { project in
            KodProject(id: project.id, name: project.name, path: project.path, sessions: model.deck.sessions(in: project.id).map { session in
                let status = model.status(of: session.id)
                let path = model.hookStatuses[session.id]?.transcriptPath ?? model.deck.transcriptPath(for: session.id)
                return KodSessionInfo(
                    id: session.id,
                    name: session.name,
                    kind: session.kind.rawValue,
                    status: Self.statusName(status.display),
                    detail: status.detail,
                    updatedAt: status.updatedAt,
                    transcriptPath: path,
                    claudeSessionID: session.claudeSessionID ?? model.hookStatuses[session.id]?.sessionID
                )
            })
        }
        return KodProjectList(projects: projects)
    }

    private func messages(_ id: UUID, limit: Int) async -> KodHTTPResponse {
        guard let model, let session = model.deck.session(id) else { return .error(404, "not_found") }
        guard session.kind == .claude else { return .error(404, "not_claude") }
        let path = model.hookStatuses[id]?.transcriptPath ?? model.deck.transcriptPath(for: id)
        let records = attributions
        let entries: [ChatEntry]
        if let path {
            entries = await Task.detached { ConversationLog.entries(of: URL(fileURLWithPath: path)) }.value
        } else {
            entries = []
        }
        let stamped = KodAttributions.stamp(entries, sessionID: id, records: records)
        let page = KodMessagePage(sessionID: id, messages: stamped.suffix(limit).map { KodMessage(entry: $0) })
        return .json(200, page)
    }

    private func send(_ id: UUID, body: Data) -> KodHTTPResponse {
        guard let model, let session = model.deck.session(id) else { return .error(404, "not_found") }
        guard session.kind == .claude else {
            rememberFailure(session, String(localized: "That session is not a Claude session."))
            return .error(404, "not_claude")
        }
        guard let text = (try? JSONDecoder().decode(KodTextBody.self, from: body))?.text else {
            return .error(400, "invalid_json")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .error(400, "empty_message") }
        if model.terminals.isRunning(id), model.status(of: id).display.isBlocked {
            rememberFailure(session, String(localized: "The session is waiting for permission or a question, so the message was not typed."))
            return .error(409, "blocked")
        }
        remember(trimmed, session: session)
        if model.terminals.isRunning(id) {
            model.typePrompt(trimmed, into: id)
        } else {
            model.sendPrompt(trimmed, to: id, select: false)
        }
        return .json(200, KodAccepted(ok: true, sessionID: id))
    }

    private func start(_ projectID: UUID, body: Data) -> KodHTTPResponse {
        guard let model, model.deck.project(projectID) != nil else { return .error(404, "not_found") }
        let prompt = body.isEmpty ? nil : (try? JSONDecoder().decode(KodPromptBody.self, from: body))?.prompt
        if !body.isEmpty, (try? JSONDecoder().decode(KodPromptBody.self, from: body)) == nil {
            return .error(400, "invalid_json")
        }
        guard let id = model.newSession(in: projectID), let session = model.deck.session(id) else {
            return .error(404, "not_found")
        }
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            record(KodActivityEntry(
                direction: .inbound,
                title: "\(ChatEntry.kodCheckerSource) · \(session.name)",
                detail: String(localized: "Started a session"),
                ok: true,
                sessionID: id
            ))
        } else {
            remember(trimmed, session: session)
            let launched = Date()
            Task {
                for _ in 0..<120 {
                    if let hook = self.model?.hookStatuses[id], hook.updatedAt >= launched { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                try? await Task.sleep(for: .seconds(1))
                guard let model = self.model, model.terminals.isRunning(id), !model.status(of: id).display.isBlocked else {
                    self.record(KodActivityEntry(
                        direction: .inbound,
                        title: "\(ChatEntry.kodCheckerSource) · \(session.name)",
                        detail: String(localized: "The session wasn't ready for the message."),
                        ok: false,
                        sessionID: id
                    ))
                    return
                }
                model.terminals.type(trimmed + "\r", into: id)
            }
        }
        return .json(200, KodAccepted(ok: true, sessionID: id))
    }

    // MARK: Log

    private func remember(_ text: String, session: DeckSession) {
        let stored = String(text.prefix(100_000))
        attributions.append(KodAttribution(sessionID: session.id, text: stored, at: Date()))
        if attributions.count > KodBridgeDisk.maxAttributions {
            attributions.removeFirst(attributions.count - KodBridgeDisk.maxAttributions)
        }
        record(KodActivityEntry(
            direction: .inbound,
            title: "\(ChatEntry.kodCheckerSource) · \(session.name)",
            detail: preview(text),
            ok: true,
            sessionID: session.id
        ))
    }

    private func rememberFailure(_ session: DeckSession, _ detail: String) {
        record(KodActivityEntry(
            direction: .inbound,
            title: "\(ChatEntry.kodCheckerSource) · \(session.name)",
            detail: detail,
            ok: false,
            sessionID: session.id
        ))
    }

    private func recordOutbound(_ event: KodBridgeEvent, result: KodWebhookResult, sessionName: String) {
        var parts = [event.finished ? String(localized: "Finished") : String(localized: "Waiting for input")]
        if !sessionName.isEmpty { parts.append(sessionName) }
        if let detail = event.detail, !detail.isEmpty { parts.append(detail) }
        if let reply = event.lastAssistantReply { parts.append(reply) }
        parts.append(result.message)
        let title = event.projectName.isEmpty ? event.event : "\(event.event) · \(event.projectName)"
        record(KodActivityEntry(
            direction: .outbound,
            title: title,
            detail: preview(parts.joined(separator: "\n"), limit: 1_000),
            ok: result.delivered,
            sessionID: UUID(uuidString: event.sessionID)
        ))
    }

    private func record(_ entry: KodActivityEntry) {
        log.append(entry)
        if log.count > KodBridgeDisk.maxLog { log.removeFirst(log.count - KodBridgeDisk.maxLog) }
        save()
    }

    private func preview(_ text: String, limit: Int = 500) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    private func ensureToken() {
        if let existing = KodBridgeKeychain.token(), !existing.isEmpty {
            token = existing
            return
        }
        let created = KodBridgeKeychain.makeToken()
        KodBridgeKeychain.setToken(created)
        token = created
    }

    private func applyListen(_ state: KodBridgeServer.State) {
        switch state {
        case .listening(let port):
            pendingPort = nil
            listening = true
            boundPort = port
            listenError = nil
        case .failed(let message):
            pendingPort = nil
            listening = false
            listenError = String(localized: "Couldn't start the local API: \(message)")
        }
    }

    private static func statusName(_ display: DisplayState) -> String {
        switch display {
        case .notStarted: "not_started"
        case .starting: "starting"
        case .shell: "shell"
        case .activity(.running): "running"
        case .activity(.needsPermission): "needs_permission"
        case .activity(.needsAnswer): "needs_answer"
        case .activity(.idle): "idle"
        case .activity(.ended): "ended"
        }
    }

    private func load() {
        guard let storageURL, let data = try? Data(contentsOf: storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let disk = try? decoder.decode(KodBridgeDisk.self, from: data) else { return }
        let trimmed = disk.trimmed()
        attributions = trimmed.attributions
        log = trimmed.log
    }

    private func save() {
        guard let storageURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(KodBridgeDisk(attributions: attributions, log: log).trimmed()) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }
}
