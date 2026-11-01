import SwiftUI

/// How a regular-width window (iPad) shows the session list: full, a strip of session icons, or
/// hidden behind an edge tab that opens it while the pointer is over it (a tap toggles it too).
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

/// The session list as icons: one per running session, ringed in its status color.
struct SessionRail: View {
    @Environment(RemoteStore.self) private var store
    @Binding var selection: UUID?
    @Binding var mode: SidebarMode
    @AppStorage(SessionStyle.colorsKey) private var customColors = ""

    var body: some View {
        let pinned = Set(store.projects.filter(\.pinned).map(\.name))
        let sessions = (store.snapshot?.sessions ?? [])
            // Only what's working or waiting for the user (and the one on screen).
            .filter { $0.state == .running || $0.state == .starting || $0.needsAttention || $0.id == selection }
            .sorted { pinned.contains($0.project) && !pinned.contains($1.project) }
        VStack(spacing: 0) {
            Button { mode = .full } label: { Image(systemName: "sidebar.left").font(.system(size: 17)) }
                .padding(.vertical, 10)
                .accessibilityLabel(Text("Show the Full Sidebar"))
            Divider()
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(sessions) { session in
                        let color = SessionStyle.color(session.state, custom: customColors)
                        Button { selection = session.id } label: {
                            ZStack(alignment: .bottomTrailing) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selection == session.id ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color, lineWidth: 1.5))
                                    .overlay {
                                        if session.state == .shell {
                                            Image(systemName: "apple.terminal").font(.system(size: 12))
                                        } else {
                                            Text(SidebarInitials.of(session.project, or: session.name))
                                                .font(.system(size: 11, weight: .semibold))
                                        }
                                    }
                                    .frame(width: 32, height: 32)
                                if session.needsAttention || session.unseen {
                                    Circle().fill(color).frame(width: 9, height: 9)
                                        .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 2))
                                        .offset(x: 3, y: 3)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .help(session.project.isEmpty || session.name.hasPrefix(session.project) ? session.name : "\(session.project) · \(session.name)")
                        .accessibilityLabel(Text(session.name))
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Hidden mode's tab on the leading edge.
struct SidebarEdgeTab: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Image(systemName: "chevron.compact.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 64)
                .background(.regularMaterial, in: UnevenRoundedRectangle(bottomTrailingRadius: 8, topTrailingRadius: 8))
                .shadow(radius: 1)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { open() } }
        .accessibilityLabel(Text("Sidebar"))
    }
}

/// The toolbar menu: full, icons, hidden.
struct SidebarModeMenu: View {
    @Binding var mode: SidebarMode

    var body: some View {
        Menu {
            Picker("Sidebar", selection: $mode) {
                Label("Full Sidebar", systemImage: "sidebar.left").tag(SidebarMode.full)
                Label("Icons Only", systemImage: "square.grid.3x1.below.line.grid.1x2").tag(SidebarMode.icons)
                Label("Hidden (Show on Hover)", systemImage: "rectangle").tag(SidebarMode.hidden)
            }
        } label: {
            Image(systemName: "sidebar.squares.left")
        }
        .accessibilityLabel(Text("Sidebar"))
    }
}
