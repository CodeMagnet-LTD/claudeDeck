import AppKit
import Foundation
import Observation
import SwiftTerm

/// The user's login shell and a clean environment for launching `claude` in it.
enum ShellEnvironment {
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// Session markers a parent Claude Code leaves in the environment (e.g. when ClaudeDeck itself
    /// was launched from a Claude terminal). Inherited, they make `claude` run as a "child session"
    /// with transcripts and hooks disabled. The login shell re-exports anything the user sets in
    /// their profile, so dropping them here is safe.
    static func isInheritedMarker(_ key: String) -> Bool {
        key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDEDECK_")
            || key == "CLAUDE_PROJECT_DIR" || key == "CLAUDE_ENV_FILE" || key.hasPrefix("CLAUDE_PLUGIN_")
    }

    static var cleanEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter { !isInheritedMarker($0.key) }
    }

    static func environment(terminalID: UUID) -> [String] {
        var env = cleanEnvironment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ClaudeDeck"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["CLAUDEDECK_TERMINAL_ID"] = terminalID.uuidString
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Absolute path of `claude` as the login shell sees it (nil if not installed).
    static func resolveClaude() -> String? {
        for flags in ["-lc", "-lic"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: loginShell)
            p.arguments = [flags, "command -v claude"]
            p.environment = cleanEnvironment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if let line = text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces),
               line.hasPrefix("/") {
                return line
            }
        }
        return nil
    }
}

final class DeckTerminalView: LocalProcessTerminalView {
    static let background = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.1, alpha: 1)
    let sessionID: UUID

    init(sessionID: UUID) {
        self.sessionID = sessionID
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        optionAsMetaKey = true
        nativeBackgroundColor = Self.background
        nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Owns every terminal view + process for the app's lifetime. Views are re-parented when
/// the selection changes; they are never recreated, so the claude processes survive.
@MainActor
@Observable
final class TerminalRegistry: NSObject, LocalProcessTerminalViewDelegate {
    private(set) var running: Set<UUID> = []
    private(set) var titles: [UUID: String] = [:]
    @ObservationIgnored private var views: [UUID: DeckTerminalView] = [:]
    @ObservationIgnored var onExit: ((UUID, Int32?) -> Void)?

    func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    func view(for id: UUID) -> DeckTerminalView? { views[id] }

    func start(id: UUID, cwd: String, claudePath: String?, args: [String]) {
        let view = views[id] ?? DeckTerminalView(sessionID: id)
        view.processDelegate = self
        views[id] = view
        if running.contains(id) { return }

        let shell = ShellEnvironment.loginShell
        // exec keeps the pid: the hook's $PPID is this very process.
        let claude = claudePath ?? "claude"
        let script = #"exec "$0" "$@""#
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        view.getTerminal().resetToInitialState()
        view.startProcess(
            executable: shell,
            args: ["-l", "-c", script, claude] + args,
            environment: ShellEnvironment.environment(terminalID: id),
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: dir
        )
        running.insert(id)
    }

    /// Types text like a user would. A trailing "\r" is sent separately after a short pause,
    /// otherwise Claude's TUI treats text+Enter as a paste and inserts a newline instead of submitting.
    func type(_ text: String, into id: UUID) {
        guard let view = views[id], running.contains(id) else { return }
        guard text.hasSuffix("\r"), text.count > 1 else { view.send(txt: text); return }
        view.send(txt: String(text.dropLast()))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.running.contains(id) else { return }
            self.views[id]?.send(txt: "\r")
        }
    }

    func terminate(_ id: UUID) {
        guard let view = views[id], running.contains(id) else { return }
        view.terminate()
    }

    func discard(_ id: UUID) {
        views[id]?.removeFromSuperview()
        views[id] = nil
        running.remove(id)
    }

    func terminateAll() {
        for id in running { views[id]?.terminate() }
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated {
            guard let id = (source as? DeckTerminalView)?.sessionID else { return }
            titles[id] = title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            guard let id = (source as? DeckTerminalView)?.sessionID else { return }
            running.remove(id)
            onExit?(id, exitCode)
        }
    }
}
