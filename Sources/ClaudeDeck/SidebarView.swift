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
                        AttentionRow(session: session).tag(session.id)
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
            Section("Projeler") {
                ForEach(sections.ungrouped) { ProjectRow(project: $0) }
                if model.deck.projects.isEmpty {
                    Button {
                        model.presentAddProject()
                    } label: {
                        Label("Proje ekle…", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
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
        }
        .contextMenu { GroupMenu(group: group) }
    }
}

struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var showResume = false

    var body: some View {
        let sessions = model.deck.sessions(in: project.id)
        DisclosureGroup(isExpanded: Binding(
            get: { !project.collapsed },
            set: { expanded in model.mutate { $0.updateProject(project.id) { $0.collapsed = !expanded } } }
        )) {
            ForEach(sessions) { session in
                SessionRow(session: session).tag(session.id)
            }
            Button {
                model.newSession(in: project.id)
            } label: {
                Label("Yeni Claude oturumu", systemImage: "plus")
                    .font(.callout)
            }
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
                    model.newSession(in: project.id)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Yeni Claude oturumu")
            }
            .help(project.path)
        }
        .contextMenu { ProjectMenu(project: project, showResume: $showResume) }
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
                Text(AttentionText.headline(status.display))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(StatusStyle.color(for: status.display))
                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if let at = status.updatedAt {
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(RelativeTime.short(at)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
        .listRowBackground(
            status.display.isBlocked
                ? RoundedRectangle(cornerRadius: 6).fill(StatusStyle.blocked.opacity(0.12)).padding(.horizontal, 4)
                : nil
        )
    }
}

enum AttentionText {
    static func headline(_ display: DisplayState) -> String {
        switch display {
        case .activity(.needsPermission): "İzin istiyor"
        case .activity(.needsAnswer): "Soru soruyor"
        case .activity(.idle): "Bitti — sıra sende"
        default: ""
        }
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession
    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        let status = model.status(of: session.id)
        HStack(spacing: 8) {
            StatusDot(display: status.display, unseen: model.isUnseenIdle(session.id))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name).lineLimit(1)
                if let detail = status.detail ?? label(for: status.display) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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
        .padding(.vertical, 2)
        .contextMenu {
            if model.terminals.isRunning(session.id) {
                Button("Oturumu bitir") { model.stop(session.id) }
            } else {
                Button("Devam et") { model.launch(session.id, resume: true); model.selectedSessionID = session.id }
                Button("Yeni başlat") { model.launch(session.id, resume: false); model.selectedSessionID = session.id }
            }
            Divider()
            Button("Yeniden adlandır…") { draft = session.name; renaming = true }
            Divider()
            Button("Bitir ve listeden kaldır", role: .destructive) { model.removeSession(session.id) }
        }
        .alert("Oturumu yeniden adlandır", isPresented: $renaming) {
            TextField("Ad", text: $draft)
            Button("Kaydet") { model.renameSession(session.id, to: draft) }
            Button("Vazgeç", role: .cancel) {}
        }
    }

    private func label(for display: DisplayState) -> String? {
        switch display {
        case .notStarted: "Durdu"
        case .starting: "Başlıyor…"
        case .activity(.running): "Çalışıyor"
        case .activity(.needsPermission): "İzin bekliyor"
        case .activity(.needsAnswer): "Cevap bekliyor"
        case .activity(.idle): "Sıra sende"
        case .activity(.ended): "Bitti"
        }
    }
}

struct ProjectMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Binding var showResume: Bool

    var body: some View {
        Button("Yeni Claude oturumu") { model.newSession(in: project.id) }
        Button("Eski oturumu devam ettir…") { showResume = true }
        let running = model.deck.sessions(in: project.id).filter { model.terminals.isRunning($0.id) }
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
    static func ask(title: String, placeholder: String, initial: String = "") -> String? {
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
        return value.isEmpty ? nil : value
    }
}
