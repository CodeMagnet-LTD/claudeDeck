import AppKit
import ClaudeDeckCore
import Observation
import SwiftUI

/// The Inbox tab's data: open issues / pull requests of one project's GitHub repository.
@MainActor
@Observable
final class InboxModel {
    enum Kind: String, CaseIterable { case issues, pullRequests }

    var projectID: UUID?
    var kind: Kind = .issues
    var filter: GitHubInboxFilter = .all
    private(set) var repo: String?
    private(set) var items: [GitHubListItem] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?
    var selection: GitHubListItem.ID?
    private(set) var details: [String: GitHubItemDetails] = [:]
    private(set) var detailErrors: [String: String] = [:]
    private(set) var detailLoading: Set<String> = []

    var itemKind: LinkedWorkItem.Kind { kind == .issues ? .issue : .pr }
    var selectedItem: GitHubListItem? { items.first { $0.id == selection } }

    /// Lists the open items (gh), keeping the selection when it is still there.
    func reload(model: AppModel) async {
        guard let projectID, let project = model.deck.project(projectID) else {
            repo = nil; items = []; error = nil
            return
        }
        let monitor = GitHubMonitor.shared
        if monitor.availability != .ready { await monitor.checkAvailability() }
        guard monitor.availability == .ready else {
            error = GitHubAlert.setupHint(monitor.availability)
            items = []
            return
        }
        loading = true
        defer { loading = false }
        switch await GitHubRepoCache.shared.resolve(project.path) {
        case .failure(let failure):
            repo = nil; items = []; error = failure.message
            return
        case .success(let name):
            repo = name
        }
        guard let repo else { return }
        let (kind, filter, requested) = (itemKind, self.filter, projectID)
        let result = await Task.detached { GitHub.list(kind, repo: repo, filter: filter) }.value
        // The project / tab / filter may have changed meanwhile.
        guard requested == self.projectID, kind == itemKind, filter == self.filter else { return }
        switch result {
        case .success(let list):
            items = list
            error = nil
            loadedAt = Date()
            if let selection, !list.contains(where: { $0.id == selection }) { self.selection = nil }
        case .failure(let failure):
            error = failure.message
        }
    }

    func loadDetails(_ item: GitHubListItem) async {
        guard !detailLoading.contains(item.id) else { return }
        detailLoading.insert(item.id)
        let work = item.workItem
        let result = await Task.detached { GitHub.view(work) }.value
        detailLoading.remove(item.id)
        switch result {
        case .success(let d): details[item.id] = d; detailErrors[item.id] = nil
        case .failure(let e): detailErrors[item.id] = e.message
        }
    }
}

/// Inbox tab: list on the left, the selected item on the right. Polls gh only while shown
/// (TabContent creates it only for the selected tab) and while the app is in front.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var inbox = InboxModel()
    @AppStorage("inbox.projectID", store: .windowState) private var savedProject = ""
    @AppStorage("inbox.newWorktree", store: .windowState) private var newWorktree = false

    static let pollInterval: Duration = .seconds(90)

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 340)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if inbox.projectID == nil {
                inbox.projectID = UUID(uuidString: savedProject).flatMap { model.deck.project($0)?.id }
                    ?? model.selectedProjectID ?? model.deck.projects.first?.id
            }
        }
        .task(id: "\(inbox.projectID?.uuidString ?? "")|\(inbox.kind)|\(inbox.filter)") {
            while !Task.isCancelled {
                if NSApp.isActive || inbox.loadedAt == nil { await inbox.reload(model: model) }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Project", selection: Binding(get: { inbox.projectID }, set: {
                inbox.projectID = $0
                inbox.selection = nil
                savedProject = $0?.uuidString ?? ""
            })) {
                ForEach(model.deck.projects) { Text($0.name).tag(Optional($0.id)) }
            }
            .fixedSize()
            Picker("Kind", selection: Binding(get: { inbox.kind }, set: {
                inbox.kind = $0
                inbox.selection = nil
                if $0 == .issues, inbox.filter == .reviewRequested { inbox.filter = .all }
            })) {
                Text("Issues").tag(InboxModel.Kind.issues)
                Text("Pull Requests").tag(InboxModel.Kind.pullRequests)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Show", selection: Binding(get: { inbox.filter }, set: { inbox.filter = $0; inbox.selection = nil })) {
                Text("All open").tag(GitHubInboxFilter.all)
                Text("Assigned to me").tag(GitHubInboxFilter.assignedToMe)
                if inbox.kind == .pullRequests { Text("Review requested").tag(GitHubInboxFilter.reviewRequested) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            if let repo = inbox.repo {
                Text(verbatim: repo).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if inbox.loading {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await inbox.reload(model: model) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
        }
    }

    @ViewBuilder private var list: some View {
        if model.deck.projects.isEmpty {
            placeholder(String(localized: "Add a project to see its GitHub issues and pull requests."), symbol: "folder.badge.plus")
        } else if let error = inbox.error, inbox.items.isEmpty {
            placeholder(error, symbol: "exclamationmark.triangle")
        } else if inbox.items.isEmpty {
            if inbox.loading || inbox.loadedAt == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder(inbox.kind == .issues ? String(localized: "No open issues") : String(localized: "No open pull requests"), symbol: "tray")
            }
        } else {
            List(inbox.items, selection: $inbox.selection) { item in
                InboxRow(item: item, linked: linkedSession(for: item) != nil).tag(item.id)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder private var detail: some View {
        if let item = inbox.selectedItem {
            InboxDetail(inbox: inbox, item: item, newWorktree: $newWorktree, linkedSession: linkedSession(for: item))
                .id(item.id)
        } else {
            placeholder(String(localized: "Select an issue or pull request"), symbol: "tray")
        }
    }

    private func linkedSession(for item: GitHubListItem) -> DeckSession? {
        model.deck.sessions.first { $0.linkedWorkItem?.isSameItem(as: item.workItem) ?? false }
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InboxRow: View {
    let item: GitHubListItem
    let linked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: GitHubStyle.icon(item.kind, item.isDraft ? .draft : .open))
                    .foregroundStyle(GitHubStyle.color(item.isDraft ? .draft : .open))
                Text(verbatim: "#\(item.number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Text(item.title).lineLimit(2)
                if linked {
                    Image(systemName: "link").font(.caption).foregroundStyle(.secondary).help("Linked to a session")
                }
            }
            HStack(spacing: 4) {
                if let author = item.author { Text(verbatim: "@\(author)") }
                Text(item.createdAt, format: .relative(presentation: .named))
                ForEach(item.labels.prefix(3), id: \.self) { label in
                    Text(label.name)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill((label.color.flatMap(Color.init(githubHex:)) ?? .secondary).opacity(0.25)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

private struct InboxDetail: View {
    @Environment(AppModel.self) private var model
    let inbox: InboxModel
    let item: GitHubListItem
    @Binding var newWorktree: Bool
    let linkedSession: DeckSession?

    var body: some View {
        let details = inbox.details[item.id]
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(item.repo) #\(item.number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if inbox.detailLoading.contains(item.id) { ProgressView().controlSize(.mini) }
                    }
                    Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        if let author = item.author { Text(verbatim: "@\(author)") }
                        Text("· opened \(item.createdAt, format: .relative(presentation: .named))")
                        if let branch = details?.headRefName {
                            Text(verbatim: "·")
                            Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let details {
                        if details.kind == .pr, let checks = details.checks {
                            checksSummary(checks)
                            FailedChecksView(pullRequest: item.workItem, details: details,
                                             sessionID: linkedSession?.id, projectID: inbox.projectID)
                        }
                        let body = details.body.trimmingCharacters(in: .whitespacesAndNewlines)
                        Divider()
                        if body.isEmpty {
                            Text("No description.").foregroundStyle(.tertiary)
                        } else {
                            Text(GitHubStyle.markdown(body, limit: 8000)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        let recent = details.comments.suffix(8)
                        if !recent.isEmpty {
                            Divider()
                            Text("Latest activity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(recent.reversed()) { comment in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(verbatim: "@\(comment.author)").fontWeight(.medium)
                                        if comment.kind == .review, let state = comment.reviewState {
                                            Text(GitHubStyle.reviewTitle(state)).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(comment.createdAt, format: .relative(presentation: .named)).foregroundStyle(.tertiary)
                                    }
                                    .font(.caption)
                                    if !comment.body.isEmpty {
                                        Text(GitHubStyle.markdown(comment.body, limit: 1200)).font(.callout).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    } else if let error = inbox.detailErrors[item.id] {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actions.padding(10)
        }
        .task(id: item.updatedAt) { await inbox.loadDetails(item) }
    }

    @ViewBuilder private func checksSummary(_ checks: GitHubChecks) -> some View {
        switch checks.outcome {
        case .failed:
            Label("\(checks.failed) of \(checks.total) checks failed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .pending:
            Label("\(checks.pending) of \(checks.total) checks running", systemImage: "clock.fill").foregroundStyle(.orange)
        case .passed:
            Label("All \(checks.passed) checks passed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                guard let projectID = inbox.projectID else { return }
                model.startWork(on: item, projectID: projectID, newWorktree: newWorktree)
            } label: {
                Label("Start Work", systemImage: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help("New Claude session in this project, linked to the item, told to work on it")
            Toggle("New worktree", isOn: $newWorktree)
                .toggleStyle(.checkbox)
                .disabled(!(inbox.projectID.flatMap { model.deck.project($0) }.map(model.isGitRepository) ?? false))
            if let session = linkedSession {
                Button("Open Session") {
                    model.tabs.selectSessions()
                    model.reveal(session.id)
                }
                .help(session.name)
            }
            Spacer()
            if let url = URL(string: item.url) {
                Link(destination: url) { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
            }
        }
    }
}

/// Failed checks of a pull request with "Fix with Claude" for GitHub Actions jobs (linked-PR popover,
/// Inbox detail). A check run that already got a repair request shows that instead of the button.
struct FailedChecksView: View {
    @Environment(AppModel.self) private var model
    let pullRequest: LinkedWorkItem
    let details: GitHubItemDetails
    /// Where the fix goes: the session linked to the PR, else a new session in `projectID`.
    let sessionID: UUID?
    let projectID: UUID?

    var body: some View {
        if let checks = details.checks, !checks.failedChecks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(checks.failedChecks) { check in
                    row(check)
                }
            }
            .font(.callout)
        }
    }

    private func row(_ check: GitHubFailedCheck) -> some View {
        let key = CIRepair.key(repo: pullRequest.repo, number: pullRequest.number, check: check)
        return HStack(spacing: 6) {
            Image(systemName: "xmark.circle").foregroundStyle(.red)
            Text(check.displayName).lineLimit(1).truncationMode(.middle)
            if let link = check.detailsURL.flatMap(URL.init(string:)) {
                Link(destination: link) { Image(systemName: "arrow.up.right.square") }
                    .help("Open the run on GitHub")
            }
            Spacer(minLength: 8)
            if GitHubMonitor.shared.repairing.contains(key) {
                ProgressView().controlSize(.mini)
                Text("Fetching log…").font(.caption).foregroundStyle(.secondary)
            } else if let request = model.deck.ciRepairRequest(key) {
                Button {
                    if let sid = request.sessionID, model.deck.session(sid) != nil {
                        model.tabs.selectSessions()
                        model.reveal(sid)
                    }
                } label: {
                    Label("Fix requested", systemImage: "checkmark")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(String(localized: "Sent to Claude \(request.requestedAt.formatted(.relative(presentation: .named))). A re-run that fails again can be fixed again."))
            } else if check.canRepair, sessionID != nil || projectID != nil {
                Button("Fix with Claude") {
                    model.repairCheck(check, pullRequest: pullRequest, branch: details.headRefName, sessionID: sessionID, projectID: projectID)
                }
                .controlSize(.small)
                .help(sessionID != nil
                      ? String(localized: "Send the failing log to the linked session with an instruction to fix it")
                      : String(localized: "Start a Claude session with the failing log and an instruction to fix it"))
            }
        }
    }
}
