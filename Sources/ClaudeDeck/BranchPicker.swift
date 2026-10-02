import AppKit
import ClaudeDeckCore
import SwiftUI

/// The branch name in the Changes header: opens a searchable list of local and remote branches
/// to switch to, and "Create Branch…".
struct BranchPickerButton: View {
    let changes: ChangesModel
    @State private var showing = false

    var body: some View {
        let status = changes.status
        Button { showing.toggle() } label: {
            HStack(spacing: 3) {
                Text(status.branch ?? String(localized: "Detached HEAD"))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(changes.repo == nil || status.isUnborn)
        .help(status.upstream.map { String(localized: "Tracking \($0)") + "\n" + String(localized: "Click to switch or create a branch") }
              ?? String(localized: "No upstream branch") + "\n" + String(localized: "Click to switch or create a branch"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            BranchPickerList(changes: changes) { showing = false }
        }
    }
}

private struct BranchPickerList: View {
    let changes: ChangesModel
    let dismiss: () -> Void
    @State private var branches: [GitBranch] = []
    @State private var loaded = false
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search branches", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Button {
                dismiss()
                changes.promptCreateBranch(existing: branches)
            } label: {
                Label("Create Branch from Current HEAD…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            Divider()
            if !loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    section(String(localized: "Branches"), filtered.filter { !$0.isRemote })
                    section(String(localized: "Remote Branches"), filtered.filter(\.isRemote))
                }
                .listStyle(.sidebar)
                .overlay {
                    if filtered.isEmpty { Text("No matching branches").foregroundStyle(.secondary) }
                }
            }
        }
        .frame(width: 320, height: 380)
        .task {
            guard let repo = changes.repo else { return }
            branches = await Task.detached { Git.branches(in: repo) }.value
            loaded = true
        }
    }

    private var filtered: [GitBranch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? branches : branches.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [GitBranch]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { branch in
                    Button {
                        guard !branch.isCurrent else { return }
                        dismiss()
                        changes.switchBranch(to: branch, existing: branches)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: branch.isCurrent ? "checkmark" : branch.isRemote ? "cloud" : "arrow.triangle.branch")
                                .foregroundStyle(branch.isCurrent ? Color.accentColor : .secondary)
                                .frame(width: 14)
                            Text(branch.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if let date = branch.date {
                                Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(branch.isRemote ? String(localized: "Check out as a local branch tracking \(branch.name)")
                          : branch.upstream.map { String(localized: "Tracking \($0)") } ?? "")
                }
            }
        }
    }
}

extension ChangesModel {
    /// Switches branch; with uncommitted changes, offers to stash them first (the stash is kept).
    func switchBranch(to branch: GitBranch, existing: [GitBranch]) {
        let target = branch.isRemote ? branch.localName : branch.name
        if status.hasChanges {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "You have uncommitted changes")
            alert.informativeText = String(localized: "Stash them (untracked files included) and switch to “\(target)”? The stash stays in the stash list until you apply it.")
            alert.addButton(withTitle: String(localized: "Stash & Switch"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runAsSheet() == .alertFirstButtonReturn else { return }
            let from = status.branch ?? "HEAD"
            let message = "ClaudeDeck: switching from \(from) to \(target)"
            perform { repo in
                let stash = Git.stashAll(message: message, in: repo)
                guard stash.succeeded else { return stash }
                return Git.checkout(branch, existing: existing, in: repo)
            }
        } else {
            perform { Git.checkout(branch, existing: existing, in: $0) }
        }
    }

    /// Asks for a name (validated by git's rules) and creates + checks out the branch at HEAD.
    func promptCreateBranch(existing: [GitBranch]) {
        guard let repo else { return }
        Task {
            var initial = ""
            while let name = TextPrompt.ask(title: String(localized: "New Branch from Current HEAD"),
                                            placeholder: String(localized: "feature/name"), initial: initial) {
                let problem = await Task.detached { Git.branchNameProblem(name, existing: existing, in: repo) }.value
                guard let problem else {
                    perform { Git.createBranch(name, in: $0) }
                    return
                }
                let alert = NSAlert()
                alert.messageText = problem
                alert.addButton(withTitle: String(localized: "OK"))
                alert.runAsSheet()
                initial = name
            }
        }
    }
}
