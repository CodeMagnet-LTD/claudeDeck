import AppKit
import ClaudeDeckCore
import Observation
import SwiftUI

extension AppModel {
    /// The home folder whose `.claude` (transcripts, skills, plugins) the app reads. Demo mode never
    /// uses the real one: `CLAUDEDECK_CLAUDE_HOME`, else a throwaway folder.
    static let claudeHome: URL = {
        if let path = ProcessInfo.processInfo.environment["CLAUDEDECK_CLAUDE_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        if isDemo { return FileManager.default.temporaryDirectory.appending(path: "ClaudeDeckDemoHome") }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// A history search hit: selects the deck session that owns the conversation, or resumes it in a
    /// new session of its project (in its worktree / subfolder when it ran in one).
    func openHistoryResult(_ result: HistorySearchResult) {
        if let existing = deck.sessions.first(where: { $0.claudeSessionID == result.id }) {
            if !terminals.isRunning(existing.id) { launch(existing.id, resume: true) }
            selectedSessionID = existing.id
            tabs.selectSessions()
            return
        }
        guard let cwd = result.cwd else {
            return historyAlert(String(localized: "This conversation doesn’t record its folder, so it can’t be resumed here."))
        }
        guard FileManager.default.fileExists(atPath: cwd) else {
            return historyAlert(String(localized: "The conversation’s folder no longer exists:\n\((cwd as NSString).abbreviatingWithTildeInPath)"))
        }
        var project = HistorySearch.owningProject(cwd: cwd, in: deck.projects)
        if project == nil {
            let root = HistorySearch.projectRoot(forCwd: cwd)
            let alert = NSAlert()
            alert.messageText = String(localized: "Add “\((root as NSString).lastPathComponent)” as a project?")
            alert.informativeText = String(localized: "The conversation ran in \((root as NSString).abbreviatingWithTildeInPath), which isn’t a ClaudeDeck project yet.")
            alert.addButton(withTitle: String(localized: "Add and Resume"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            project = addProject(path: root)
        }
        guard let project else { return }
        let worktree = HistorySearch.worktree(of: cwd)
        let label = worktree.map { "\($0.name) · " } ?? ""
        let name = "\(project.name) · \(label)\(result.title.prefix(30))"
        var created: DeckSession?
        mutate { deck in
            created = deck.addSession(to: project.id, claudeSessionID: result.id, name: name)
            guard let id = created?.id, cwd != project.path else { return }
            deck.updateSession(id) {
                $0.workingDirectory = cwd
                if let worktree, worktree.projectPath == project.path { $0.worktreeName = worktree.name }
            }
        }
        guard let session = created else { return }
        launch(session.id, resume: true, resumeID: result.id)
        selectedSessionID = session.id
        tabs.selectSessions()
    }

    private func historyAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Can’t Resume Conversation")
        alert.informativeText = text
        alert.runModal()
    }
}

/// The Search tab's query and streamed results. One per app (the main window has one Search tab).
@MainActor
@Observable
final class HistorySearchController {
    static let shared = HistorySearchController()

    enum Scope: String, CaseIterable { case project, all }

    var query = "" { didSet { if query != oldValue { schedule() } } }
    var scope: Scope = .all { didSet { if scope != oldValue { schedule() } } }
    /// The project "This Project" searches (the selected session's), set by the view.
    var projectPath: String? { didSet { if projectPath != oldValue, scope == .project { schedule() } } }
    private(set) var results: [HistorySearchResult] = []
    private(set) var isSearching = false
    private(set) var searchedFiles = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    static let minimumQueryLength = 2

    var reachedLimit: Bool { results.count >= HistorySearch.maxResults }

    func schedule() {
        task?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minimumQueryLength else {
            results = []
            isSearching = false
            return
        }
        let projectPath = scope == .project ? projectPath : nil
        let root = TranscriptIndex.defaultRoot(home: AppModel.claudeHome)
        isSearching = true
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250)) // debounce typing
            guard !Task.isCancelled else { return }
            let files = await Task.detached { HistorySearch.files(root: root, projectPath: projectPath) }.value
            guard !Task.isCancelled, let self else { return }
            self.results = []
            self.searchedFiles = files.count
            var batch: [HistorySearchResult] = []
            var lastFlush = ContinuousClock.now
            for await result in HistorySearch.stream(query, in: files) {
                batch.append(result)
                if ContinuousClock.now - lastFlush > .milliseconds(150) {
                    self.results += batch
                    batch = []
                    lastFlush = .now
                }
            }
            guard !Task.isCancelled else { return }
            self.results += batch
            self.isSearching = false
        }
    }

    func cancel() {
        task?.cancel()
        isSearching = false
    }
}

struct HistorySearchView: View {
    @Environment(AppModel.self) private var model
    @State private var search = HistorySearchController.shared
    @FocusState private var fieldFocused: Bool

    private var currentProject: Project? {
        model.selectedSessionID.flatMap { model.deck.session($0) }.flatMap { model.deck.project($0.projectID) }
    }

    var body: some View {
        @Bindable var search = search
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search conversations", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { search.schedule() }
                if search.isSearching { ProgressView().controlSize(.small) }
                Picker("Scope", selection: $search.scope) {
                    Text(currentProject.map { "\($0.name)" } ?? String(localized: "This Project")).tag(HistorySearchController.Scope.project)
                    Text("All Projects").tag(HistorySearchController.Scope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(currentProject == nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            content
        }
        .onAppear {
            search.projectPath = currentProject?.path
            if currentProject == nil { search.scope = .all }
            fieldFocused = true
        }
        .onChange(of: currentProject?.path) { _, path in
            search.projectPath = path
            if path == nil { search.scope = .all }
        }
    }

    @ViewBuilder private var content: some View {
        if search.query.trimmingCharacters(in: .whitespacesAndNewlines).count < HistorySearchController.minimumQueryLength {
            placeholder("Search the text of your Claude conversations", systemImage: "text.magnifyingglass")
        } else if search.results.isEmpty {
            if search.isSearching {
                placeholder("Searching…", systemImage: "hourglass")
            } else {
                placeholder("No matches", systemImage: "magnifyingglass")
            }
        } else {
            List {
                ForEach(search.results) { result in
                    HistoryResultRow(result: result, projectName: projectName(for: result))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.openHistoryResult(result) }
                        .contextMenu {
                            Button("Open Conversation") { model.openHistoryResult(result) }
                            Button("Reveal Transcript in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([result.file])
                            }
                            Button("Copy Session ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(result.id, forType: .string)
                            }
                        }
                }
                if search.reachedLimit {
                    Text("Showing the first \(HistorySearch.maxResults) conversations. Refine the search to see others.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    private func placeholder(_ title: LocalizedStringKey, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary)
            Text("Double-click a result to open it; a conversation no session owns is resumed in a new one.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The deck project the conversation ran in, else the folder's name.
    private func projectName(for result: HistorySearchResult) -> String {
        guard let cwd = result.cwd else { return result.projectDirectory }
        let base = HistorySearch.owningProject(cwd: cwd, in: model.deck.projects)?.name
            ?? (HistorySearch.projectRoot(forCwd: cwd) as NSString).lastPathComponent
        return HistorySearch.worktree(of: cwd).map { "\(base) · \($0.name)" } ?? base
    }
}

private struct HistoryResultRow: View {
    @Environment(AppModel.self) private var model
    let result: HistorySearchResult
    let projectName: String

    private var isOpen: Bool { model.deck.sessions.contains { $0.claudeSessionID == result.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(result.title).font(.headline).lineLimit(1)
                if isOpen {
                    Image(systemName: "terminal").foregroundStyle(.secondary).help("Open in a ClaudeDeck session")
                }
                Spacer(minLength: 8)
                Text(result.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Label(projectName, systemImage: "folder").lineLimit(1)
                if result.matchCount > 1 {
                    Text("\(result.matchCount) matches")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(Array(result.snippets.enumerated()), id: \.offset) { _, snippet in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: snippet.role == "user" ? "person" : "sparkle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(highlighted(snippet))
                        .font(.callout)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func highlighted(_ snippet: HistorySnippet) -> AttributedString {
        var text = AttributedString(snippet.text)
        let chars = text.characters
        if snippet.matchStart + snippet.matchLength <= chars.count,
           let lower = chars.index(chars.startIndex, offsetBy: snippet.matchStart, limitedBy: chars.endIndex),
           let upper = chars.index(lower, offsetBy: snippet.matchLength, limitedBy: chars.endIndex) {
            text[lower..<upper].backgroundColor = .yellow.opacity(0.45)
            text[lower..<upper].font = .callout.bold()
        }
        return text
    }
}

/// File ▸ "Search History…" (⇧⌘H).
struct OpenHistorySearchButton: View {
    let model: AppModel

    var body: some View {
        Button("Search Conversation History…") { model.showHistorySearch() }
            .keyboardShortcut("h", modifiers: [.command, .shift])
        Button("Skills…") { model.showSkills() }
    }
}
