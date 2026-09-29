import AppKit
import ClaudeDeckCore
import Observation
import SwiftUI

/// Which page the right-hand inspector shows.
enum InspectorTab: String {
    case files, changes
}

/// The inspector: a Files | Changes switch over the file browser and the source control view.
struct InspectorPanel: View {
    @Binding var tab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                Text("Files").tag(InspectorTab.files)
                Text("Changes").tag(InspectorTab.changes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
            // The file browser stays alive underneath so its expansion state survives a visit to
            // Changes; the Changes view (which polls) exists only while shown.
            ZStack {
                FileBrowserPanel()
                    .opacity(tab == .files ? 1 : 0)
                    .allowsHitTesting(tab == .files)
                    .accessibilityHidden(tab != .files)
                if tab == .changes {
                    ChangesView().background(.background)
                }
            }
        }
    }
}

// MARK: - Model

/// Live git state of one directory for the Changes view. Git runs off the main actor;
/// refreshes are coalesced.
@MainActor
@Observable
final class ChangesModel {
    /// One model per directory for the app's lifetime, so a half-written commit message
    /// survives switching tabs or sessions.
    private static var cache: [String: ChangesModel] = [:]

    static func model(for directory: String) -> ChangesModel {
        if let model = cache[directory] { return model }
        let model = ChangesModel(root: URL(fileURLWithPath: directory))
        cache[directory] = model
        return model
    }

    let root: URL
    private(set) var repo: URL?
    private(set) var loaded = false
    private(set) var status = GitRepoStatus()
    var selection: String? { didSet { if selection != oldValue { loadDiff() } } }
    private(set) var diffFiles: [DiffFile] = []
    @ObservationIgnored private var diffText = ""
    var message = ""
    var amend = false { didSet { if amend && !oldValue { prefillAmend() } } }
    private(set) var busy = false
    var error: String?
    private(set) var generating = false

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var diffTask: Task<Void, Never>?
    @ObservationIgnored private var generateTask: Task<Void, Never>?
    @ObservationIgnored private var generator: OneShotProcess?
    @ObservationIgnored private var watchers: [DirectoryWatcher] = []
    @ObservationIgnored private var active = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var pendingRefresh = false

    init(root: URL) {
        self.root = root
    }

    var selectedChange: GitChange? {
        guard let selection else { return nil }
        return (status.staged + status.unstaged).first { $0.id == selection }
    }

    // MARK: Refresh

    func activate() {
        active = true
        refresh(after: .zero)
    }

    func deactivate() {
        active = false
        watchers.forEach { $0.stop() }
        watchers = []
    }

    /// Re-reads status (and the selected diff) off the main actor; calls within `delay` coalesce.
    func refresh(after delay: Duration = .milliseconds(200)) {
        // A refresh already running git finishes; one more follows it instead of piling up.
        if refreshing { pendingRefresh = true; return }
        refreshTask?.cancel()
        let root = self.root
        let knownRepo = repo
        refreshTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.refreshing = true
            let (repo, status) = await Task.detached { () -> (URL?, GitRepoStatus?) in
                guard let repo = knownRepo ?? Git.root(of: root) else { return (nil, nil) }
                return (repo, Git.repoStatus(in: repo))
            }.value
            self.refreshing = false
            self.apply(repo: repo, status: status)
            if self.pendingRefresh {
                self.pendingRefresh = false
                self.refresh(after: .zero)
            }
        }
    }

    private func apply(repo: URL?, status: GitRepoStatus?) {
        loaded = true
        if repo != self.repo {
            self.repo = repo
            watchers.forEach { $0.stop() }
            watchers = []
        }
        if active, watchers.isEmpty, let repo { startWatching(repo) }
        let new = status ?? GitRepoStatus()
        if new != self.status { self.status = new }
        // Keep following a file that moved between Staged and Changes.
        if let selection, selectedChange == nil {
            let path = selection.split(separator: ":", maxSplits: 1).last.map(String.init)
            self.selection = (new.staged + new.unstaged).first { $0.path == path }?.id
        } else {
            loadDiff()
        }
    }

    private func startWatching(_ repo: URL) {
        Task { [weak self] in
            let dirs = await Task.detached { Git.watchedDirectories(of: repo) }.value
            guard let self, self.active, self.repo == repo, self.watchers.isEmpty else { return }
            self.watchers = dirs.map { dir in
                let watcher = DirectoryWatcher(url: dir, debounce: 0.3) { [weak self] in
                    Task { @MainActor in self?.refresh() }
                }
                watcher.start()
                return watcher
            }
        }
    }

    private func loadDiff() {
        diffTask?.cancel()
        guard let repo, let change = selectedChange else {
            diffText = ""
            diffFiles = []
            return
        }
        diffTask = Task { [weak self] in
            let text = await Task.detached { Git.changeDiff(change, in: repo) }.value
            guard !Task.isCancelled, let self, text != self.diffText else { return }
            self.diffText = text
            self.diffFiles = UnifiedDiff.parse(text)
        }
    }

    // MARK: Operations

    private func perform(_ operation: @escaping @Sendable (URL) -> Git.Result,
                         then: ((Git.Result) -> Void)? = nil) {
        guard let repo, !busy else { return }
        busy = true
        error = nil
        Task {
            let result = await Task.detached { operation(repo) }.value
            busy = false
            if !result.succeeded { error = result.message.isEmpty ? String(localized: "Git reported an error.") : result.message }
            then?(result)
            refresh(after: .zero)
        }
    }

    func stage(_ changes: [GitChange]) { let paths = changes.map(\.path); perform { Git.stage(paths, in: $0) } }
    func unstage(_ changes: [GitChange]) { perform { Git.unstage(changes, in: $0) } }
    func discard(_ changes: [GitChange]) { perform { Git.discard(changes, in: $0) } }
    func stageAll() { perform { Git.stageAll(in: $0) } }
    func unstageAll() { perform { Git.unstageAll(in: $0) } }

    /// Stages (or, for a staged file, unstages) one hunk of the selected diff.
    func toggleHunk(_ index: Int, of file: DiffFile, change: GitChange) {
        let patch = UnifiedDiff.patch(file, hunks: [index])
        let reverse = change.area == .staged
        perform { Git.applyToIndex(patch, reverse: reverse, in: $0) }
    }

    var canCommit: Bool {
        !busy && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (amend || !status.staged.isEmpty)
    }

    func commit(andPush: Bool) {
        guard canCommit else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let amend = self.amend
        let hasUpstream = status.upstream != nil
        perform({ repo in
            let result = Git.commit(message: text, amend: amend, in: repo)
            guard result.succeeded, andPush else { return result }
            return Git.push(in: repo, hasUpstream: hasUpstream)
        }, then: { [weak self] _ in
            // The commit itself may have succeeded even if the push failed.
            guard let self, let repo = self.repo else { return }
            Task {
                let clean = await Task.detached { Git.lastCommitMessage(in: repo) == text }.value
                if clean && self.message.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                    self.message = ""
                    self.amend = false
                }
            }
        })
    }

    func push() {
        let hasUpstream = status.upstream != nil
        perform { Git.push(in: $0, hasUpstream: hasUpstream) }
    }

    func pull() { perform { Git.pull(in: $0) } }

    private func prefillAmend() {
        guard message.isEmpty, let repo else { return }
        Task {
            let last = await Task.detached { Git.lastCommitMessage(in: repo) }.value
            if amend, message.isEmpty, let last { message = last }
        }
    }

    // MARK: Commit message generation

    /// Asks the user's `claude` CLI (one-shot, no tools) for a message describing the staged diff.
    func generateMessage(claudePath: String?) {
        guard let repo, !generating else { return }
        generating = true
        error = nil
        let branch = status.branch
        let runner = OneShotProcess()
        generator = runner
        generateTask = Task { [weak self] in
            var claude = claudePath
            if claude == nil { claude = await Task.detached { ShellEnvironment.resolveClaude() }.value }
            let context = await Task.detached { Git.commitContext(in: repo) }.value
            guard let self, !Task.isCancelled else { return }
            defer { self.generating = false; self.generator = nil }
            guard let claude else {
                self.error = String(localized: "`claude` wasn’t found in your login shell. Is Claude Code installed?")
                return
            }
            guard !context.patch.isEmpty else {
                self.error = String(localized: "There are no changes to describe.")
                return
            }
            let prompt = CommitMessagePrompt.build(branch: branch, stat: context.stat, patch: context.patch)
            let result = await runner.run(
                ShellEnvironment.loginShell,
                ["-l", "-c", #"exec "$0" "$@""#, claude, "-p", "--tools", "", "--no-session-persistence"],
                input: prompt, directory: repo, timeout: 180)
            guard !runner.isCancelled, !Task.isCancelled else { return }
            let text = CommitMessagePrompt.clean(result.output)
            if result.status == 0, !text.isEmpty {
                self.message = text
            } else {
                let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                self.error = detail.isEmpty ? String(localized: "Claude didn’t return a commit message.") : detail
            }
        }
    }

    func cancelGeneration() {
        generator?.cancel()
        generateTask?.cancel()
        generator = nil
        generating = false
    }
}

/// Runs one process to completion off the main actor, feeding it stdin; cancellable.
final class OneShotProcess: @unchecked Sendable {
    struct Output: Sendable {
        var status: Int32
        var output: String
        var error: String
    }

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock {
            cancelled = true
            if process?.isRunning == true { process?.terminate() }
        }
    }

    func run(_ executable: String, _ args: [String], input: String, directory: URL, timeout: TimeInterval) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.runBlocking(executable, args, input: input, directory: directory, timeout: timeout))
            }
        }
    }

    private func runBlocking(_ executable: String, _ args: [String], input: String, directory: URL, timeout: TimeInterval) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = directory
        p.environment = ShellEnvironment.cleanEnvironment
        let inPipe = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = inPipe
        p.standardOutput = out
        p.standardError = err
        let started: Bool = lock.withLock {
            guard !cancelled, (try? p.run()) != nil else { return false }
            process = p
            return true
        }
        guard started else { return Output(status: -1, output: "", error: "") }
        DispatchQueue.global().async {
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let box = DataBox()
        let group = DispatchGroup()
        for (index, pipe) in [out, err].enumerated() {
            group.enter()
            DispatchQueue.global().async {
                box.set(index, pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = group.wait(timeout: .now() + 5)
            return Output(status: -1, output: "", error: String(localized: "Claude took too long to answer."))
        }
        p.waitUntilExit()
        return Output(status: p.terminationStatus, output: box.string(0), error: box.string(1))
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: [Int: Data] = [:]
        func set(_ i: Int, _ d: Data) { lock.withLock { data[i] = d } }
        func string(_ i: Int) -> String { lock.withLock { String(decoding: data[i] ?? Data(), as: UTF8.self) } }
    }
}

// MARK: - Views

/// Source control for the focused project (or the focused session's worktree).
struct ChangesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let dir = focusedDirectory {
            ChangesContent(changes: ChangesModel.model(for: dir))
                .id(dir)
        } else {
            Text("Select a session to see its changes")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Same choice as the Files tab (`FileBrowserPanel.focusedProject`).
    private var focusedDirectory: String? {
        let selected = model.selectedSessionID.flatMap { model.deck.session($0) }
        if let browsed = model.browsedProjectID, let p = model.deck.project(browsed), selected?.projectID != browsed {
            return p.path
        }
        guard let project = selected.flatMap({ model.deck.project($0.projectID) }) else { return model.deck.projects.first?.path }
        if let wd = selected?.workingDirectory, FileManager.default.fileExists(atPath: wd) { return wd }
        return project.path
    }
}

private struct ChangesContent: View {
    @Environment(AppModel.self) private var model
    @Bindable var changes: ChangesModel
    @State private var diffHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            if changes.loaded && changes.repo == nil {
                Text("This folder isn’t a Git repository")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BranchHeader(changes: changes)
                Divider()
                CommitBox(changes: changes)
                if let error = changes.error {
                    ErrorBanner(text: error) { changes.error = nil }
                }
                Divider()
                ChangeList(changes: changes)
                    .frame(maxHeight: .infinity)
                if let change = changes.selectedChange {
                    HorizontalDivider { delta in diffHeight = min(max(120, diffHeight - delta), 900) }
                    DiffPanel(changes: changes, change: change)
                        .frame(height: diffHeight)
                }
            }
        }
        .onAppear { changes.activate() }
        .onDisappear { changes.deactivate() }
        // Working tree edits don't touch .git: poll lightly while the tab is visible.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                if !Task.isCancelled { changes.refresh(after: .zero) }
            }
        }
    }
}

private struct BranchHeader: View {
    let changes: ChangesModel

    var body: some View {
        let status = changes.status
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            Text(status.branch ?? String(localized: "Detached HEAD"))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(status.upstream.map { String(localized: "Tracking \($0)") } ?? String(localized: "No upstream branch"))
            if status.ahead > 0 || status.behind > 0 {
                Text("↑\(status.ahead) ↓\(status.behind)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if changes.busy { ProgressView().controlSize(.small) }
            Button { changes.pull() } label: { Image(systemName: "arrow.down") }
                .buttonStyle(.borderless)
                .help("Pull (fast-forward only)")
                .disabled(changes.busy || status.upstream == nil)
            Button { changes.push() } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless)
                .help(status.upstream == nil ? String(localized: "Publish Branch to origin") : String(localized: "Push"))
                .disabled(changes.busy || status.branch == nil || status.isUnborn)
            Button { changes.refresh(after: .zero) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct CommitBox: View {
    @Environment(AppModel.self) private var model
    @Bindable var changes: ChangesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // TextEditor, not a TextField: Return must insert a newline (subject + body).
            TextEditor(text: $changes.message)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 48, idealHeight: 64, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .overlay(alignment: .topLeading) {
                    if changes.message.isEmpty {
                        Text("Commit message")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(changes.generating)
            HStack(spacing: 8) {
                if changes.generating {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { changes.cancelGeneration() }
                        .controlSize(.small)
                } else {
                    Button {
                        changes.generateMessage(claudePath: model.claudePath)
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(.borderless)
                    .help("Generate Commit Message with Claude")
                    .disabled(changes.busy || !changes.status.hasChanges)
                }
                Toggle("Amend", isOn: $changes.amend)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(changes.status.isUnborn)
                Spacer(minLength: 4)
                Menu {
                    Button("Commit & Push") { changes.commit(andPush: true) }
                        .disabled(!changes.canCommit || changes.status.branch == nil)
                } label: {
                    Text(changes.amend ? LocalizedStringKey("Amend") : LocalizedStringKey("Commit"))
                } primaryAction: {
                    changes.commit(andPush: false)
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(!changes.canCommit)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            ScrollView {
                Text(text).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 80)
            .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
    }
}

private struct ChangeList: View {
    @Bindable var changes: ChangesModel

    var body: some View {
        let status = changes.status
        List(selection: $changes.selection) {
            if !status.staged.isEmpty {
                Section {
                    ForEach(status.staged) { ChangeRow(changes: changes, change: $0).tag($0.id) }
                } header: {
                    SectionHeader(title: String(localized: "Staged"), count: status.staged.count) {
                        Button { changes.unstageAll() } label: { Image(systemName: "minus") }
                            .help("Unstage All")
                    }
                }
            }
            Section {
                ForEach(status.unstaged) { ChangeRow(changes: changes, change: $0).tag($0.id) }
                if status.unstaged.isEmpty && changes.loaded {
                    Text(status.staged.isEmpty ? LocalizedStringKey("No changes") : LocalizedStringKey("No unstaged changes"))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } header: {
                SectionHeader(title: String(localized: "Changes"), count: status.unstaged.count) {
                    if !status.unstaged.isEmpty {
                        Button {
                            let discardable = status.unstaged.filter { $0.area == .unstaged || $0.area == .untracked }
                            guard !discardable.isEmpty, Confirm.ask(
                                String(localized: "Discard all changes?"),
                                detail: String(localized: "Changes to tracked files are lost; new files are moved to the Trash."),
                                action: String(localized: "Discard All")) else { return }
                            changes.discard(discardable)
                        } label: { Image(systemName: "arrow.uturn.backward") }
                            .help("Discard All Changes")
                        Button { changes.stageAll() } label: { Image(systemName: "plus") }
                            .help("Stage All")
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SectionHeader<Actions: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            actions().buttonStyle(.borderless)
        }
    }
}

private struct ChangeRow: View {
    @Environment(AppModel.self) private var model
    let changes: ChangesModel
    let change: GitChange
    @State private var hovering = false

    var body: some View {
        let name = (change.path as NSString).lastPathComponent
        let folder = (change.path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            Text(change.state.rawValue)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(GitStyle.color(change.state))
                .frame(width: 12)
            Text(name).lineLimit(1).truncationMode(.middle)
            if !folder.isEmpty {
                Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 2)
            if hovering {
                actions
            } else {
                counts
            }
        }
        .help(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    @ViewBuilder private var counts: some View {
        HStack(spacing: 3) {
            if let add = change.additions, add > 0 { Text("+\(add)").foregroundStyle(.green) }
            if let del = change.deletions, del > 0 { Text("−\(del)").foregroundStyle(.red) }
        }
        .font(.caption.monospacedDigit())
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            if change.area == .unstaged || change.area == .untracked {
                Button { discard() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Discard Changes")
            }
            if change.isStaged {
                Button { changes.unstage([change]) } label: { Image(systemName: "minus") }
                    .help("Unstage")
            } else {
                Button { changes.stage([change]) } label: { Image(systemName: "plus") }
                    .help(change.area == .conflicted ? String(localized: "Mark as Resolved") : String(localized: "Stage"))
            }
        }
        .buttonStyle(.borderless)
        .disabled(changes.busy)
    }

    @ViewBuilder private var menu: some View {
        if change.isStaged {
            Button("Unstage") { changes.unstage([change]) }
        } else {
            Button(change.area == .conflicted ? LocalizedStringKey("Mark as Resolved") : LocalizedStringKey("Stage")) { changes.stage([change]) }
        }
        if change.area == .unstaged || change.area == .untracked {
            Button("Discard Changes…", role: .destructive) { discard() }
        }
        Divider()
        if let repo = changes.repo {
            let url = repo.appending(path: change.path)
            if change.state != .deleted {
                Button("Open") { FileActions.openDefault(url) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            if let session = model.selectedSessionID, model.terminals.isRunning(session) {
                Button("Add @\(url.lastPathComponent) to Claude") { model.insertPaths([url], into: session) }
            }
            Button("Copy Relative Path") { FileActions.copy(change.path) }
        }
    }

    private func discard() {
        let untracked = change.area == .untracked
        guard Confirm.ask(
            String(localized: "Discard changes to “\(change.path)”?"),
            detail: untracked ? String(localized: "The file is moved to the Trash.") : String(localized: "This can’t be undone."),
            action: String(localized: "Discard")) else { return }
        changes.discard([change])
    }
}

/// Embedded unified diff of the selected change with per-hunk stage/unstage.
private struct DiffPanel: View {
    @Environment(AppModel.self) private var model
    let changes: ChangesModel
    let change: GitChange

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(change.state.rawValue)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(GitStyle.color(change.state))
                Text(change.path).font(.caption).lineLimit(1).truncationMode(.head)
                Text(change.isStaged ? LocalizedStringKey("Staged") : LocalizedStringKey("Working Tree")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { changes.selection = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close Diff")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(changes.diffFiles.enumerated()), id: \.offset) { _, file in
                        if file.isBinary {
                            Text("Binary file").foregroundStyle(.secondary).padding(8)
                        }
                        ForEach(Array(file.hunks.enumerated()), id: \.offset) { index, hunk in
                            hunkHeader(hunk, index: index, file: file)
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                DiffLineRow(line: line, width: gutterWidth, onAsk: askAction(line))
                            }
                        }
                    }
                    if changes.diffFiles.isEmpty {
                        Text("No textual changes").foregroundStyle(.secondary).font(.callout).padding(8)
                    }
                }
                .padding(.bottom, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var gutterWidth: CGFloat {
        let maxLine = changes.diffFiles.flatMap(\.hunks).map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 1
        return CGFloat(max(2, String(maxLine).count)) * 7 + 6
    }

    private func hunkHeader(_ hunk: DiffHunk, index: Int, file: DiffFile) -> some View {
        HStack(spacing: 6) {
            Text(hunk.header)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.purple)
                .lineLimit(1)
            Spacer(minLength: 8)
            if change.area == .staged || change.area == .unstaged {
                Button(change.isStaged ? LocalizedStringKey("Unstage Hunk") : LocalizedStringKey("Stage Hunk")) {
                    changes.toggleHunk(index, of: file, change: change)
                }
                .controlSize(.small)
                .disabled(changes.busy)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(minWidth: 280, alignment: .leading)
        .background(Color.purple.opacity(0.07))
    }

    /// "Ask Claude about this line…": types `@path:LINE comment` into the selected Claude session.
    private func askAction(_ line: DiffLine) -> (() -> Void)? {
        guard let number = line.displayLine, let repo = changes.repo,
              let id = model.selectedSessionID, let session = model.deck.session(id),
              session.kind == .claude, model.terminals.isRunning(id) else { return nil }
        let file = repo.appending(path: change.path)
        return {
            guard let comment = TextPrompt.ask(
                title: String(localized: "Ask Claude about line \(number)"),
                placeholder: String(localized: "Your question or comment"),
                allowEmpty: true) else { return }
            let root = URL(fileURLWithPath: session.workingDirectory ?? model.deck.project(session.projectID)?.path ?? repo.path)
            let mention = "@" + FileListing.relativePath(of: file.resolvingSymlinksInPath(), in: root.resolvingSymlinksInPath()) + ":\(number)"
            model.terminals.type(comment.isEmpty ? mention + " " : mention + " " + comment, into: id)
            model.selectedSessionID = id
        }
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let width: CGFloat
    let onAsk: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldLine)
            number(line.newLine)
            Text(marker)
                .frame(width: 14)
                .foregroundStyle(color)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .noNewline ? .secondary : .primary)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .frame(minWidth: 280, alignment: .leading)
        .background(background)
        .contextMenu {
            Button("Ask Claude about This Line…") { onAsk?() }
                .disabled(onAsk == nil)
            Button("Copy Line") { FileActions.copy(line.text) }
        }
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "-"
        case .context, .noNewline: " "
        }
    }

    private var color: Color {
        switch line.kind {
        case .added: .green
        case .removed: .red
        default: .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: .green.opacity(0.12)
        case .removed: .red.opacity(0.12)
        default: .clear
        }
    }
}

/// Drag handle between the change list and the diff (vertical resizing).
private struct HorizontalDivider: View {
    let onDrag: (CGFloat) -> Void
    @State private var last: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        onDrag(value.translation.height - last)
                        last = value.translation.height
                    }
                    .onEnded { _ in last = 0 }
            )
    }
}
