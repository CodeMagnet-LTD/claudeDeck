import AppKit
import ClaudeDeckCore
import SwiftUI

enum GitHubStyle {
    static func color(_ state: GitHubItemState?) -> Color {
        switch state {
        case .open: .green
        case .draft, nil: .secondary
        case .merged: .purple
        case .closed: .red
        }
    }

    static func icon(_ kind: LinkedWorkItem.Kind, _ state: GitHubItemState?) -> String {
        switch (kind, state) {
        case (.pr, .merged): "arrow.triangle.merge"
        case (.pr, _): "arrow.triangle.pull"
        case (.issue, .closed): "checkmark.circle"
        case (.issue, _): "smallcircle.filled.circle"
        }
    }

    static func stateTitle(_ state: GitHubItemState) -> String {
        switch state {
        // Keyed: "Open" alone is already the verb ("Aç").
        case .open: String(localized: "github.state.open", defaultValue: "Open")
        case .draft: String(localized: "github.state.draft", defaultValue: "Draft")
        case .merged: String(localized: "github.state.merged", defaultValue: "Merged")
        case .closed: String(localized: "github.state.closed", defaultValue: "Closed")
        }
    }

    static func reviewTitle(_ state: String) -> String {
        switch state {
        case "APPROVED": String(localized: "approved")
        case "CHANGES_REQUESTED": String(localized: "requested changes")
        case "COMMENTED": String(localized: "reviewed")
        case "DISMISSED": String(localized: "review dismissed")
        default: String(localized: "reviewed")
        }
    }

    /// GitHub markdown as inline-styled text (bold, code, links); block structure stays as plain lines.
    static func markdown(_ text: String, limit: Int) -> AttributedString {
        var source = text.replacingOccurrences(of: "\r\n", with: "\n")
        // HTML comments (PR templates) are noise here.
        source = source.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if source.count > limit { source = String(source.prefix(limit)) + "…" }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }
}

/// "PR #12" / "#34" capsule, colored by state, with a dot when the item changed since last seen.
/// Clicking it shows `LinkedWorkItemView`.
struct GitHubLinkBadge: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession
    /// Opens on `GitHubMonitor.debugPresentRequest` (only one badge per session should).
    var answersDebugPresent = false
    @State private var showing = false

    var body: some View {
        if let item = session.linkedWorkItem {
            let monitor = GitHubMonitor.shared
            let state = monitor.details[session.id]?.displayState
            let color = GitHubStyle.color(state)
            Button {
                showing.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: GitHubStyle.icon(item.kind, state))
                    Text(item.shortLabel).monospacedDigit()
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(0.14)))
                .overlay(alignment: .topTrailing) {
                    if monitor.hasUpdate(session) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 2, y: -2)
                    }
                }
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help(monitor.details[session.id]?.title ?? item.url)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                LinkedWorkItemView(sessionID: session.id)
                    .environment(model)
            }
            .onChange(of: monitor.debugPresentRequest) { _, id in
                guard answersDebugPresent, id == session.id else { return }
                monitor.debugPresentRequest = nil
                showing = true
            }
        }
    }
}

/// Popover with the linked issue / pull request: state, labels, body, latest activity, CI.
struct LinkedWorkItemView: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID
    @State private var composing = false
    @State private var draft = ""
    @State private var posting = false
    @State private var postError: String?

    var body: some View {
        let monitor = GitHubMonitor.shared
        if let session = model.deck.session(sessionID), let item = session.linkedWorkItem {
            let details = monitor.details[sessionID]
            VStack(alignment: .leading, spacing: 0) {
                header(item, details)
                    .padding(12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if monitor.availability == .missing || monitor.availability == .unauthenticated {
                            setupMessage(monitor.availability)
                        } else if let error = monitor.errors[sessionID], details == nil {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.callout)
                        } else if let details {
                            content(details)
                        } else {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 380)
                Divider()
                if composing { commentBox(item).padding(12); Divider() }
                actions(session, item).padding(10)
            }
            .frame(width: 420)
            .task {
                monitor.markSeen(sessionID)
                if monitor.availability != .ready { await monitor.checkAvailability() }
                await monitor.refresh(sessionID)
                monitor.markSeen(sessionID)
            }
        }
    }

    private func header(_ item: LinkedWorkItem, _ details: GitHubItemDetails?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                let state = details?.displayState
                if let state {
                    Label(GitHubStyle.stateTitle(state), systemImage: GitHubStyle.icon(item.kind, state))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(GitHubStyle.color(state)))
                }
                Text(verbatim: "\(item.repo) #\(item.number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if GitHubMonitor.shared.loading.contains(sessionID) { ProgressView().controlSize(.mini) }
            }
            if let details {
                Text(details.title).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    if let author = details.author { Text(verbatim: "@\(author)") }
                    Text("· updated \(details.updatedAt, format: .relative(presentation: .named))")
                    if let branch = details.headRefName {
                        Text(verbatim: "·")
                        Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !details.labels.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(details.labels, id: \.self) { label in
                                let color = label.color.flatMap(Color.init(githubHex:)) ?? .secondary
                                Text(label.name)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(color.opacity(0.25)))
                                    .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 0.5))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ details: GitHubItemDetails) -> some View {
        if details.kind == .pr { pullRequestStatus(details) }
        let body = details.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            Text("No description.").font(.callout).foregroundStyle(.tertiary)
        } else {
            Text(GitHubStyle.markdown(body, limit: 3000))
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        let recent = details.comments.suffix(5)
        if !recent.isEmpty {
            Divider()
            Text("Latest activity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(recent.reversed()) { comment in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: comment.kind == .review ? reviewIcon(comment.reviewState) : "text.bubble")
                            .foregroundStyle(comment.reviewState == "APPROVED" ? .green : comment.reviewState == "CHANGES_REQUESTED" ? .red : .secondary)
                        Text(verbatim: "@\(comment.author)").fontWeight(.medium)
                        if comment.kind == .review, let state = comment.reviewState {
                            Text(GitHubStyle.reviewTitle(state)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(comment.createdAt, format: .relative(presentation: .named)).foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                    if !comment.body.isEmpty {
                        Text(GitHubStyle.markdown(comment.body, limit: 600))
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func reviewIcon(_ state: String?) -> String {
        switch state {
        case "APPROVED": "checkmark.seal"
        case "CHANGES_REQUESTED": "exclamationmark.bubble"
        default: "eye"
        }
    }

    @ViewBuilder
    private func pullRequestStatus(_ details: GitHubItemDetails) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let checks = details.checks {
                switch checks.outcome {
                case .failed:
                    Label("\(checks.failed) of \(checks.total) checks failed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    if !checks.failedNames.isEmpty {
                        Text(checks.failedNames.prefix(4).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                case .pending:
                    Label("\(checks.pending) of \(checks.total) checks running", systemImage: "clock.fill")
                        .foregroundStyle(.orange)
                case .passed:
                    Label("All \(checks.passed) checks passed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            switch details.reviewDecision {
            case "APPROVED": Label("Approved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case "CHANGES_REQUESTED": Label("Changes requested", systemImage: "exclamationmark.bubble.fill").foregroundStyle(.red)
            case "REVIEW_REQUIRED": Label("Review required", systemImage: "eye").foregroundStyle(.secondary)
            default: EmptyView()
            }
            if details.displayState == .open, details.mergeStateStatus == "DIRTY" {
                Label("Merge conflicts", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }

    private func setupMessage(_ availability: GitHubAvailability?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(availability == .missing ? String(localized: "GitHub CLI (gh) is not installed") : String(localized: "GitHub CLI is not signed in"),
                  systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.medium))
            Text(GitHubAlert.setupHint(availability)).font(.callout).foregroundStyle(.secondary)
            Button("Check Again") {
                Task {
                    await GitHubMonitor.shared.checkAvailability()
                    await GitHubMonitor.shared.refresh(sessionID)
                }
            }
            .disabled(GitHubMonitor.shared.checkingAvailability)
        }
    }

    private func commentBox(_ item: LinkedWorkItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $draft)
                .font(.callout)
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            if let postError {
                Text(postError).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Cancel") { composing = false; postError = nil }
                Button("Comment") { post(item) }
                    .buttonStyle(.borderedProminent)
                    .disabled(posting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func post(_ item: LinkedWorkItem) {
        let body = draft
        posting = true
        postError = nil
        Task {
            let result = await Task.detached { GitHub.comment(on: item, body: body) }.value
            posting = false
            switch result {
            case .success:
                draft = ""
                composing = false
                await GitHubMonitor.shared.refresh(sessionID)
                GitHubMonitor.shared.markSeen(sessionID)
            case .failure(let error):
                postError = error.message
            }
        }
    }

    private func actions(_ session: DeckSession, _ item: LinkedWorkItem) -> some View {
        HStack(spacing: 8) {
            Button {
                if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
            } label: {
                Label("Open on GitHub", systemImage: "safari")
            }
            Button {
                composing = true
            } label: {
                Label("Add Comment…", systemImage: "text.bubble")
            }
            .disabled(composing || GitHubMonitor.shared.availability != .ready)
            Spacer()
            if session.kind == .claude {
                Button {
                    model.sendWorkItemToClaude(session.id)
                } label: {
                    Label("Send to Claude", systemImage: "paperplane")
                }
                .help("Types a short prompt with the link into the session")
            }
        }
        .controlSize(.small)
    }
}

/// Session menu items: link / edit / remove, and "PR for current branch".
struct GitHubLinkMenuItems: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession

    var body: some View {
        if session.linkedWorkItem == nil {
            Button("Link GitHub Issue or PR…") { model.promptLinkWorkItem(session.id) }
        } else {
            Button("Edit GitHub Link…") { model.promptLinkWorkItem(session.id) }
            Button("Remove GitHub Link") { model.setLinkedWorkItem(nil, for: session.id) }
        }
        if model.repositoryDirectory(for: session) != nil {
            Button("Link PR for Current Branch") { model.linkPullRequestForCurrentBranch(session.id) }
        }
    }
}

extension Color {
    /// GitHub label colors ("d73a4a").
    init?(githubHex hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
