import ClaudeDeckCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebar.inactiveExpanded", store: .windowState) private var inactiveExpanded = true
    @AppStorage("sidebar.filter", store: .windowState) private var filter: SidebarFilter = .all
    @State private var layoutController = SidebarLayoutController()
    @State private var sidebarHeight: CGFloat = 600

    var body: some View {
        let latest = model.sidebarLayout(filter: filter)
        // Rows only move when the user caused it or isn't pointing at the sidebar (LayoutGate).
        let layout = layoutController.shown ?? latest
        let waiting = model.waitingSessions
        ScrollViewReader { proxy in
            list(layout)
                .onChange(of: latest, initial: true) { _, value in
                    layoutController.offer(value, userActionAt: model.lastUserLayoutAction)
                }
                .onChange(of: model.sidebarReveal) { _, request in
                    guard let request else { return }
                    reveal(request.id, proxy: proxy, latest: latest)
                }
        }
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Waiting tray above the footer, outside the list: it only shortens the list, never
            // pushes its rows around.
            VStack(spacing: 0) {
                if !waiting.isEmpty {
                    WaitingTray(sessions: waiting, maxHeight: sidebarHeight * 0.4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                UsageMeterFooter()
                footer
            }
            .animation(.snappy(duration: 0.3), value: waiting.isEmpty)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sidebarHeight = $0 }
        // The whole column (list, filter bar, tray) counts as "pointing at the sidebar".
        .onHover { layoutController.pointer(inside: $0) }
    }

    private func list(_ layout: SidebarLayout) -> some View {
        // Project header rows carry the project id as their tag: the list's own click handling
        // is the only reliable way to catch a click on a DisclosureGroup header.
        // The highlight is the last row the user clicked (project or session), not the terminal
        // that happens to be shown.
        List(selection: Binding(
            get: { model.sidebarSelection },
            set: { id in
                guard let id else { return }
                layoutController.click()
                if model.deck.project(id) != nil { model.openProject(id) } else { model.selectFromSidebar(id) }
            }
        )) {
            let pinned = layout.pinned.compactMap { model.deck.project($0) }
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { ProjectEntry(project: $0, layout: layout) }
                }
            }
            // Active: projects and groups with a running terminal, in the order they became active.
            // Status changes never reorder them; the status shows in place.
            Section {
                ForEach(layout.active, id: \.self) { SidebarItemView(item: $0, layout: layout) }
                if layout.active.isEmpty {
                    Text(filter == .waiting ? "Nothing is waiting for you" : "No running sessions")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            } header: {
                HStack(spacing: 4) {
                    Text("Active")
                    Text("\(layout.active.count)").foregroundStyle(.tertiary)
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
            // Hidden while a filter is on (nothing there is waiting or working).
            if filter == .all {
                Section(isExpanded: $inactiveExpanded) {
                    ForEach(layout.inactive, id: \.self) { SidebarItemView(item: $0, layout: layout) }
                } header: {
                    HStack(spacing: 4) {
                        Text("Inactive")
                        Text("\(layout.inactive.count)").foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var filterBar: some View {
        let counts = model.sidebarCounts
        return Picker("Show", selection: Binding(
            get: { filter },
            set: { value in
                model.noteUserLayoutAction()
                filter = value
            }
        )) {
            Text("All").tag(SidebarFilter.all)
            Text("Waiting \(counts.waiting)").tag(SidebarFilter.waiting)
            Text("Working \(counts.working)").tag(SidebarFilter.working)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .help("Show all projects, only sessions waiting for you, or only working sessions")
    }

    private var footer: some View {
        HStack {
            Button {
                model.presentAddProject()
            } label: {
                Label("Add Project", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            Button { model.showAutomations() } label: { Image(systemName: "clock.arrow.circlepath") }
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

    /// ⌘J / tray click: make sure the row is listed (a filter may hide it), then scroll to it.
    private func reveal(_ id: UUID, proxy: ScrollViewProxy, latest: SidebarLayout) {
        if filter != .all, !latest.sessionsInProject.values.contains(where: { $0.contains(id) }) {
            filter = .all
        }
        layoutController.offer(model.sidebarLayout(filter: filter), userActionAt: model.lastUserLayoutAction)
        Task { @MainActor in
            // Let the expanded project / group and the applied layout render first.
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
        }
    }
}

/// Holds the sidebar's rows steady: new layouts go through a `LayoutGate`, which applies them
/// at once after a user action and otherwise waits until the pointer has left the sidebar.
@MainActor
@Observable
final class SidebarLayoutController {
    private(set) var shown: SidebarLayout?
    @ObservationIgnored private var gate: LayoutGate<SidebarLayout>?
    @ObservationIgnored private var retry: Task<Void, Never>?

    func offer(_ latest: SidebarLayout, userActionAt: Date) {
        guard var next = gate else {
            gate = LayoutGate(latest)
            publish()
            return
        }
        next.userAction(at: userActionAt)
        next.offer(latest, at: Date())
        gate = next
        publish()
        scheduleRetry()
    }

    func pointer(inside: Bool) {
        gate?.pointer(inside: inside, at: Date())
        if !inside { scheduleRetry() }
    }

    func click() { gate?.click(at: Date()) }

    private func publish() {
        if shown != gate?.shown { shown = gate?.shown }
    }

    /// While a layout is held back, check every so often whether it may be applied.
    private func scheduleRetry() {
        guard gate?.pending != nil, retry == nil else { return }
        retry = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                self.gate?.tick(at: Date())
                self.publish()
                if self.gate?.pending == nil {
                    self.retry = nil
                    return
                }
            }
        }
    }
}

/// A top-level entry of the Active / Inactive sections.
struct SidebarItemView: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem
    let layout: SidebarLayout

    var body: some View {
        switch item {
        case .project(let id):
            if let project = model.deck.project(id) { ProjectEntry(project: project, layout: layout) }
        case .group(let id):
            if let group = model.deck.groups.first(where: { $0.id == id }) {
                GroupRow(group: group, projects: (layout.projectsInGroup[id] ?? []).compactMap { model.deck.project($0) }, layout: layout)
            }
        }
    }
}

/// A project as one row (its only session) or as a header with its sessions.
struct ProjectEntry: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let layout: SidebarLayout

    var body: some View {
        let sessions = (layout.sessionsInProject[project.id] ?? []).compactMap { model.deck.session($0) }
        if layout.compact.contains(project.id), let session = sessions.first {
            CompactProjectRow(project: project, session: session)
        } else {
            ProjectRow(project: project, sessions: sessions)
        }
    }
}

struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: ProjectGroup
    let projects: [Project]
    let layout: SidebarLayout
    @State private var pickingProjects = false

    var body: some View {
        // Only the user opens or closes a group (opening it by itself would move rows under the
        // pointer); the badges show what's going on inside while it's closed.
        DisclosureGroup(isExpanded: Binding(
            get: { !group.collapsed },
            set: { expanded in model.mutate { $0.updateGroup(group.id) { $0.collapsed = !expanded } } }
        )) {
            ForEach(projects) { ProjectEntry(project: $0, layout: layout) }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(GroupPalette.color(group.colorIndex)).frame(width: 8, height: 8)
                Text(group.name).fontWeight(.medium)
                Spacer()
                AggregateBadge(sessionIDs: model.deck.projects.filter { $0.groupID == group.id && !$0.pinned }
                    .flatMap { model.deck.sessions(in: $0.id).map(\.id) })
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
    /// The sessions to list (the sidebar filter may hide some).
    let sessions: [DeckSession]
    @State private var showResume = false

    var body: some View {
        let all = model.deck.sessions(in: project.id)
        let active = all.contains { model.terminals.isRunning($0.id) }
        // Projects without a running session start collapsed; with one, the saved state applies.
        // Only the user opens or closes it (the waiting tray lists sessions that need them).
        DisclosureGroup(isExpanded: Binding(
            get: { active ? !project.collapsed : model.idleExpandedProjects.contains(project.id) },
            set: { expanded in
                model.noteUserLayoutAction()
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
                if project.collapsed || !active { AggregateBadge(sessionIDs: all.map(\.id)) }
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

/// A project with a single session, as one row: the session's status with the project's name.
/// Its context menu has the session's items and the project's under "Project".
struct CompactProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let session: DeckSession
    @State private var showResume = false
    @State private var hovering = false

    var body: some View {
        let status = model.status(of: session.id)
        let unseen = model.isUnseenIdle(session.id)
        HStack(spacing: 8) {
            StatusDot(display: status.display, unseen: unseen)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if session.kind == .shell {
                        Image(systemName: "apple.terminal").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(project.name).fontWeight(.medium).lineLimit(1)
                    if let extra = Self.extraName(session: session.name, project: project.name) {
                        Text(extra).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if project.pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
                    }
                    GitHubLinkBadge(session: session)
                    Spacer(minLength: 4)
                    if hovering {
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
                    RowTime(date: status.updatedAt)
                }
                SessionStatusLine(session: session, status: status, unseen: unseen)
            }
        }
        .padding(.vertical, 2)
        .flashOnStateChange(status.display)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedSessionID = session.id }
        .onHover { hovering = $0 }
        .help(project.path)
        .contextMenu {
            SessionMenu(session: session)
            Divider()
            Menu("Project") { ProjectMenu(project: project, showResume: $showResume) }
        }
        .onDrag {
            model.draggedSessionID = session.id
            model.lastDraggedSessionID = session.id
            return NSItemProvider(object: session.id.uuidString as NSString)
        }
        .sheet(isPresented: $showResume) { ResumeSheet(project: project) }
        .tag(session.id)
        .id(session.id)
    }

    /// The session's name when it says more than the project's ("app · fix login" → "fix login");
    /// nil for the default names ("app", "app · 2").
    static func extraName(session: String, project: String) -> String? {
        guard session != project else { return nil }
        guard session.hasPrefix(project) else { return session }
        let rest = session.dropFirst(project.count).trimmingCharacters(in: CharacterSet(charactersIn: " ·-–—:").union(.whitespaces))
        if rest.isEmpty || rest.allSatisfy(\.isNumber) { return nil }
        return rest
    }
}

/// The waiting tray docked at the bottom of the sidebar: sessions that need the user, with
/// the permission buttons. Collapsible; scrolls on its own beyond `maxHeight`.
struct WaitingTray: View {
    @AppStorage("sidebar.trayCollapsed", store: .windowState) private var collapsed = false
    let sessions: [DeckSession]
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0
    @Environment(AppModel.self) private var model

    var body: some View {
        let blocked = sessions.contains { model.status(of: $0.id).display.isBlocked }
        VStack(spacing: 0) {
            Divider()
            Button {
                withAnimation(.snappy(duration: 0.25)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(blocked ? StatusStyle.blocked : StatusStyle.idle)
                    Text("Waiting for you · \(sessions.count)").font(.callout.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .help("Next session waiting for you: ⌘J")
            if !collapsed {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sessions) { WaitingRow(session: $0) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(contentHeight, 1), max(maxHeight, 80)))
            }
        }
        .background(.bar)
        .animation(.snappy(duration: 0.25), value: sessions.map(\.id))
    }
}

/// A session that needs the user, with its project and what it is waiting for.
struct WaitingRow: View {
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
            RowTime(date: status.updatedAt)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(status.display.isBlocked ? StatusStyle.blocked.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .flashOnStateChange(status.display)
        .contentShape(Rectangle())
        .onTapGesture { model.revealInSidebar(session.id) }
        .contextMenu { SessionMenu(session: session) }
        .onDrag {
            model.draggedSessionID = session.id
            model.lastDraggedSessionID = session.id
            return NSItemProvider(object: session.id.uuidString as NSString)
        }
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession

    var body: some View {
        let status = model.status(of: session.id)
        let unseen = model.isUnseenIdle(session.id)
        HStack(spacing: 8) {
            StatusDot(display: status.display, unseen: unseen)
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
                    GitHubLinkBadge(session: session)
                    Spacer(minLength: 4)
                    RowTime(date: status.updatedAt)
                }
                SessionStatusLine(session: session, status: status, unseen: unseen)
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
        .id(session.id)
    }
}

/// Status pill, shell badge and detail under a session's name. A seen "your turn" gets no pill
/// (its hollow dot says enough), so only what needs the user stands out.
struct SessionStatusLine: View {
    let session: DeckSession
    let status: SessionStatus
    let unseen: Bool

    var body: some View {
        let quiet = status.display.isIdle && !unseen
        let detail = status.detail ?? session.startupCommand.map { "▶︎ " + $0 }
        let hasBadge = session.kind == .shell && session.startupCommand != nil
        if !quiet || hasBadge || detail != nil {
            HStack(spacing: 6) {
                if !quiet { StatusPill(display: status.display, unseen: unseen) }
                ShellStartBadge(session: session)
                if let detail {
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
}

/// "3m" next to a row, refreshed every 15 seconds.
struct RowTime: View {
    let date: Date?

    var body: some View {
        if let date {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                Text(RelativeTime.short(date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
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
            Button(session.kind == .shell ? String(localized: "Restart Terminal") : String(localized: "Restart Session")) {
                Task { await model.restartSession(session.id) }
            }
            .disabled(!model.canRestart(session.id))
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
        GitHubLinkMenuItems(session: session)
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
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        }
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
