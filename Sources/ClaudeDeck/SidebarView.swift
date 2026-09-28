import ClaudeDeckCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let sections = model.deck.sections
        let waiting = model.attentionSessions
        List(selection: $model.selectedSessionID) {
            if !waiting.isEmpty {
                Section("Bekleyenler") {
                    ForEach(waiting) { session in
                        // No selection tag: the same session is also listed under its project.
                        AttentionRow(session: session)
                    }
                }
            }
            if !sections.pinned.isEmpty {
                Section("Sabitlenenler") {
                    ForEach(sections.pinned) { ProjectRow(project: $0) }
                }
            }
            if !sections.groups.isEmpty {
                Section("Gruplar") {
                    ForEach(sections.groups, id: \.group.id) { entry in
                        GroupRow(group: entry.group, projects: entry.projects)
                    }
                }
            }
            Section {
                ForEach(sections.ungrouped) { ProjectRow(project: $0) }
            } header: {
                HStack {
                    Text("Projeler")
                    Spacer()
                    Button {
                        model.presentAddProject()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Proje ekle (⌘O)")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.presentAddProject()
                } label: {
                    Label("Proje ekle", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Ayarlar — otomatik devam, /compact, bildirimler (⌘,)")
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

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { !group.collapsed },
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
            }
            .contextMenu { GroupMenu(group: group) }
        }
    }
}

struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var showResume = false

    /// Clicking a project opens its most recently active session, or toggles it when empty.
    private func openProject(_ sessions: [DeckSession]) {
        let recent = sessions.max { ($0.lastActivityAt ?? $0.createdAt) < ($1.lastActivityAt ?? $1.createdAt) }
        if let recent {
            if project.collapsed { model.mutate { $0.updateProject(project.id) { $0.collapsed = false } } }
            model.selectedSessionID = recent.id
        } else {
            model.mutate { $0.updateProject(project.id) { $0.collapsed.toggle() } }
        }
    }

    var body: some View {
        let sessions = model.deck.sessions(in: project.id)
        DisclosureGroup(isExpanded: Binding(
            get: { !project.collapsed },
            set: { expanded in model.mutate { $0.updateProject(project.id) { $0.collapsed = !expanded } } }
        )) {
            ForEach(sessions) { session in
                SessionRow(session: session).tag(session.id)
            }
            HStack(spacing: 14) {
                Button {
                    model.newSession(in: project.id)
                } label: {
                    Label("Yeni Claude oturumu", systemImage: "plus")
                }
                Button {
                    model.newShell(in: project.id)
                } label: {
                    Label("Terminal", systemImage: "apple.terminal")
                }
                .help("Proje klasöründe boş terminal aç (⌥⌘T)")
            }
            .font(.callout)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: project.pinned ? "pin.fill" : "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(project.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 4)
                if project.collapsed { AggregateBadge(sessionIDs: sessions.map(\.id)) }
                Button {
                    model.newShell(in: project.id)
                } label: {
                    Image(systemName: "apple.terminal")
                }
                .buttonStyle(.borderless)
                .help("Proje klasöründe boş terminal aç")
                Button {
                    model.newSession(in: project.id)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Yeni Claude oturumu")
            }
            .help(project.path)
            .contentShape(Rectangle())
            .onTapGesture { openProject(sessions) }
            .contextMenu { ProjectMenu(project: project, showResume: $showResume) }
        }
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
        .onDrag { NSItemProvider(object: session.id.uuidString as NSString) }
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
        .onDrag { NSItemProvider(object: session.id.uuidString as NSString) }
    }
}

/// Right-click menu for a session — same in the sidebar, the waiting list and the menu bar.
struct SessionMenu: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession

    var body: some View {
        if let stamp = model.pendingPermissionStamp(session.id) {
            Button("İzin ver") { model.approvePermission(session.id, expectedAt: stamp) }
            Button("Reddet") { model.denyPermission(session.id, expectedAt: stamp) }
            Divider()
        }
        if !model.deck.visiblePanes.contains(session.id) {
            Button("Yanına aç") { model.openBeside(session.id) }
        } else if model.deck.panes.count > 1 {
            Button("Bölmeyi kapat") { model.closePane(session.id) }
        }
        Divider()
        if model.terminals.isRunning(session.id) {
            Button(session.kind == .shell ? "Terminali kapat" : "Oturumu bitir") { model.stop(session.id) }
        } else if session.kind == .shell {
            Button("Yeniden aç") { model.launch(session.id, resume: false); model.selectedSessionID = session.id }
        } else {
            Button("Devam et") { model.launch(session.id, resume: true); model.selectedSessionID = session.id }
            Button("Yeni başlat") { model.launch(session.id, resume: false); model.selectedSessionID = session.id }
        }
        if session.kind == .shell {
            Divider()
            Button(session.startupCommand == nil ? "Başlangıç komutu…" : "Başlangıç komutu: \(session.startupCommand!)…") {
                if let command = TextPrompt.ask(
                    title: "Terminal açılınca çalışacak komut",
                    placeholder: "yarn start (boş bırak = yok)",
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
                Toggle("Uygulama açılınca otomatik başlat", isOn: Binding(
                    get: { session.autoStart },
                    set: { value in model.mutate { $0.updateSession(session.id) { $0.autoStart = value } } }
                ))
            }
        }
        Divider()
        Button("Yeniden adlandır…") {
            if let name = TextPrompt.ask(title: "Oturumu yeniden adlandır", placeholder: "Ad", initial: session.name) {
                model.renameSession(session.id, to: name)
            }
        }
        Divider()
        Button("Bitir ve listeden kaldır", role: .destructive) { model.removeSession(session.id) }
    }
}

struct ProjectMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Binding var showResume: Bool

    var body: some View {
        Button("Yeni Claude oturumu") { model.newSession(in: project.id) }
        Button("Yeni terminal") { model.newShell(in: project.id) }
        Button("Yeni terminal (komutla)…") {
            if let command = TextPrompt.ask(title: "Açılışta çalışacak komut", placeholder: "yarn start") {
                model.newCommandShell(in: project.id, command: command)
            }
        }
        Button("Eski oturumu devam ettir…") { showResume = true }
        let projectSessions = model.deck.sessions(in: project.id)
        if projectSessions.count > 1 {
            Button("Oturumlarını yan yana aç") {
                for s in projectSessions.prefix(DeckData.maxPanes) where !model.deck.visiblePanes.contains(s.id) {
                    model.openBeside(s.id, anchor: model.deck.panes.last)
                }
            }
        }
        let running = projectSessions.filter { model.terminals.isRunning($0.id) }
        if !running.isEmpty {
            Button("Tüm oturumları bitir (\(running.count))") { running.forEach { model.stop($0.id) } }
        }
        Divider()
        Button(project.pinned ? "Sabitlemeyi kaldır" : "Sabitle") {
            model.mutate { $0.updateProject(project.id) { $0.pinned.toggle() } }
        }
        Menu("Gruba taşı") {
            ForEach(model.deck.groups) { group in
                Button(group.name) { model.mutate { $0.updateProject(project.id) { $0.groupID = group.id } } }
            }
            if project.groupID != nil {
                Button("Gruptan çıkar") { model.mutate { $0.updateProject(project.id) { $0.groupID = nil } } }
            }
            Divider()
            Button("Yeni grup…") {
                if let name = TextPrompt.ask(title: "Yeni grup", placeholder: "Grup adı") {
                    model.mutate {
                        let g = $0.addGroup(name: name)
                        $0.updateProject(project.id) { $0.groupID = g.id }
                    }
                }
            }
        }
        Button("Yeniden adlandır…") {
            if let name = TextPrompt.ask(title: "Projeyi yeniden adlandır", placeholder: "Ad", initial: project.name) {
                model.mutate { $0.updateProject(project.id) { $0.name = name } }
            }
        }
        Button("Finder'da göster") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
        if VSCode.isInstalled {
            Button("VS Code'da aç") { VSCode.open(URL(fileURLWithPath: project.path)) }
        }
        Divider()
        Button("Projeyi kaldır", role: .destructive) { model.removeProject(project.id) }
    }
}

struct GroupMenu: View {
    @Environment(AppModel.self) private var model
    let group: ProjectGroup

    var body: some View {
        Button("Yeniden adlandır…") {
            if let name = TextPrompt.ask(title: "Grubu yeniden adlandır", placeholder: "Ad", initial: group.name) {
                model.mutate { $0.updateGroup(group.id) { $0.name = name } }
            }
        }
        Menu("Renk") {
            ForEach(0..<GroupPalette.count, id: \.self) { i in
                Button(GroupPalette.names[i]) { model.mutate { $0.updateGroup(group.id) { $0.colorIndex = i } } }
            }
        }
        Divider()
        Button("Grubu sil", role: .destructive) { model.mutate { $0.removeGroup(group.id) } }
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
        alert.addButton(withTitle: "Kaydet")
        alert.addButton(withTitle: "Vazgeç")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty && !allowEmpty ? nil : value
    }
}
