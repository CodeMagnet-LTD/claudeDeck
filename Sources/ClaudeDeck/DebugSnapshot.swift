import AppKit
import ClaudeDeckCore

/// Development aid: when `CLAUDEDECK_SNAPSHOT_DIR` is set, periodically renders the app's own
/// windows to PNG files there (no screen-recording permission needed).
@MainActor
enum DebugSnapshot {
    static func startIfRequested(model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["CLAUDEDECK_SNAPSHOT_DIR"] else { return }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                write(to: dir)
                typePendingInput(from: dir, model: model)
            }
        }
    }

    /// `<dir>/<session-uuid>.in` files are typed into that session's terminal, then deleted;
    /// an empty `<dir>/<session-uuid>.select` selects that session, `.beside` opens it in a new pane,
    /// `<project-uuid>.shell` opens a plain terminal in that project.
    private static func typePendingInput(from dir: String, model: AppModel) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for file in files where file.hasSuffix(".select") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.dropLast(7))) { model.selectedSessionID = id }
        }
        for file in files where file.hasSuffix(".beside") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.dropLast(7))) { model.openBeside(id) }
        }
        for file in files where file.hasSuffix(".shell") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            if let project = UUID(uuidString: String(file.dropLast(6))) { model.newShell(in: project) }
        }
        // `<session-uuid>.remove`: deletes that session, as its context menu does.
        for file in files where file.hasSuffix(".remove") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.dropLast(7))) { model.removeSession(id) }
        }
        for file in files where file.hasSuffix(".paste") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.dropLast(6))) { model.terminals.view(for: id)?.paste(NSApp as Any) }
        }
        for file in files where file.hasSuffix(".approve") || file.hasSuffix(".deny") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            let approve = file.hasSuffix(".approve")
            guard let id = UUID(uuidString: String(file.prefix(36))) else { continue }
            let stamp = model.pendingPermissionStamp(id)
            _ = approve ? model.approvePermission(id, expectedAt: stamp) : model.denyPermission(id, expectedAt: stamp)
        }
        // `remote.cmd`: "host" / "client" / "off" turns remote mode on that side (demo testing);
        // `<session-uuid>.remote-approve` / `.remote-deny` answer a prompt on the paired Mac.
        for file in files where file == "remote.cmd" {
            let path = (dir as NSString).appendingPathComponent(file)
            let command = contents(path).trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(atPath: path)
            model.mutate {
                $0.settings.remoteHost = command.hasPrefix("host")
                $0.settings.remoteLAN = command.hasSuffix("+lan")
                $0.settings.remoteClient = command.hasPrefix("client")
            }
            model.remote.refresh()
        }
        let remote = model.remote
        let remoteLines = ["host: \(remote.hostState) remotes=\(remote.connectedRemotes) last=\(remote.lastRemoteAnswer ?? "-") rejected=\(remote.lastRejectedPeer ?? "-")",
                           "client: \(remote.connection) answering=\(remote.answering.count) error=\(remote.answerError ?? "-")",
                           "terminals: \(remote.terminalStates) counters: \(remote.counters.sorted { $0.key < $1.key })",
                           "lan: \(remote.lanHosts.map(\.name)) via=\(remote.connectedVia ?? "-")"]
            + (remote.snapshot?.sessions ?? []).map { "  \($0.id.uuidString) \($0.name) \($0.state.rawValue) stamp=\($0.permissionStamp.map { String($0) } ?? "-")" }
        try? remoteLines.joined(separator: "\n").write(toFile: (dir as NSString).appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        // `<id>.remote-open` opens the paired Mac's session in a tab; `<id>.remote-type` types its
        // contents there ("\\r" = Enter); `screen-<id>.txt` holds each live terminal's visible text.
        for file in files where file.hasSuffix(".remote-open") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.prefix(36))) { model.openRemoteTerminal(id) }
        }
        for file in files where file.hasSuffix(".remote-type") {
            let path = (dir as NSString).appendingPathComponent(file)
            let text = contents(path).replacingOccurrences(of: "\\r", with: "\r")
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.prefix(36))) { model.remote.sendTerminalInput(id, data: Data(text.utf8)) }
        }
        for (id, text) in model.remote.debugScreens() {
            try? text.write(toFile: (dir as NSString).appendingPathComponent("screen-\(id.uuidString).txt"), atomically: true, encoding: .utf8)
        }
        // `remote.password`: sets the remote-mode password (both roles).
        for file in files where file == "remote.password" {
            let path = (dir as NSString).appendingPathComponent(file)
            let password = contents(path).trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(atPath: path)
            if !password.isEmpty { model.remote.setPassword(password) }
        }
        for file in files where file.hasSuffix(".remote-approve") || file.hasSuffix(".remote-deny") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            guard let id = UUID(uuidString: String(file.prefix(36))) else { continue }
            model.remote.answer(id, stamp: model.remote.snapshot?.session(id)?.permissionStamp, approve: file.hasSuffix(".remote-approve"))
        }
        // `<name>.tab`: "diff\t<dir>\t<path>\t<staged 0|1>" opens that diff tab (as a Changes click would),
        // "file\t<path>\t<preview 0|1>" an editor tab, "repo\t<dir>\t<history|worktrees>" a repository page,
        // "automations" / "inbox" / "sessions" / "skills" those tabs, "search\t<query>\t<all 0|1>" the Search
        // tab with that query; "close-all" closes every tab but Sessions.
        for file in files where file.hasSuffix(".tab") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            let parts = contents(path).components(separatedBy: "\t")
            if parts.count == 4, parts[0] == "diff" {
                model.tabs.open(.diff(repo: parts[1], path: parts[2], staged: parts[3] == "1"), preview: true)
            } else if parts.count == 3, parts[0] == "file" {
                model.tabs.openFile(URL(fileURLWithPath: parts[1]), preview: parts[2] == "1")
            } else if parts.count == 3, parts[0] == "repo", let page = RepositoryPage(rawValue: parts[2]) {
                model.tabs.open(.repository(repo: parts[1], page: page))
            } else if parts == ["automations"] {
                model.tabs.open(.automations)
            } else if parts == ["inbox"] {
                model.tabs.open(.inbox)
            } else if parts == ["skills"] {
                model.showSkills()
            } else if parts.count == 3, parts[0] == "search" {
                model.showHistorySearch()
                HistorySearchController.shared.scope = parts[2] == "1" ? .all : .project
                HistorySearchController.shared.query = parts[1]
            } else if parts == ["sessions"] {
                model.tabs.selectSessions()
            } else if parts == ["close-all"] {
                model.tabs.close(model.tabs.tabs.filter { $0 != .sessions })
            }
        }
        // `<name>.inspector`: "files" / "changes" shows the right panel on that tab, "hide" closes it.
        for file in files where file.hasSuffix(".inspector") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            let tab = contents(path)
            UserDefaults.windowState.set(tab != "hide", forKey: "showFiles")
            if let tab = InspectorTab(rawValue: tab) { UserDefaults.windowState.set(tab.rawValue, forKey: "inspectorTab") }
        }
        // `<name>.quickopen`: shows Quick Open with the file's text as the query.
        for file in files where file.hasSuffix(".quickopen") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            ExplorerSheets.quickOpen(model: model, query: contents(path))
        }
        // `<session-uuid>.github` fetches the session's linked issue/PR; `.popover` opens its pane-header popover.
        for file in files where file.hasSuffix(".github") || file.hasSuffix(".popover") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            guard let id = UUID(uuidString: String(file.prefix(36))) else { continue }
            if file.hasSuffix(".github") { Task { await GitHubMonitor.shared.refresh(id) } }
            else { GitHubMonitor.shared.debugPresentRequest = id }
        }
        // `<name>.frame`: "x y w h" (screen points, bottom-left origin) for the main window.
        for file in files where file.hasSuffix(".frame") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            let n = contents(path).split(separator: " ").compactMap { Double($0) }
            if n.count == 4 { model.tabs.mainWindow?.setFrame(NSRect(x: n[0], y: n[1], width: n[2], height: n[3]), display: true) }
        }
        // `<name>.scroll`: "x y" (window points, top-left origin) scrolls the scroll view there to its end.
        for file in files where file.hasSuffix(".scroll") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            let n = contents(path).split(separator: " ").compactMap { Double($0) }
            guard n.count == 2, let window = model.tabs.mainWindow, let content = window.contentView else { continue }
            let point = NSPoint(x: n[0], y: content.bounds.height - n[1])
            var view = content.hitTest(point)
            while let v = view, !(v is NSScrollView) { view = v.superview }
            guard let scroll = view as? NSScrollView, let doc = scroll.documentView else { continue }
            let end = doc.isFlipped ? max(0, doc.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: end))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        // `app.activate` brings the app forward (active window chrome, popovers); `app.quit` quits it.
        for file in files where file == "app.activate" || file == "app.quit" {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(file))
            guard file == "app.quit" else { NSApp.activate(); continue }
            // An open sheet (Quick Open) would hold up termination.
            for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
            NSApp.terminate(nil)
        }
        for file in files where file.hasSuffix(".in") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard let id = UUID(uuidString: String(file.dropLast(3))),
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            model.terminals.type(text.replacingOccurrences(of: "<ESC>", with: "\u{1b}").replacingOccurrences(of: "<CR>", with: "\r"), into: id)
        }
    }

    private static func contents(_ path: String) -> String {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Row counts of every table/outline view (glass sidebars don't render into snapshots).
    private static func writeRowCounts(to dir: String) {
        var lines: [String] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTableView {
                lines.append("\(type(of: t)) rows=\(t.numberOfRows) frame=\(t.frame.integral)")
                // Every row view the table holds: one not at its row's place is drawn as a stale copy.
                for sub in t.subviews.sorted(by: { $0.frame.minY < $1.frame.minY }) where !sub.isHidden && sub.alphaValue > 0 {
                    let row = (sub as? NSTableRowView).map { t.row(for: $0) } ?? -2
                    let expected = row >= 0 ? t.rect(ofRow: row).integral : .zero
                    lines.append("  \(type(of: sub)) row=\(row) frame=\(sub.frame.integral)\(row >= 0 && expected != sub.frame.integral ? " expected=\(expected)" : "")")
                }
            }
            v.subviews.forEach(walk)
        }
        for w in NSApp.windows where w.isVisible { if let c = w.contentView?.superview ?? w.contentView { walk(c) } }
        try? lines.joined(separator: "\n").write(toFile: (dir as NSString).appendingPathComponent("rows.txt"), atomically: true, encoding: .utf8)
    }

    private static func write(to dir: String) {
        writeRowCounts(to: dir)
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? "window-\(i)" : window.title
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
    }
}
