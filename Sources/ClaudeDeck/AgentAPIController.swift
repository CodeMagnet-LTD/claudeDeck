import ClaudeDeckCore
import Foundation
import Observation

/// The agents' local API: 127.0.0.1 only, a bearer token from the keychain. A bot on this Mac
/// (a Grok Bot routine) reads sessions, answers requests with notes, and — if its profile allows —
/// types into Claude. Contract: docs/agents.md.
@MainActor
@Observable
final class AgentAPIController {
    enum State: Equatable { case off, listening(UInt16), failed(String) }
    private(set) var state = State.off
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let server = AgentAPIServer()
    @ObservationIgnored private var runningPort: Int?

    /// The remote listener's port is never shared.
    static let reservedPorts: Set<Int> = [Int(RemotePairing.defaultPort)]

    var token: String? { AgentKeychain.read("api-token") }

    func regenerateToken() { AgentKeychain.write(AgentBearer.newToken(), "api-token") }

    func start(model: AppModel) {
        self.model = model
        server.onState = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .listening(let port): self?.state = .listening(port)
                case .failed(let reason): self?.state = .failed(reason)
                }
            }
        }
        refresh()
    }

    /// Follows Settings: on/off and the port.
    func refresh() {
        guard let model else { return }
        let settings = model.deck.settings
        guard settings.agentAPIEnabled else {
            server.stop()
            runningPort = nil
            state = .off
            return
        }
        if token == nil { regenerateToken() }
        let port = settings.agentAPIPort
        guard (1024...65535).contains(port), !Self.reservedPorts.contains(port) else {
            server.stop()
            runningPort = nil
            state = .failed(String(localized: "Pick another port (1024–65535, not the remote one)."))
            return
        }
        guard runningPort != port else { return }
        runningPort = port
        server.start(port: UInt16(port)) { [weak self] request in
            await self?.handle(request) ?? .error(503, "unavailable")
        }
    }

    // MARK: Requests

    func handle(_ request: AgentHTTPRequest) async -> AgentHTTPResponse {
        let route: AgentRoute
        switch AgentRoute.resolve(request, token: token) {
        case .failure(let refusal): return refusal.response
        case .success(let resolved): route = resolved
        }
        guard let model else { return .error(503, "unavailable") }
        switch route {
        case .listAgents, .registerAgent, .agentInfo, .deleteAgent:
            return model.handleAgentRegistration(route, body: request.body)
        case .projects:
            return .json(200, projects(model))
        case .messages(let id):
            return await messages(id, limit: AgentRoute.limit(request.query), model: model)
        case .notes:
            guard let body = try? AgentJSON.decode(AgentNoteBody.self, from: request.body),
                  !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !body.agent.isEmpty else { return .error(400, "bad_request") }
            guard model.deck.session(body.sessionId) != nil else { return .error(404, "unknown_session") }
            let id = model.receiveNote(requestID: body.requestId, sessionID: body.sessionId, agent: body.agent, text: body.text)
            model.logAgent(body.agent, inbound: true, "note · \(model.deck.session(body.sessionId)?.name ?? "")")
            return .json(200, ["note_id": id.uuidString])
        case .prompt(let id):
            guard let body = try? AgentJSON.decode(AgentPromptBody.self, from: request.body),
                  !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !body.agent.isEmpty else { return .error(400, "bad_request") }
            guard let session = model.deck.session(id), session.kind == .claude else { return .error(404, "unknown_session") }
            // Not an allowed agent: the text waits for the user as a note.
            guard model.agent(named: body.agent)?.canSendDirectly == true else {
                let note = model.receiveNote(requestID: nil, sessionID: id, agent: body.agent, text: body.text)
                model.logAgent(body.agent, inbound: true, "prompt → note (not allowed to send) · \(session.name)")
                return .json(200, ["delivered": "note", "note_id": note.uuidString])
            }
            guard model.terminals.isRunning(id) else { return .error(409, "not_running") }
            guard !model.status(of: id).display.isBlocked else { return .error(409, "blocked") }
            model.rememberAgentPrompt(body.text, in: id)
            if let failure = model.typePrompt(body.text, into: id) {
                model.logAgent(body.agent, inbound: true, failure, ok: false)
                return .error(409, "blocked")
            }
            model.logAgent(body.agent, inbound: true, "prompt → Claude · \(session.name)")
            return .json(200, ["delivered": "claude"])
        case .newSession(let projectID):
            guard let body = try? AgentJSON.decode(AgentNewSessionBody.self, from: request.body), !body.agent.isEmpty else { return .error(400, "bad_request") }
            guard model.deck.project(projectID) != nil else { return .error(404, "unknown_project") }
            guard let id = model.startClaudeSession(in: projectID, name: body.name, prompt: body.prompt) else { return .error(409, "not_started") }
            model.logAgent(body.agent, inbound: true, "new session · \(model.deck.project(projectID)?.name ?? "")")
            return .json(200, ["session_id": id.uuidString])
        }
    }

    private func projects(_ model: AppModel) -> [AgentProjectInfo] {
        model.deck.projects.map { project in
            AgentProjectInfo(id: project.id, name: project.name, path: project.path, sessions: model.deck.sessions(in: project.id).map { session in
                let status = model.status(of: session.id)
                return AgentSessionInfo(id: session.id, name: session.name, kind: session.kind == .shell ? "terminal" : "claude",
                                        state: AppModel.stateName(status.display), detail: status.detail, updatedAt: status.updatedAt)
            })
        }
    }

    private func messages(_ id: UUID, limit: Int, model: AppModel) async -> AgentHTTPResponse {
        guard model.deck.session(id) != nil else { return .error(404, "unknown_session") }
        guard let path = model.hookStatuses[id]?.transcriptPath ?? model.deck.transcriptPath(for: id) else { return .json(200, [AgentMessageInfo]()) }
        let entries = await Task.detached { ConversationLog.entries(of: URL(fileURLWithPath: path)) }.value
        return .json(200, entries.suffix(limit).map(AgentMessageInfo.init))
    }
}
