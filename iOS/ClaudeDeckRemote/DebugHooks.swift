import SwiftTerm
import UIKit

/// Simulator testing: with `CLAUDEDECK_DEBUG=1` in the launch environment, files dropped into
/// `tmp/debug/` drive the app and `tmp/debug/remote.txt` reports its state.
///   pair.txt (a claudedeck:// link) · <id>.open · <id>.window (new window) · <id>.mode (Shift+Tab) · <id>.attach (an off-screen terminal, for .type and screen-<id>.txt) · <id>.answer (JSON [QuestionAnswer]) · <id>.files (text, sent with a photo and a file) · <id>.approve / <id>.deny · <id>.type (text, "\r" = Enter)
@MainActor
final class DebugHooks {
    private let store: RemoteStore
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "debug")
    private var timer: Timer?
    private var terminals: [UUID: RemoteTerminalUIView] = [:]

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
            } else if file == "start.txt", let prompt = try? String(contentsOf: url, encoding: .utf8), let project = store.projects.first {
                try? FileManager.default.removeItem(at: url)
                store.startSession(in: project.id, prompt: prompt)
            } else if file == "shell.txt", let command = try? String(contentsOf: url, encoding: .utf8), let project = store.projects.first {
                try? FileManager.default.removeItem(at: url)
                store.startShell(in: project.id, command: command)
                store.loadPastConversations(project.id)
            } else if file == "files.txt", let target = try? String(contentsOf: url, encoding: .utf8), let project = store.projects.first {
                try? FileManager.default.removeItem(at: url)
                store.listDirectory(project.id, path: "")
                store.readFile(project.id, path: target.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if file.hasSuffix(".stop"), let id {
                try? FileManager.default.removeItem(at: url)
                store.stopSession(id)
            } else if file.hasSuffix(".resume"), let id {
                try? FileManager.default.removeItem(at: url)
                store.resumeSession(id)
            } else if file.hasSuffix(".open"), let id {
                try? FileManager.default.removeItem(at: url)
                store.open(id)
            } else if file.hasSuffix(".attach"), let id {
                try? FileManager.default.removeItem(at: url)
                let view = RemoteTerminalUIView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
                view.onInput = { [weak store] data in store?.sendTerminalInput(id, data: data) }
                terminals[id] = view
                store.attachTerminal(id, sink: view)
            } else if file.hasSuffix(".answer"), let id, let data = try? Data(contentsOf: url),
                      let answers = try? JSONDecoder().decode([QuestionAnswer].self, from: data),
                      let entry = store.conversations[id]?.entries.last(where: { $0.questions != nil }) {
                try? FileManager.default.removeItem(at: url)
                store.answerQuestion(id, toolUseID: entry.id, answers: answers)
            } else if file.hasSuffix(".files"), let id, let text = try? String(contentsOf: url, encoding: .utf8) {
                // The text as a message, with a drawn photo ("42") and a text file.
                try? FileManager.default.removeItem(at: url)
                let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200)).image { _ in
                    UIColor.white.setFill()
                    UIRectFill(CGRect(x: 0, y: 0, width: 400, height: 200))
                    ("42" as NSString).draw(at: CGPoint(x: 140, y: 40), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 100)])
                }
                let files = [Attachment.photo(image.pngData()!, number: 1), Attachment.file(Data("The secret word is kiwi.\n".utf8), name: "my notes.txt")]
                store.sendPrompt(id, text: text, files: files.compactMap { $0?.upload })
            } else if file.hasSuffix(".mode"), let id {
                try? FileManager.default.removeItem(at: url)
                store.permissionMode(id, cycle: true)
            } else if file.hasSuffix(".window"), let id {
                try? FileManager.default.removeItem(at: url)
                store.newWindowRequest = RemoteStore.OpenRequest(session: id, scene: nil)
            } else if file.hasSuffix(".approve") || file.hasSuffix(".deny"), let id {
                try? FileManager.default.removeItem(at: url)
                store.answer(id, stamp: store.snapshot?.session(id)?.permissionStamp, approve: file.hasSuffix(".approve"))
            } else if file.hasSuffix(".type"), let id, let text = try? String(contentsOf: url, encoding: .utf8) {
                try? FileManager.default.removeItem(at: url)
                store.sendTerminalInput(id, data: Data(text.replacingOccurrences(of: "\\r", with: "\r").utf8))
            }
        }
        let push = PushRegistration.shared
        var lines = ["connection: \(store.connection) modes=\(store.permissionModes.values.sorted()) sendingFiles=\(store.sendingFiles.count) promptError=\(store.promptError ?? "-") windows=\(store.scenes.map { "\($0.key.uuidString.prefix(8)):\($0.value?.uuidString.suffix(4) ?? "-")" }.sorted()) projects=\(store.projects.map(\.name))", "files: dirs=\(store.directories.values.map { $0.entries.map(\.name) }) file=\(store.files.values.map { "\($0.size):\($0.text?.prefix(30) ?? "")|\($0.error ?? "")" })",
                     "terminals: \(store.terminalStates) usage=\(store.snapshot?.usage.map { "\($0.fiveHour ?? -1)/\($0.week ?? -1)" } ?? "-") past=\(store.pastConversations.values.map(\.count))",
                     "lan: \(store.lanHosts.map(\.name)) via=\(store.connectedVia ?? "-") pairing=\(store.pairing?.addresses ?? [])",
                     "push: token=\(push.token?.count ?? 0) env=\(PushRegistration.environment) error=\(push.lastError ?? "-")"]
        for session in store.snapshot?.sessions ?? [] {
            lines.append("  \(session.id.uuidString) \(session.name) \(session.state.rawValue) stamp=\(session.permissionStamp.map { String($0) } ?? "-") unseen=\(session.unseen)")
        }
        for (id, conversation) in store.conversations {
            let questions = conversation.entries.filter { $0.questions != nil }.map { "\($0.id.suffix(6)):\($0.questions?.count ?? 0)q:\($0.result == nil ? "open" : "done")" }
            lines.append("  conversation \(id.uuidString) entries=\(conversation.entries.count) questions=\(questions)")
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
