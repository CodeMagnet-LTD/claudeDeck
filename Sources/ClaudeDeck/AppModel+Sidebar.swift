import AppKit
import ClaudeDeckCore
import Foundation

/// A request to scroll the sidebar to a session (⌘J, a click in the waiting tray).
struct SidebarReveal: Equatable {
    var id: UUID
    var nonce: Int
}

/// Maps the app's state into the UI-free sidebar logic (ClaudeDeckCore/SidebarLayout.swift).
extension AppModel {
    func sidebarSession(_ session: DeckSession) -> SidebarSession {
        let status = status(of: session.id)
        let state: SidebarSession.State = switch status.display {
        case .notStarted, .activity(.ended): .stopped
        case .starting: .starting
        case .shell: .shell
        case .activity(.running): .running
        case .activity(.needsPermission), .activity(.needsAnswer): .blocked
        case .activity(.idle): .idle(unseen: isUnseenIdle(session.id))
        }
        return SidebarSession(id: session.id, state: state, updatedAt: status.updatedAt, isWorktree: session.worktreeName != nil)
    }

    var sidebarProjects: [SidebarProject] {
        let groupIDs = Set(deck.groups.map(\.id))
        let sessionsByProject = Dictionary(grouping: deck.sessions, by: \.projectID)
        return deck.projects.map { p in
            SidebarProject(
                id: p.id,
                pinned: p.pinned,
                groupID: p.groupID.flatMap { groupIDs.contains($0) ? $0 : nil },
                sessions: (sessionsByProject[p.id] ?? []).map(sidebarSession)
            )
        }
    }

    /// The rows the sidebar should show now. Updates the activation-order memory (not observed).
    func sidebarLayout(filter: SidebarFilter) -> SidebarLayout {
        SidebarLayout.build(groups: deck.groups.map(\.id), projects: sidebarProjects, filter: filter, order: &activationOrder)
    }

    var sidebarCounts: (waiting: Int, working: Int) {
        SidebarAttention.counts(deck.sessions.map(sidebarSession))
    }

    /// Sessions in the waiting tray, in tray order (blocked first, then finished-unseen; oldest first).
    var waitingSessions: [DeckSession] {
        SidebarAttention.order(deck.sessions.map(sidebarSession)).compactMap { deck.session($0) }
    }

    func noteUserLayoutAction() { lastUserLayoutAction = Date() }

    /// ⌘J: the next session waiting for the user, selected and scrolled to. Beeps if none.
    func selectNextWaiting() {
        let order = SidebarAttention.order(deck.sessions.map(sidebarSession))
        guard let next = SidebarAttention.next(after: deck.selectedSessionID, in: order) else {
            NSSound.beep()
            return
        }
        revealInSidebar(next)
        focusTerminal(of: next) // ⌘J: ready to type the answer
    }

    /// Selects a session, shows the Sessions tab and scrolls the sidebar to its row, opening its
    /// project and group if they are collapsed.
    func revealInSidebar(_ id: UUID) {
        guard let session = deck.session(id), let project = deck.project(session.projectID) else { return }
        noteUserLayoutAction()
        if deck.sessions(in: project.id).count > 1 || session.worktreeName != nil {
            if isActive(project) {
                if project.collapsed { mutate { $0.updateProject(project.id) { $0.collapsed = false } } }
            } else {
                idleExpandedProjects.insert(project.id)
            }
        }
        if let groupID = project.groupID, deck.groups.first(where: { $0.id == groupID })?.collapsed == true {
            mutate { $0.updateGroup(groupID) { $0.collapsed = false } }
        }
        showMainWindow()
        selectedSessionID = id
        sidebarReveal = SidebarReveal(id: id, nonce: (sidebarReveal?.nonce ?? 0) + 1)
    }
}
