import ClaudeDeckCore
import SwiftUI

/// How the main window shows its sidebar: the full list, a narrow strip of session icons, or
/// hidden behind an edge button that opens it while the pointer is over it.
enum SidebarMode: String, CaseIterable {
    case full, icons, hidden
    static let key = "sidebar.mode"
}

/// Two letters for a name: "swinghub-2.1" → "SW", "Matrix NEW" → "MN".
enum SidebarInitials {
    static func of(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { !$0.isEmpty }
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String(name.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
    }

    /// The first name's, or the second's when the first has no letters ("/", "").
    static func of(_ name: String, or fallback: String) -> String {
        let initials = of(name)
        return initials.isEmpty ? of(fallback) : initials
    }
}

/// The sidebar as icons: one per running session, ringed in its status color; a click opens it.
struct SidebarRail: View {
    @Environment(AppModel.self) private var model
    @Binding var mode: SidebarMode

    var body: some View {
        let projects = model.deck.projects
        let order = Dictionary(uniqueKeysWithValues: projects.enumerated().map { ($1.id, $0) })
        let sessions = model.deck.sessions
            .filter { model.status(of: $0.id).display != .notStarted }
            .sorted { (order[$0.projectID] ?? .max) < (order[$1.projectID] ?? .max) }
        VStack(spacing: 0) {
            Button { mode = .full } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless)
                .help("Show the Full Sidebar")
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sessions) { session in
                        let project = model.deck.project(session.projectID)
                        RailIcon(
                            initials: SidebarInitials.of(project?.name ?? "", or: session.name),
                            terminal: session.kind == .shell,
                            color: StatusStyle.color(for: model.status(of: session.id).display),
                            attention: model.status(of: session.id).display.isBlocked || model.isUnseenIdle(session.id),
                            selected: model.selectedSessionID == session.id
                        )
                        .help(project.map { "\($0.name) · \(session.name)" } ?? session.name)
                        .onTapGesture { model.selectFromSidebar(session.id) }
                        .contextMenu { SessionMenu(session: session) }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct RailIcon: View {
    let initials: String
    let terminal: Bool
    let color: Color
    let attention: Bool
    let selected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color, lineWidth: 1.5))
                .overlay {
                    if terminal {
                        Image(systemName: "apple.terminal").font(.system(size: 13))
                    } else {
                        Text(initials).font(.system(size: 10.5, weight: .semibold))
                    }
                }
                .frame(width: 30, height: 30)
            if attention {
                Circle().fill(color).frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Hidden mode: a button on the window's leading edge; the pointer on it opens the full sidebar
/// over the content, and it closes when the pointer leaves (a click toggles it too).
struct HoverSidebar: View {
    @Binding var mode: SidebarMode
    @State private var open = false
    @State private var closeTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .leading) {
            if open {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button { mode = .full } label: { Image(systemName: "pin") }
                            .buttonStyle(.borderless)
                            .help("Keep the Sidebar Open")
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    SidebarView()
                }
                .frame(width: 290)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 12)
                .padding(6)
                .onHover { hovering in hover(hovering) }
                .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                // A slim tab on the leading edge, halfway down: covers almost nothing.
                Button { open = true } label: {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 56)
                        .background(.regularMaterial, in: UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6))
                        .shadow(radius: 1)
                }
                .buttonStyle(.plain)
                .help("Sidebar")
                .onHover { hovering in if hovering { hover(true) } }
            }
        }
        .animation(.snappy(duration: 0.2), value: open)
    }

    private func hover(_ hovering: Bool) {
        closeTask?.cancel()
        if hovering {
            open = true
        } else {
            // A moment's grace: crossing a menu or the edge shouldn't close it.
            closeTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { open = false }
            }
        }
    }
}

/// The toolbar's sidebar menu: full, icons, hidden.
struct SidebarModeMenu: View {
    @Binding var mode: SidebarMode

    var body: some View {
        Menu {
            Picker("Sidebar", selection: $mode) {
                Label("Full Sidebar", systemImage: "sidebar.left").tag(SidebarMode.full)
                Label("Icons Only", systemImage: "square.grid.3x1.below.line.grid.1x2").tag(SidebarMode.icons)
                Label("Hidden (Show on Hover)", systemImage: "rectangle").tag(SidebarMode.hidden)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sidebar", systemImage: "sidebar.squares.left")
        }
        .help("Sidebar: full, icons only, or hidden")
    }
}
