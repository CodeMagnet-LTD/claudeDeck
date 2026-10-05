import Foundation
import SwiftTerm

/// Simulator testing: with `CLAUDEDECK_DEBUG=1` in the launch environment, files dropped into
/// `tmp/debug/` drive the app and `tmp/debug/remote.txt` reports its state.
///   pair.txt (a claudedeck:// link) · <id>.open · <id>.approve / <id>.deny · <id>.type (text, "\r" = Enter)
@MainActor
final class DebugHooks {
    private let store: RemoteStore
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "debug")
    private var timer: Timer?

    static func startIfRequested(store: RemoteStore) -> DebugHooks? {
        guard ProcessInfo.processInfo.environment["CLAUDEDECK_DEBUG"] != nil else { return nil }
        let hooks = DebugHooks(store: store)
        try? FileManager.default.createDirectory(at: hooks.dir, withIntermediateDirectories: true)
        hooks.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { hooks.tick() }
        }
        return hooks
    }

    private init(store: RemoteStore) { self.store = store }

    private func tick() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for file in files {
            let url = dir.appending(path: file)
            let id = UUID(uuidString: String(file.prefix(36)))
            if file == "lanpair.txt", let password = try? String(contentsOf: url, encoding: .utf8), let host = store.lanHosts.first {
                try? FileManager.default.removeItem(at: url)
                store.pair(lanHost: host, password: password.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if file == "pair.txt", let link = try? String(contentsOf: url, encoding: .utf8) {
                try? FileManager.default.removeItem(at: url)
                store.pair(link: link)
            } else if file.hasSuffix(".open"), let id {
                try? FileManager.default.removeItem(at: url)
                store.path = [id]
            } else if file.hasSuffix(".approve") || file.hasSuffix(".deny"), let id {
                try? FileManager.default.removeItem(at: url)
                store.answer(id, stamp: store.snapshot?.session(id)?.permissionStamp, approve: file.hasSuffix(".approve"))
            } else if file.hasSuffix(".type"), let id, let text = try? String(contentsOf: url, encoding: .utf8) {
                try? FileManager.default.removeItem(at: url)
                store.sendTerminalInput(id, data: Data(text.replacingOccurrences(of: "\\r", with: "\r").utf8))
            }
        }
        let push = PushRegistration.shared
        var lines = ["connection: \(store.connection)", "terminals: \(store.terminalStates)",
                     "lan: \(store.lanHosts.map(\.name)) via=\(store.connectedVia ?? "-") pairing=\(store.pairing?.addresses ?? [])",
                     "push: token=\(push.token?.count ?? 0) env=\(PushRegistration.environment) error=\(push.lastError ?? "-")"]
        for session in store.snapshot?.sessions ?? [] {
            lines.append("  \(session.id.uuidString) \(session.name) \(session.state.rawValue) stamp=\(session.permissionStamp.map { String($0) } ?? "-")")
        }
        for (id, view) in store.debugTerminals() {
            let terminal = view.terminal.getTerminal()
            let text = (0..<terminal.rows).map { row in
                (0..<terminal.cols).map { col in
                    let c = terminal.getCharacter(col: col, row: row) ?? " "
                    return c == "\u{0}" ? " " : String(c)
                }.joined().replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }.joined(separator: "\n")
            try? "\(terminal.cols)x\(terminal.rows)\n\(text)".write(to: dir.appending(path: "screen-\(id.uuidString).txt"), atomically: true, encoding: .utf8)
        }
        try? lines.joined(separator: "\n").write(to: dir.appending(path: "remote.txt"), atomically: true, encoding: .utf8)
    }
}
