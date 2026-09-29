import AppKit

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
        // `<name>.tab`: "diff\t<dir>\t<path>\t<staged 0|1>" opens that diff tab (as a Changes click would),
        // "file\t<path>\t<preview 0|1>" an editor tab, "automations" / "sessions" those tabs; "close-all"
        // closes every tab but Sessions.
        for file in files where file.hasSuffix(".tab") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            let parts = contents(path).components(separatedBy: "\t")
            if parts.count == 4, parts[0] == "diff" {
                model.tabs.open(.diff(repo: parts[1], path: parts[2], staged: parts[3] == "1"), preview: true)
            } else if parts.count == 3, parts[0] == "file" {
                model.tabs.openFile(URL(fileURLWithPath: parts[1]), preview: parts[2] == "1")
            } else if parts == ["automations"] {
                model.tabs.open(.automations)
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
            if let t = v as? NSTableView { lines.append("\(type(of: t)) rows=\(t.numberOfRows) frame=\(t.frame.integral)") }
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
