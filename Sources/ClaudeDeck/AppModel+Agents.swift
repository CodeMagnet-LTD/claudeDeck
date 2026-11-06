import ClaudeDeckCore
import Foundation

/// A note that left the open list: what became of it.
struct AgentReviewRecord: Codable, Identifiable, Equatable {
    var id: UUID { note.id }
    var note: AgentNote
    var outcome: String  // "sent", "queued", "dismissed"
    var date: Date
}

enum AgentSheet: Identifiable, Equatable {
    case preview(session: UUID, agents: [UUID], text: String)
    case history(session: UUID)
    var id: String {
        switch self {
        case .preview(let session, _, _): "preview-\(session)"
        case .history(let session): "history-\(session)"
        }
    }
}

/// One line of the agents' activity log: what went out to an agent, what came in from one.
struct AgentActivity: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let inbound: Bool
    let agent: String
    let summary: String
    let ok: Bool
}

/// Asking agents (Grok bots, webhooks) about a Claude session: the request goes out with the
/// session's context, the answer comes back as a note beside the session, and only the user (or
/// an agent allowed to) sends it on to Claude. Automatic requests follow the session's turns.
extension AppModel {
    static let maxNotesPerSession = 20
    static let maxActivity = 300

    var agents: [AgentProfile] { deck.settings.agents }

    func agent(named name: String) -> AgentProfile? {
        agents.first { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }

    func logAgent(_ agent: String, inbound: Bool, _ summary: String, ok: Bool = true) {
        agentActivity.append(AgentActivity(inbound: inbound, agent: agent, summary: summary, ok: ok))
        if agentActivity.count > Self.maxActivity { agentActivity.removeFirst(agentActivity.count - Self.maxActivity) }
    }

    /// Asks each agent (several at once is fine); `request` is what to look at, may be empty.
    func askAgents(_ ids: [UUID], about sessionID: UUID, request: String, event: AgentPayload.Event = .manual) {
        let chosen = agents.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, deck.session(sessionID) != nil else { return }
        if event == .manual { agentGate.reset(sessionID) }
        var notes: [(AgentProfile, AgentNote)] = []
        for agent in chosen {
            let note = AgentNote(agentID: agent.id, agentName: agent.name, request: event == .manual ? request : Self.label(event))
            notes.append((agent, note))
            agentNotes[sessionID, default: []].append(note)
        }
        trimNotes(sessionID)
        let snapshot = contextSnapshot(sessionID)
        let callback = agentAPIBase
        Task { @MainActor [weak self] in
            let context = await snapshot.gather(request: request)
            for (agent, note) in notes {
                let payload = AgentPayload(
                    requestId: note.id.uuidString, event: event, agent: agent, async: agent.usesWebhook && agent.async,
                    project: snapshot.project, sessionId: sessionID, sessionName: snapshot.sessionName,
                    sessionState: snapshot.state, context: context, transcriptPath: snapshot.transcript,
                    callback: callback.map { AgentPayload.Callback(notesUrl: $0 + "/v1/notes", requestId: note.id.uuidString) }
                )
                self?.logAgent(agent.name, inbound: false, "\(event.rawValue) · \(snapshot.sessionName)\(request.isEmpty ? "" : " · \(request)")")
                Task { @MainActor [weak self] in
                    do {
                        if let reply = try await AgentRunner.ask(agent, payload: payload) {
                            self?.updateNote(note.id, in: sessionID) { $0.reply = reply }
                            self?.logAgent(agent.name, inbound: true, "answer · \(snapshot.sessionName) · \(reply.count) chars")
                        } else {
                            self?.logAgent(agent.name, inbound: true, "accepted (answer comes later) · \(snapshot.sessionName)")
                        }
                    } catch {
                        self?.updateNote(note.id, in: sessionID) { $0.error = error.localizedDescription }
                        self?.logAgent(agent.name, inbound: true, error.localizedDescription, ok: false)
                    }
                }
            }
        }
    }

    private static func label(_ event: AgentPayload.Event) -> String {
        switch event {
        case .idle: String(localized: "Turn finished")
        case .permission: String(localized: "Waiting for permission")
        case .question: String(localized: "Asking a question")
        case .manual, .test: ""
        }
    }

    /// What's needed to build the context, read now (on the main actor); `gather` does the slow part.
    struct ContextSnapshot: Sendable {
        var project: AgentPayload.Project
        var sessionName: String
        var state: String
        var transcript: String?
        var folder: String?

        func gather(request: String) async -> AgentContext {
            let (project, sessionName, transcript, folder) = (project, sessionName, transcript, folder)
            return await Task.detached {
                let entries = transcript.map { ConversationLog.entries(of: URL(fileURLWithPath: $0)) } ?? []
                let exchange = AgentContext.lastExchange(in: entries)
                let repo = folder.map { URL(fileURLWithPath: $0) }
                return AgentContext(project: project.name, session: sessionName, lastPrompt: exchange.prompt, lastReply: exchange.reply,
                                    diff: repo.map { Git.uncommittedDiff(in: $0) }, untracked: repo.map { Git.untrackedFiles(in: $0) } ?? [],
                                    request: request)
            }.value
        }
    }

    func contextSnapshot(_ sessionID: UUID) -> ContextSnapshot {
        let session = deck.session(sessionID)
        let project = session.flatMap { deck.project($0.projectID) }
        return ContextSnapshot(
            project: AgentPayload.Project(id: project?.id, name: project?.name ?? "", path: project?.path ?? ""),
            sessionName: session?.name ?? "",
            state: Self.stateName(status(of: sessionID).display),
            transcript: hookStatuses[sessionID]?.transcriptPath ?? deck.transcriptPath(for: sessionID),
            folder: session?.workingDirectory ?? project?.path
        )
    }

    static func stateName(_ display: DisplayState) -> String {
        switch display {
        case .notStarted: "stopped"
        case .starting: "starting"
        case .shell: "shell"
        case .activity(let activity):
            switch activity {
            case .running: "running"
            case .idle: "idle"
            case .needsPermission: "needsPermission"
            case .needsAnswer: "needsAnswer"
            default: "stopped"
            }
        }
    }

    /// The local API's base, for the payload's callback (nil while the API is off).
    var agentAPIBase: String? {
        deck.settings.agentAPIEnabled ? "http://127.0.0.1:\(deck.settings.agentAPIPort)" : nil
    }

    // MARK: Automatic requests

    /// On every status change: agents set to follow sessions get the turns that just ended, the
    /// permission prompts and the questions — once each, and at most a few rounds in a row.
    func triggerAgents() {
        guard agents.contains(where: { $0.autoTrigger && !$0.autoProjects.isEmpty }) else { return }
        for session in deck.sessions where session.kind == .claude && terminals.isRunning(session.id) {
            // Only the agents following this session's project.
            let following = agents.filter { $0.follows(project: session.projectID) }
            guard !following.isEmpty else { continue }
            let id = session.id
            let status = status(of: id)
            let hook = hookStatuses[id]
            // A message the user submitted (not one an agent typed) starts the count again.
            if let hook, hook.event == "UserPromptSubmit", hook.updatedAt > (agentPromptSeen[id] ?? .distantPast) {
                agentPromptSeen[id] = hook.updatedAt
                let typed = Self.promptKey(hook.detail ?? "")
                if !(agentTypedPrompts[id] ?? []).contains(where: { typed.hasPrefix($0) || $0.hasPrefix(typed) }) { agentGate.reset(id) }
            }
            let turn = String(status.updatedAt?.timeIntervalSince1970 ?? 0)
            switch agentGate.decide(session: id, state: Self.stateName(status.display), event: hook?.event, turn: turn, byUser: false) {
            case .send(let event):
                askAgents(following.map(\.id), about: id, request: "", event: event)
            case .paused:
                logAgent(following.map(\.name).joined(separator: ", "), inbound: false,
                         "paused after \(AgentTriggerGate.maxRounds) automatic rounds · \(session.name) (ask by hand to go on)", ok: false)
            case .skip:
                break
            }
        }
    }

    static func promptKey(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
    }

    /// Text an agent typed into a session (through the API), so its UserPromptSubmit isn't taken
    /// for the user's.
    func rememberAgentPrompt(_ text: String, in id: UUID) {
        var list = agentTypedPrompts[id] ?? []
        list.append(Self.promptKey(text))
        agentTypedPrompts[id] = Array(list.suffix(10))
    }

    // MARK: Notes

    /// Returns why the answer didn't go to Claude; the note then stays, showing it.
    @discardableResult
    func agentNoteAction(_ noteID: UUID, in sessionID: UUID, action: AgentNoteAction) -> String? {
        guard let note = agentNotes[sessionID]?.first(where: { $0.id == noteID }) else { return nil }
        var failure: String?
        switch action {
        case .dismiss:
            break
        case .sendToClaude:
            failure = note.reply == nil ? String(localized: "No answer to send yet.") : typePrompt(AgentHandoff.prompt(from: note), into: sessionID)
        case .queueForClaude:
            if note.reply == nil {
                failure = String(localized: "No answer to send yet.")
            } else if deck.session(sessionID)?.kind != .claude || !terminals.isRunning(sessionID) {
                failure = String(localized: "This session isn't running.")
            } else {
                enqueue(sessionID, text: AgentHandoff.prompt(from: note))
            }
        }
        if let failure {
            updateNote(noteID, in: sessionID) { $0.actionError = failure }
        } else {
            // The user chose to send it: their turn, for the automatic count.
            if action != .dismiss { agentGate.reset(sessionID) }
            agentNotes[sessionID]?.removeAll { $0.id == noteID }
            let outcome = switch action {
            case .dismiss: "dismissed"
            case .sendToClaude: "sent"
            case .queueForClaude: "queued"
            }
            agentReviewHistory[sessionID, default: []].append(AgentReviewRecord(note: note, outcome: outcome, date: Date()))
            if let count = agentReviewHistory[sessionID]?.count, count > 50 { agentReviewHistory[sessionID]?.removeFirst(count - 50) }
            notesChanged(sessionID)
        }
        return failure
    }

    /// A note from the local API: the answer to an earlier request (same id), or a new one.
    @discardableResult
    func receiveNote(requestID: String?, sessionID: UUID, agent: String, text: String) -> UUID {
        if let requestID, let id = UUID(uuidString: requestID), agentNotes[sessionID]?.contains(where: { $0.id == id }) == true {
            updateNote(id, in: sessionID) { $0.reply = text; $0.error = nil }
            return id
        }
        let note = AgentNote(agentID: self.agent(named: agent)?.id ?? UUID(), agentName: agent, request: "", reply: text)
        agentNotes[sessionID, default: []].append(note)
        trimNotes(sessionID)
        return note.id
    }

    func notesChanged(_ sessionID: UUID) {
        agentNotesRevision[sessionID, default: 0] += 1
        onAgentNotesChanged?()
        saveAgentNotesSoon()
    }

    // MARK: Kept on disk (Application Support/agent-notes.json)

    private struct NotesFile: Codable {
        var notes: [UUID: [AgentNote]]
        var history: [UUID: [AgentReviewRecord]]
    }

    private var agentNotesURL: URL {
        DeckDataStore.default().url.deletingLastPathComponent().appending(path: "agent-notes.json")
    }

    func loadAgentNotes() {
        guard let data = try? Data(contentsOf: agentNotesURL) else { return }
        do {
            let file = try JSONDecoder().decode(NotesFile.self, from: data)
            let known = Set(deck.sessions.map(\.id))
            agentNotes = file.notes.filter { known.contains($0.key) }
            agentReviewHistory = file.history.filter { known.contains($0.key) }
        } catch {
            logAgent("ClaudeDeck", inbound: false, "couldn't read agent-notes.json: \(error.localizedDescription)", ok: false)
        }
    }

    private func saveAgentNotesSoon() {
        agentNotesSaveTask?.cancel()
        agentNotesSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(NotesFile(notes: self.agentNotes, history: self.agentReviewHistory))
                try data.write(to: self.agentNotesURL, options: .atomic)
            } catch {
                self.logAgent("ClaudeDeck", inbound: false, "couldn't save agent notes: \(error.localizedDescription)", ok: false)
            }
        }
    }

    /// What would go to the agents (masked, cut), shown before sending.
    func previewAgentRequest(_ ids: [UUID], about sessionID: UUID, request: String) {
        let snapshot = contextSnapshot(sessionID)
        Task { @MainActor [weak self] in
            let context = await snapshot.gather(request: request)
            self?.agentSheet = .preview(session: sessionID, agents: ids, text: context.message)
        }
    }

    private func updateNote(_ id: UUID, in sessionID: UUID, _ change: (inout AgentNote) -> Void) {
        guard let index = agentNotes[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        change(&agentNotes[sessionID]![index])
        notesChanged(sessionID)
    }

    private func trimNotes(_ sessionID: UUID) {
        if let count = agentNotes[sessionID]?.count, count > Self.maxNotesPerSession {
            agentNotes[sessionID]?.removeFirst(count - Self.maxNotesPerSession)
        }
        notesChanged(sessionID)
    }

    // MARK: Sessions for the API

    /// A new Claude session; `prompt` goes in once Claude is up (as from the phone).
    func startClaudeSession(in projectID: UUID, name: String?, prompt: String?) -> UUID? {
        guard deck.project(projectID) != nil else { return nil }
        let title = name ?? prompt?.split(separator: "\n").first.map(String.init)
        guard let id = newSession(in: projectID, title: title.flatMap { $0.isEmpty ? nil : $0 }) else { return nil }
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let launched = Date()
            Task { @MainActor [weak self] in
                for _ in 0..<120 {
                    if let hook = self?.hookStatuses[id], hook.updatedAt >= launched { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                try? await Task.sleep(for: .seconds(1))
                self?.rememberAgentPrompt(prompt, in: id)
                self?.typePrompt(prompt, into: id)
            }
        }
        return id
    }
}
