import Foundation

/// One tab of the main window's detail area.
public enum WorkspaceTab: Hashable, Codable, Sendable {
    /// The terminal panes. Always the first tab; can't be closed or moved.
    case sessions
    /// A file in the built-in editor.
    case file(URL)
    /// A full-width Changes diff. `repo` is the Changes view's directory, `path` relative to the repo.
    case diff(repo: String, path: String, staged: Bool)
    case automations
    /// Full-text search over the Claude conversation history.
    case search
    /// The Skills browser.
    case skills

    public var fileURL: URL? {
        if case .file(let url) = self { url } else { nil }
    }
}

/// The open tabs, the selection and the preview tab (VS Code style: a preview is replaced by the
/// next preview open until it is pinned). Pure value type; the app wraps it in `WorkspaceTabs`.
public struct WorkspaceTabList: Equatable, Codable, Sendable {
    public private(set) var tabs: [WorkspaceTab] = [.sessions]
    public private(set) var selected: WorkspaceTab = .sessions
    public private(set) var preview: WorkspaceTab?

    public init() {}

    public var selectedIndex: Int { tabs.firstIndex(of: selected) ?? 0 }
    public var isSessionsSelected: Bool { selected == .sessions }

    /// Opens a tab, or selects it if it's already open. A preview open replaces the current preview
    /// tab in place; a non-preview open of the preview tab pins it.
    public mutating func open(_ tab: WorkspaceTab, preview asPreview: Bool = false) {
        if tabs.contains(tab) {
            if !asPreview, preview == tab { preview = nil }
            selected = tab
            return
        }
        if tab == .sessions { selected = .sessions; return }
        if asPreview, let old = preview, let index = tabs.firstIndex(of: old) {
            tabs[index] = tab
        } else {
            tabs.insert(tab, at: selectedIndex + 1)
        }
        if asPreview { preview = tab }
        selected = tab
    }

    public mutating func select(_ tab: WorkspaceTab) {
        if tabs.contains(tab) { selected = tab }
    }

    /// A preview tab becomes a normal one (edited, double-clicked, "Pin").
    public mutating func pin(_ tab: WorkspaceTab) {
        if preview == tab { preview = nil }
    }

    /// Removes a tab; closing the selected one selects its right neighbour (else the left one).
    public mutating func close(_ tab: WorkspaceTab) {
        guard tab != .sessions, let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        if preview == tab { preview = nil }
        if selected == tab { selected = tabs[min(index, tabs.count - 1)] }
    }

    /// The tabs "Close Others" would close (never Sessions).
    public func others(than tab: WorkspaceTab) -> [WorkspaceTab] {
        tabs.filter { $0 != tab && $0 != .sessions }
    }

    /// The tabs "Close Tabs to the Right" would close.
    public func tabsToTheRight(of tab: WorkspaceTab) -> [WorkspaceTab] {
        guard let index = tabs.firstIndex(of: tab) else { return [] }
        return Array(tabs[(index + 1)...])
    }

    /// Drag to reorder: moves `tab` to where `target` is. Sessions stays first.
    public mutating func move(_ tab: WorkspaceTab, to target: WorkspaceTab) {
        guard tab != .sessions, tab != target, let from = tabs.firstIndex(of: tab),
              let to = tabs.firstIndex(of: target) else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: max(1, to))
    }

    /// ⌘1 = Sessions, ⌘2…⌘8 = the tab at that position, ⌘9 = the last tab.
    public func tab(forCommandNumber number: Int) -> WorkspaceTab? {
        switch number {
        case 1: return .sessions
        case 9: return tabs.last
        case 2...8: return number <= tabs.count ? tabs[number - 1] : nil
        default: return nil
        }
    }

    /// ⌃Tab / ⌃⇧Tab, wrapping around.
    public mutating func selectNeighbour(forward: Bool) {
        guard tabs.count > 1 else { return }
        let step = forward ? 1 : tabs.count - 1
        selected = tabs[(selectedIndex + step) % tabs.count]
    }

    // MARK: Persistence

    /// What is restored on launch: file, automations, search and skills tabs (diffs are transient). The selection
    /// survives if it is one of them.
    public var persistable: WorkspaceTabList {
        var copy = self
        copy.tabs = tabs.filter {
            switch $0 {
            case .sessions, .file, .automations, .search, .skills: true
            case .diff: false
            }
        }
        if !copy.tabs.contains(selected) { copy.selected = .sessions }
        if let preview, !copy.tabs.contains(preview) { copy.preview = nil }
        return copy
    }

    /// A saved list cleaned up for this launch: drops files that no longer exist (and duplicates),
    /// keeps Sessions first.
    public func restored(fileExists: (URL) -> Bool) -> WorkspaceTabList {
        var copy = WorkspaceTabList()
        for tab in persistable.tabs where !copy.tabs.contains(tab) {
            if let url = tab.fileURL, !fileExists(url) { continue }
            copy.tabs.append(tab)
        }
        if copy.tabs.contains(selected) { copy.selected = selected }
        if let preview, copy.tabs.contains(preview) { copy.preview = preview }
        return copy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabs = (try? c.decodeIfPresent([WorkspaceTab].self, forKey: .tabs)) ?? [.sessions]
        if tabs.first != .sessions { tabs.removeAll { $0 == .sessions }; tabs.insert(.sessions, at: 0) }
        selected = (try? c.decodeIfPresent(WorkspaceTab.self, forKey: .selected)) ?? .sessions
        preview = try? c.decodeIfPresent(WorkspaceTab.self, forKey: .preview)
    }
}
