import ClaudeDeckCore
import Foundation

/// Asking agents (Grok bots, webhooks) about a Claude session: the request goes out with the
/// session's context, the answer comes back as a note beside the session, and only the user sends
/// it on to Claude.
extension AppModel {
    static let maxNotesPerSession = 20

    var agents: [AgentProfile] { deck.settings.agents }

    /// Asks each agent (several at once is fine); `request` is what to look at, may be empty.
    func askAgents(_ ids: [UUID], about sessionID: UUID, request: String) {
        let chosen = agents.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, let session = deck.session(sessionID) else { return }
        let project = deck.project(session.projectID)
        let transcript = hookStatuses[sessionID]?.transcriptPath ?? deck.transcriptPath(for: sessionID)
        let folder = session.workingDirectory ?? project?.path
        var notes: [(AgentProfile, AgentNote)] = []
        for agent in chosen {
            let note = AgentNote(agentID: agent.id, agentName: agent.name, request: request)
            notes.append((agent, note))
            agentNotes[sessionID, default: []].append(note)
        }
        trimNotes(sessionID)
        let projectName = project?.name ?? ""
        let sessionName = session.name
        Task { @MainActor [weak self] in
            // The context once for all of them, off the main thread (transcript and git).
            let context = await Task.detached { () -> AgentContext in
                let entries = transcript.map { ConversationLog.entries(of: URL(fileURLWithPath: $0)) } ?? []
                let diff = folder.map { Git.uncommittedDiff(in: URL(fileURLWithPath: $0)) }
                return AgentContext(
                    project: projectName, session: sessionName,
                    lastPrompt: entries.last { $0.kind == .user }?.text,
                    lastReply: entries.last { $0.kind == .assistant }?.text,
                    diff: diff, request: request
                )
            }.value
            for (agent, note) in notes {
                Task { @MainActor [weak self] in
                    do {
                        let reply = try await AgentRunner.ask(agent, message: context.message)
                        self?.updateNote(note.id, in: sessionID) { $0.reply = reply }
                    } catch {
                        self?.updateNote(note.id, in: sessionID) { $0.error = error.localizedDescription }
                    }
                }
            }
        }
    }

    func agentNoteAction(_ noteID: UUID, in sessionID: UUID, action: AgentNoteAction) {
        guard let note = agentNotes[sessionID]?.first(where: { $0.id == noteID }) else { return }
        switch action {
        case .dismiss:
            agentNotes[sessionID]?.removeAll { $0.id == noteID }
        case .sendToClaude:
            guard note.reply != nil else { return }
            typePrompt(AgentHandoff.prompt(from: note), into: sessionID)
            agentNotes[sessionID]?.removeAll { $0.id == noteID }
        case .queueForClaude:
            guard note.reply != nil else { return }
            enqueue(sessionID, text: AgentHandoff.prompt(from: note))
            agentNotes[sessionID]?.removeAll { $0.id == noteID }
        }
        onAgentNotesChanged?()
    }

    private func updateNote(_ id: UUID, in sessionID: UUID, _ change: (inout AgentNote) -> Void) {
        guard let index = agentNotes[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        change(&agentNotes[sessionID]![index])
        onAgentNotesChanged?()
    }

    private func trimNotes(_ sessionID: UUID) {
        if let count = agentNotes[sessionID]?.count, count > Self.maxNotesPerSession {
            agentNotes[sessionID]?.removeFirst(count - Self.maxNotesPerSession)
        }
        onAgentNotesChanged?()
    }
}
