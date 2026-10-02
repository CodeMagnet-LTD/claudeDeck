import AppKit
import ClaudeDeckCore
import Foundation

/// Linking a GitHub issue or pull request to a session (see GitHubMonitor, GitHubLinkViews).
extension AppModel {
    func setLinkedWorkItem(_ item: LinkedWorkItem?, for id: UUID) {
        mutate { $0.updateSession(id) { $0.linkedWorkItem = item } }
        GitHubMonitor.shared.linkChanged(id)
    }

    /// Asks for an issue/PR URL (or `owner/repo#N`) until it parses or the user cancels.
    func promptLinkWorkItem(_ id: UUID) {
        guard let session = deck.session(id) else { return }
        var text = session.linkedWorkItem?.url ?? ""
        while true {
            guard let answer = TextPrompt.ask(
                title: String(localized: "Link GitHub Issue or Pull Request"),
                placeholder: "https://github.com/owner/repo/pull/12",
                initial: text
            ) else { return }
            text = answer
            guard var item = LinkedWorkItem.parse(answer) else {
                GitHubAlert.show(String(localized: "Not a GitHub issue or pull request"),
                                 detail: String(localized: "Paste a link like https://github.com/owner/repo/pull/12 or https://github.com/owner/repo/issues/34, or write owner/repo#12."))
                continue
            }
            if let old = session.linkedWorkItem, old.isSameItem(as: item) { return }
            guard LinkedWorkItem.isShortForm(answer) else {
                setLinkedWorkItem(item, for: id)
                return
            }
            // owner/repo#N doesn't say whether it's a PR; gh knows.
            Task { @MainActor in
                let monitor = GitHubMonitor.shared
                if monitor.availability != .ready { await monitor.checkAvailability() }
                if monitor.availability == .ready {
                    let unresolved = item
                    item = await Task.detached { GitHub.resolveKind(unresolved) }.value
                }
                setLinkedWorkItem(item, for: id)
            }
            return
        }
    }

    /// Directory whose checked-out branch belongs to the session (its worktree, else the project).
    func repositoryDirectory(for session: DeckSession) -> URL? {
        if let wd = session.workingDirectory, FileManager.default.fileExists(atPath: wd) { return URL(fileURLWithPath: wd) }
        guard let project = deck.project(session.projectID), isGitRepository(project) else { return nil }
        return URL(fileURLWithPath: project.path)
    }

    /// Links the pull request of the branch checked out in the session's directory.
    func linkPullRequestForCurrentBranch(_ id: UUID) {
        guard let session = deck.session(id), let dir = repositoryDirectory(for: session) else { return }
        Task { @MainActor in
            let monitor = GitHubMonitor.shared
            await monitor.checkAvailability()
            guard monitor.availability == .ready else {
                GitHubAlert.show(String(localized: "GitHub CLI not available"), detail: GitHubAlert.setupHint(monitor.availability))
                return
            }
            let lookup: (branch: String?, result: Result<LinkedWorkItem?, GitHubError>?) = await Task.detached {
                guard let branch = Git.currentBranch(in: dir) else { return (nil, nil) }
                return (branch, GitHub.pullRequest(forBranch: branch, in: dir))
            }.value
            guard let branch = lookup.branch else {
                GitHubAlert.show(String(localized: "No branch checked out"), detail: dir.path)
                return
            }
            switch lookup.result {
            case .success(let item?):
                setLinkedWorkItem(item, for: id)
            case .failure(let error):
                GitHubAlert.show(String(localized: "Couldn't look up the pull request"), detail: error.message)
            default:
                GitHubAlert.show(String(localized: "No pull request for branch \(branch)"),
                                 detail: String(localized: "Push the branch and open a pull request first."))
            }
        }
    }

    /// Types a short prompt into the session; the agent fetches the details with gh itself.
    func sendWorkItemToClaude(_ id: UUID) {
        guard let session = deck.session(id), session.kind == .claude, let item = session.linkedWorkItem else { return }
        let title = GitHubMonitor.shared.details[id]?.title
        sendPrompt(GitHubListItem.workPrompt(kind: item.kind, number: item.number, title: title, url: item.url), to: id)
    }
}

enum GitHubAlert {
    @MainActor
    static func show(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "OK"))
        _ = alert.runAsSheet()
    }

    static func setupHint(_ availability: GitHubAvailability?) -> String {
        availability == .missing
            ? String(localized: "Install the GitHub CLI (brew install gh), then run gh auth login in a terminal.")
            : String(localized: "Run gh auth login in a terminal to sign in to GitHub.")
    }
}
