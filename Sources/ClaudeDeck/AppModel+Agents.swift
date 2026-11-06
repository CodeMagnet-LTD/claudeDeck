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
                let exchange = AgentContext.lastExchange(in: entries)
                let repo = folder.map { URL(fileURLWithPath: $0) }
                return AgentContext(
                    project: projectName, session: sessionName,
                    lastPrompt: exchange.prompt, lastReply: exchange.reply,
                    diff: repo.map { Git.uncommittedDiff(in: $0) },
                    untracked: repo.map { Git.untrackedFiles(in: $0) } ?? [],
                    request: request
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
            agentNotes[sessionID]?.removeAll { $0.id == noteID }
            notesChanged(sessionID)
        }
        return failure
    }

    func notesChanged(_ sessionID: UUID) {
        agentNotesRevision[sessionID, default: 0] += 1
        onAgentNotesChanged?()
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
}
