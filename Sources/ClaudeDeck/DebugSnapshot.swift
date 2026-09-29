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
        // `<name>.tab`: "diff\t<dir>\t<path>\t<staged 0|1>" opens that diff tab (as a Changes click would).
        for file in files where file.hasSuffix(".tab") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            let parts = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .newlines).components(separatedBy: "\t")
            if parts.count == 4, parts[0] == "diff" {
                model.tabs.open(.diff(repo: parts[1], path: parts[2], staged: parts[3] == "1"), preview: true)
            }
        }
        for file in files where file.hasSuffix(".in") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard let id = UUID(uuidString: String(file.dropLast(3))),
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            model.terminals.type(text.replacingOccurrences(of: "<ESC>", with: "\u{1b}").replacingOccurrences(of: "<CR>", with: "\r"), into: id)
        }
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
