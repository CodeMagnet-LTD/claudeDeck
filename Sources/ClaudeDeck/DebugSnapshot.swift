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
    /// an empty `<dir>/<session-uuid>.select` selects that session, `.beside` opens it in a new pane.
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
        for file in files where file.hasSuffix(".in") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard let id = UUID(uuidString: String(file.dropLast(3))),
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            model.terminals.type(text.replacingOccurrences(of: "<ESC>", with: "\u{1b}").replacingOccurrences(of: "<CR>", with: "\r"), into: id)
        }
    }

    private static func write(to dir: String) {
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
