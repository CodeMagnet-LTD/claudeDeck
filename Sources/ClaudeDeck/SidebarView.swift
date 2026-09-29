import ClaudeDeckCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebar.inactiveExpanded") private var inactiveExpanded = true

    var body: some View {
        @Bindable var model = model
        let sections = model.deck.sections
        let waiting = model.attentionSessions
        // Project header rows carry the project id as their tag: the list's own click handling
        // is the only reliable way to catch a click on a DisclosureGroup header.
        // The highlight is the last row the user clicked (project or session), not the terminal
        // that happens to be shown.
        List(selection: Binding(
            get: { model.sidebarSelection },
            set: { id in
                guard let id else { return }
                if model.deck.project(id) != nil { model.openProject(id) } else { model.selectFromSidebar(id) }
            }
        )) {
            if !waiting.isEmpty {
                Section("Needs Attention") {
                    ForEach(waiting) { session in
                        // No selection tag: the same session is also listed under its project.
                        AttentionRow(session: session)
                    }
                }
            }
            if !sections.pinned.isEmpty {
                Section("Pinned") {
                    ForEach(sections.pinned) { ProjectRow(project: $0) }
                }
            }
            // Active: projects with a running terminal, in the order they became active (stable),
            // then groups that contain an active project.
            let activeProjects = model.activeInOrder(sections.ungrouped)
            let activeGroups = model.activeGroupsInOrder(sections.groups)
            let _ = model.pruneActivationOrder()
            Section {
                ForEach(activeProjects) { ProjectRow(project: $0) }
                ForEach(activeGroups, id: \.group.id) { entry in
                    GroupRow(group: entry.group, projects: entry.projects)
                }
                if activeProjects.isEmpty && activeGroups.isEmpty {
                    Text("No running sessions").font(.callout).foregroundStyle(.tertiary)
                }
            } header: {
                HStack {
                    Text("Active")
                    Spacer()
                    Menu {
                        Button("Add Project…") { model.presentAddProject() }
                        Button("New Group…") {
                            if let name = TextPrompt.ask(title: String(localized: "New Group"), placeholder: String(localized: "Group name")) {
                                model.mutate { $0.addGroup(name: name) }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add project / new group")
                }
            }
            // Inactive: everything else in its saved order, collapsible like an accordion.
            let activeGroupIDs = Set(activeGroups.map(\.group.id))
            let idleGroups = sections.groups.filter { !activeGroupIDs.contains($0.group.id) }
            let idleProjects = sections.ungrouped.filter { !model.isActive($0) }
            Section(isExpanded: $inactiveExpanded) {
                ForEach(idleGroups, id: \.group.id) { entry in
                    GroupRow(group: entry.group, projects: entry.projects)
                }
                ForEach(idleProjects) { ProjectRow(project: $0) }
            } header: {
                HStack(spacing: 4) {
                    Text("Inactive")
                    Text("\(idleGroups.count + idleProjects.count)").foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.presentAddProject()
                } label: {
                    Label("Add Project", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                Button { openWindow(id: "automations") } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(.borderless)
                    .help("Automations — scheduled prompts")
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings — auto-resume, /compact, notifications (⌘,)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: ProjectGroup
    let projects: [Project]
    @State private var pickingProjects = false

    var body: some View {
        // A session waiting for the user forces its group open.
        let attention = projects.contains { p in model.deck.sessions(in: p.id).contains { model.needsAttention($0.id) } }
        DisclosureGroup(isExpanded: Binding(
            get: { !group.collapsed || attention },
            set: { expanded in model.mutate { $0.updateGroup(group.id) { $0.collapsed = !expanded } } }
        )) {
            ForEach(projects) { ProjectRow(project: $0) }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(GroupPalette.color(group.colorIndex)).frame(width: 8, height: 8)
                Text(group.name).fontWeight(.medium)
                Spacer()
                AggregateBadge(sessionIDs: projects.flatMap { model.deck.sessions(in: $0.id).map(\.id) })
                Text("\(projects.count)").font(.caption).foregroundStyle(.tertiary)
                Menu {
                    Button("Add Project to This Group…") { model.presentAddProject(toGroup: group.id) }
                    Button("Choose Projects…") { pickingProjects = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add projects to the group")
            }
            .contextMenu { GroupMenu(group: group, pickingProjects: $pickingProjects) }
            .sheet(isPresented: $pickingProjects) { GroupProjectsSheet(group: group) }
            // Only the title row is tinted (on the DisclosureGroup it would tint every child row).
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6)
                    .fill(GroupPalette.color(group.colorIndex).opacity(0.16))
                    .padding(.horizontal, 4)
            )
        }
    }
}

struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var showResume = false

    var body: some View {
        let sessions = model.deck.sessions(in: project.id)
        let active = sessions.contains { model.terminals.isRunning($0.id) }
        let attention = sessions.contains { model.needsAttention($0.id) }
        // Projects without a running session start collapsed; with one, the saved state applies.
        // A session waiting for the user (permission, question, unseen finish) forces it open.
        DisclosureGroup(isExpanded: Binding(
            get: { attention || (active ? !project.collapsed : model.idleExpandedProjects.contains(project.id)) },
            set: { expanded in
                if active {
                    model.mutate { $0.updateProject(project.id) { $0.collapsed = !expanded } }
                } else {
                    if expanded { model.idleExpandedProjects.insert(project.id) } else { model.idleExpandedProjects.remove(project.id) }
                }
            }
        )) {
            ForEach(sessions) { session in
                SessionRow(session: session).tag(session.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: project.pinned ? "pin.fill" : "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(project.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 4)
                if project.collapsed || !active { AggregateBadge(sessionIDs: sessions.map(\.id)) }
                // One "+" with every way to start something in this project.
                Menu {
                    NewSessionItems(project: project, showResume: $showResume)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New Claude session or terminal")
            }
            .help(project.path)
            .contentShape(Rectangle())
            .contextMenu { ProjectMenu(project: project, showResume: $showResume) }
        }
        .tag(project.id)
        .sheet(isPresented: $showResume) { ResumeSheet(project: project) }
    }
}

/// A session that needs the user, with its project and what it is waiting for.
struct AttentionRow: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession

    var body: some View {
        let status = model.status(of: session.id)
        let project = model.deck.project(session.projectID)?.name ?? ""
        HStack(alignment: .top, spacing: 8) {
            StatusDot(display: status.display, unseen: model.isUnseenIdle(session.id))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.name).fontWeight(.semibold).lineLimit(1)
                    if !session.name.hasPrefix(project) {
                        Text(project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                StatusPill(display: status.display, unseen: true)
                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                PermissionButtons(sessionID: session.id).padding(.top, 2)
            }
            Spacer(minLength: 4)
            if let at = status.updatedAt {
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(RelativeTime.short(at)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
        .flashOnStateChange(status.display)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedSessionID = session.id }
        .contextMenu { SessionMenu(session: session) }
        .onDrag {
            model.draggedSessionID = session.id
            model.lastDraggedSessionID = session.id
            return NSItemProvider(object: session.id.uuidString as NSString)
        }
        .listRowBackground(
            status.display.isBlocked
                ? RoundedRectangle(cornerRadius: 6).fill(StatusStyle.blocked.opacity(0.12)).padding(.horizontal, 4)
                : nil
        )
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession

    var body: some View {
        let status = model.status(of: session.id)
        HStack(spacing: 8) {
            StatusDot(display: status.display, unseen: model.isUnseenIdle(session.id))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if session.kind == .shell {
                        Image(systemName: "apple.terminal").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(session.name).lineLimit(1)
                    if let worktree = session.worktreeName {
                        Label(worktree, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Separate git worktree: \(session.workingDirectory ?? worktree)")
                    }
                    Spacer(minLength: 4)
                    if let at = status.updatedAt {
                        TimelineView(.periodic(from: .now, by: 15)) { _ in
                            Text(RelativeTime.short(at))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                HStack(spacing: 6) {
                    StatusPill(display: status.display, unseen: model.isUnseenIdle(session.id))
                    ShellStartBadge(session: session)
                    if let detail = status.detail ?? session.startupCommand.map({ "▶︎ " + $0 }) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .id(detail)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.25), value: status.detail)
                .clipped()
            }
        }
        .padding(.vertical, 3)
        .flashOnStateChange(status.display)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedSessionID = session.id }
        .contextMenu { SessionMenu(session: session) }
        .onDrag {
            model.draggedSessionID = session.id
            model.lastDraggedSessionID = session.id
            return NSItemProvider(object: session.id.uuidString as NSString)
        }
    }
}

/// Right-click menu for a session — same in the sidebar, the waiting list and the menu bar.
struct SessionMenu: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession

    var body: some View {
        if let stamp = model.pendingPermissionStamp(session.id) {
            Button("Allow") { model.approvePermission(session.id, expectedAt: stamp) }
            Button("Deny") { model.denyPermission(session.id, expectedAt: stamp) }
            Divider()
        }
        if !model.deck.visiblePanes.contains(session.id) {
            Button("Open Beside") { model.openBeside(session.id) }
        } else if model.deck.panes.count > 1 {
            Button("Close Pane") { model.closePane(session.id) }
        }
        Divider()
        if model.terminals.isRunning(session.id) {
            Button(session.kind == .shell ? String(localized: "Close Terminal") : String(localized: "End Session")) { model.stop(session.id) }
        } else if session.kind == .shell {
            Button("Reopen") { model.launch(session.id, resume: false); model.selectedSessionID = session.id }
        } else {
            Button("Resume") { model.launch(session.id, resume: true); model.selectedSessionID = session.id }
            Button("Start Fresh") { model.launch(session.id, resume: false); model.selectedSessionID = session.id }
        }
        if session.kind == .shell {
            Divider()
            Button(session.startupCommand == nil ? String(localized: "Startup Command…") : String(localized: "Startup Command: \(session.startupCommand!)…")) {
                if let command = TextPrompt.ask(
                    title: String(localized: "Command to run when the terminal opens"),
                    placeholder: String(localized: "yarn start (leave empty for none)"),
                    initial: session.startupCommand ?? "",
                    allowEmpty: true
                ) {
                    model.mutate {
                        $0.updateSession(session.id) {
                            $0.startupCommand = command.isEmpty ? nil : command
                            if command.isEmpty { $0.autoStart = false } else if session.startupCommand == nil { $0.autoStart = true }
                        }
                    }
                }
            }
            if session.startupCommand != nil {
                Toggle("Start Automatically When the App Opens", isOn: Binding(
                    get: { session.autoStart },
                    set: { value in model.mutate { $0.updateSession(session.id) { $0.autoStart = value } } }
                ))
            }
        }
        Divider()
        Button("Rename…") {
            if let name = TextPrompt.ask(title: String(localized: "Rename Session"), placeholder: String(localized: "Name"), initial: session.name) {
                model.renameSession(session.id, to: name)
            }
        }
        Divider()
        Button("End and Remove…", role: .destructive) {
            if Confirm.ask(String(localized: "End \"\(session.name)\" and remove it from the list?"),
                           detail: String(localized: "The running process is stopped. The Claude conversation history is kept and can be reopened from the project's \"Resume Previous Conversation…\" menu."),
                           action: String(localized: "End and Remove")) {
                model.removeSession(session.id)
            }
        }
    }
}

struct ProjectMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Binding var showResume: Bool

    var body: some View {
        NewSessionItems(project: project, showResume: $showResume)
        let projectSessions = model.deck.sessions(in: project.id)
        if projectSessions.count > 1 {
            Button("Open Sessions Side by Side") {
                for s in projectSessions.prefix(DeckData.maxPanes) where !model.deck.visiblePanes.contains(s.id) {
                    model.openBeside(s.id, anchor: model.deck.panes.last)
                }
            }
        }
        let running = projectSessions.filter { model.terminals.isRunning($0.id) }
        if !running.isEmpty {
            Button("End All Sessions (\(running.count))") { running.forEach { model.stop($0.id) } }
        }
        Divider()
        Button(project.pinned ? String(localized: "Unpin") : String(localized: "Pin")) {
            model.mutate { $0.updateProject(project.id) { $0.pinned.toggle() } }
        }
        Menu("Move to Group") {
            ForEach(model.deck.groups) { group in
                Button(group.name) { model.mutate { $0.updateProject(project.id) { $0.groupID = group.id } } }
            }
            if project.groupID != nil {
                Button("Remove from Group") { model.mutate { $0.updateProject(project.id) { $0.groupID = nil } } }
            }
            Divider()
            Button("New Group…") {
                if let name = TextPrompt.ask(title: String(localized: "New Group"), placeholder: String(localized: "Group name")) {
                    model.mutate {
                        let g = $0.addGroup(name: name)
                        $0.updateProject(project.id) { $0.groupID = g.id }
                    }
                }
            }
        }
        Button("Rename…") {
            if let name = TextPrompt.ask(title: String(localized: "Rename Project"), placeholder: String(localized: "Name"), initial: project.name) {
                model.mutate { $0.updateProject(project.id) { $0.name = name } }
            }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
        if VSCode.isInstalled {
            Button("Open in VS Code") { VSCode.open(URL(fileURLWithPath: project.path)) }
        }
        Divider()
        Button("Remove Project…", role: .destructive) {
            let count = model.deck.sessions(in: project.id).count
            if Confirm.ask(String(localized: "Remove \"\(project.name)\" from the list?"),
                           detail: (count > 0 ? String(localized: "Its \(count) sessions are ended and removed. ") : "") + String(localized: "The folder and its files are not touched."),
                           action: String(localized: "Remove")) {
                model.removeProject(project.id)
            }
        }
    }
}

struct GroupMenu: View {
    @Environment(AppModel.self) private var model
    let group: ProjectGroup
    @Binding var pickingProjects: Bool

    var body: some View {
        Button("Choose Projects…") { pickingProjects = true }
        Divider()
        Button("Rename…") {
            if let name = TextPrompt.ask(title: String(localized: "Rename Group"), placeholder: String(localized: "Name"), initial: group.name) {
                model.mutate { $0.updateGroup(group.id) { $0.name = name } }
            }
        }
        Menu("Color") {
            ForEach(0..<GroupPalette.count, id: \.self) { i in
                Button(GroupPalette.names[i]) { model.mutate { $0.updateGroup(group.id) { $0.colorIndex = i } } }
            }
        }
        Divider()
        Button("Delete Group…", role: .destructive) {
            if Confirm.ask(String(localized: "Delete the group \"\(group.name)\"?"), detail: String(localized: "Its projects are not deleted; they just leave the group."), action: String(localized: "Delete Group")) {
                model.mutate { $0.removeGroup(group.id) }
            }
        }
    }
}

/// Small modal text prompt (context menus can't host SwiftUI alerts reliably).
enum TextPrompt {
    @MainActor
    /// Returns nil on cancel; "" only when `allowEmpty` (e.g. clearing a value).
    static func ask(title: String, placeholder: String, initial: String = "", allowEmpty: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runAsSheet() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty && !allowEmpty ? nil : value
    }
}

/// Checklist to assign many projects to a group at once.
struct GroupProjectsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: ProjectGroup
    @State private var chosen: Set<UUID> = []
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(group.name) — Projects").font(.headline)
            TextField("Search", text: $filter).textFieldStyle(.roundedBorder)
            List {
                ForEach(visibleProjects) { project in
                    Toggle(isOn: Binding(
                        get: { chosen.contains(project.id) },
                        set: { on in if on { chosen.insert(project.id) } else { chosen.remove(project.id) } }
                    )) {
                        HStack {
                            Text(project.name)
                            if let other = project.groupID, other != group.id, let name = model.deck.groups.first(where: { $0.id == other })?.name {
                                Text(name).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(project.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        }
                    }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Button("Select All") { chosen.formUnion(visibleProjects.map(\.id)) }
                Button("None") { chosen.subtract(visibleProjects.map(\.id)) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
        .onAppear { chosen = Set(model.deck.projects.filter { $0.groupID == group.id }.map(\.id)) }
    }

    private var visibleProjects: [Project] {
        let all = model.deck.projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !filter.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.path.localizedCaseInsensitiveContains(filter) }
    }

    private func save() {
        model.mutate { deck in
            for project in deck.projects {
                if chosen.contains(project.id) {
                    deck.updateProject(project.id) { $0.groupID = group.id }
                } else if project.groupID == group.id {
                    deck.updateProject(project.id) { $0.groupID = nil }
                }
            }
        }
        dismiss()
    }
}

/// "Are you sure?" confirmation for destructive actions.
enum Confirm {
    @MainActor
    static func ask(_ title: String, detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runAsSheet() == .alertFirstButtonReturn
    }
}


/// Everything that can be started in a project — shared by the project's "+" menu and its
/// right-click menu so both offer the same choices.
struct NewSessionItems: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Binding var showResume: Bool

    var body: some View {
        Button {
            model.newSession(in: project.id)
        } label: {
            Label("New Claude Session", systemImage: "sparkles")
        }
        Button {
            model.promptWorktreeSession(in: project)
        } label: {
            Label("New Claude Session (Separate Worktree)…", systemImage: "arrow.triangle.branch")
        }
        .disabled(!model.isGitRepository(project))
        Button {
            showResume = true
        } label: {
            Label("Resume Previous Conversation…", systemImage: "clock.arrow.circlepath")
        }
        Divider()
        Button {
            model.newShell(in: project.id)
        } label: {
            Label("New Terminal", systemImage: "apple.terminal")
        }
        Button {
            if let command = TextPrompt.ask(title: String(localized: "Command to run on open"), placeholder: "yarn start") {
                model.newCommandShell(in: project.id, command: command)
            }
        } label: {
            Label("New Terminal with Command…", systemImage: "bolt")
        }
    }
}
