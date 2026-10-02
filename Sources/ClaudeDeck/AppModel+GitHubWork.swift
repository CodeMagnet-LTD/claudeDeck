import AppKit
import ClaudeDeckCore
import Foundation

/// Inbox "Start Work" and CI "Fix with Claude": sessions that work on a GitHub item.
extension AppModel {
    /// Types `text` into a Claude session, starting (resuming) it first and waiting for its prompt.
    func sendPrompt(_ text: String, to id: UUID, select: Bool = true) {
        guard let session = deck.session(id), session.kind == .claude else { return }
        let wasRunning = terminals.isRunning(id)
        if select { selectedSessionID = id }
        Task { @MainActor in
            if !wasRunning {
                let launchedAt = Date()
                launch(id, resume: true)
                // Ready once a hook reports idle after the launch (or the status looks idle).
                let deadline = ContinuousClock.now + .seconds(60)
                while ContinuousClock.now < deadline, terminals.isRunning(id) {
                    if let hook = hookStatuses[id], hook.updatedAt > launchedAt, hook.state == .idle { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard terminals.isRunning(id) else { return }
            terminals.type(text.trimmingCharacters(in: .whitespacesAndNewlines) + "\r", into: id)
        }
    }

    /// A new Claude session in the project (optionally in a fresh worktree), linked to `item`.
    /// Not launched: `sendPrompt` starts it.
    func createLinkedSession(in projectID: UUID, item: LinkedWorkItem, newWorktree: Bool) -> UUID? {
        guard let project = deck.project(projectID) else { return nil }
        let base = "\(project.name) · \(item.shortLabel)"
        let taken = Set(deck.sessions(in: projectID).map(\.name))
        var name = base
        var n = 2
        while taken.contains(name) { name = "\(base) \(n)"; n += 1 }
        var created: DeckSession?
        if newWorktree, isGitRepository(project) {
            let slug = "\(item.kind == .pr ? "pr" : "issue")-\(item.number)"
            let dir = URL(fileURLWithPath: project.path).appending(path: ".claude/worktrees/\(slug)").path
            let clash = deck.sessions(in: projectID).contains { $0.worktreeName == slug } || FileManager.default.fileExists(atPath: dir)
            let worktree = DeckData.isValidWorktreeName(slug) && !clash ? slug : defaultWorktreeName(for: project)
            mutate { deck in
                created = deck.addWorktreeSession(to: projectID, worktreeName: worktree)
                if let id = created?.id { deck.updateSession(id) { $0.name = name } }
            }
        } else {
            mutate { created = $0.addSession(to: projectID, name: name) }
        }
        guard let id = created?.id else { return nil }
        setLinkedWorkItem(item, for: id)
        return id
    }

    /// Inbox "Start Work": a linked session told to work on the item.
    func startWork(on item: GitHubListItem, projectID: UUID, newWorktree: Bool) {
        guard let id = createLinkedSession(in: projectID, item: item.workItem, newWorktree: newWorktree) else { NSSound.beep(); return }
        tabs.selectSessions()
        sendPrompt(item.workPrompt, to: id)
    }

    /// "Fix with Claude" for a failed check: fetches its failing log and sends it with an instruction
    /// to `sessionID` (the PR's linked session), or to a new session in `projectID` linked to the PR.
    func repairCheck(_ check: GitHubFailedCheck, pullRequest: LinkedWorkItem, branch: String?, sessionID: UUID?, projectID: UUID?) {
        let key = CIRepair.key(repo: pullRequest.repo, number: pullRequest.number, check: check)
        let monitor = GitHubMonitor.shared
        guard check.canRepair, !monitor.repairing.contains(key) else { return }
        monitor.repairing.insert(key)
        Task { @MainActor in
            defer { monitor.repairing.remove(key) }
            let repo = pullRequest.repo
            let log = await Task.detached { GitHub.failedLog(repo: repo, check: check) }.value
            let text: String
            switch log {
            case .success(let tail): text = tail
            case .failure(let error):
                // A log that can't be fetched (expired, still running) still gets Claude started.
                text = "(could not fetch the log: \(error.message))"
            }
            var target = sessionID.flatMap { deck.session($0) }?.id
            if target == nil, let projectID {
                target = createLinkedSession(in: projectID, item: pullRequest, newWorktree: false)
            }
            guard let target else { NSSound.beep(); return }
            mutate { $0.recordCIRepair(CIRepairRequest(key: key, sessionID: target)) }
            tabs.selectSessions()
            sendPrompt(CIRepair.prompt(repo: repo, number: pullRequest.number, branch: branch, check: check, log: text), to: target)
        }
    }

    /// The project whose folder is the clone of `repo`, preferring `preferred`.
    func project(forRepo repo: String, preferred: UUID? = nil) -> UUID? {
        let matches = deck.projects.filter { GitHubRepoCache.shared.repo(forPath: $0.path)?.lowercased() == repo.lowercased() }.map(\.id)
        if let preferred, matches.contains(preferred) { return preferred }
        return matches.first
    }
}

/// "owner/name" per project folder (`gh repo view`), cached for the app's lifetime.
@MainActor
final class GitHubRepoCache {
    static let shared = GitHubRepoCache()
    private var repos: [String: String] = [:]
    private var failures: [String: Date] = [:]

    func repo(forPath path: String) -> String? { repos[path] }

    /// Looks it up with gh (off the main thread); a failure is retried after 10 minutes.
    func resolve(_ path: String) async -> Result<String, GitHubError> {
        if let repo = repos[path] { return .success(repo) }
        if let failed = failures[path], Date().timeIntervalSince(failed) < 600 {
            return .failure(GitHubError(String(localized: "This project's folder isn't a GitHub repository.")))
        }
        let result = await Task.detached { GitHub.repository(in: URL(fileURLWithPath: path)) }.value
        switch result {
        case .success(let repo): repos[path] = repo; failures[path] = nil
        case .failure: failures[path] = Date()
        }
        return result
    }
}
