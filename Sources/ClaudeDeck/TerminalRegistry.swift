import AppKit
import Foundation
import Observation
import SwiftTerm

/// The user's login shell and a clean environment for launching `claude` in it.
enum ShellEnvironment {
    /// The user's login shell if it is POSIX-compatible (the launch script uses "$0" "$@"),
    /// otherwise zsh.
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            let posix: Set<String> = ["zsh", "bash", "sh", "dash", "ksh"]
            if posix.contains((path as NSString).lastPathComponent), FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
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

    /// Backslash-escapes a path the way Terminal.app does for dropped files.
    static func escapedPath(_ path: String) -> String {
        var out = ""
        for ch in path {
            if " '\"\\()[]{}&;|<>*?!$`#~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
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
            // A prompting or slow rc file must not hang the app.
            let deadline = Date().addingTimeInterval(8)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate(); continue }
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
    /// Terminal background for the current appearance (dark: near-black, light: near-white).
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.1, alpha: 1)
            : NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.97, alpha: 1)
    }
    static let foreground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.9, alpha: 1)
            : NSColor(calibratedWhite: 0.12, alpha: 1)
    }
    let sessionID: UUID

    init(sessionID: UUID, fontSize: CGFloat = 13) {
        self.sessionID = sessionID
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        optionAsMetaKey = true
        applyColors()
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Resolve the dynamic colors for the view's current appearance (SwiftTerm stores concrete colors).
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeBackgroundColor = Self.background.usingColorSpace(.deviceRGB) ?? Self.background
            nativeForegroundColor = Self.foreground.usingColorSpace(.deviceRGB) ?? Self.foreground
            caretColor = nativeForegroundColor
        }
    }

    /// Trackpad pinch zooms all terminals.
    var onMagnify: ((CGFloat) -> Void)?
    private var pinch: CGFloat = 0

    override func magnify(with event: NSEvent) {
        pinch += event.magnification
        if abs(pinch) >= 0.15 {
            onMagnify?(pinch > 0 ? 1 : -1)
            pinch = 0
        }
        if event.phase == .ended || event.phase == .cancelled { pinch = 0 }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    var onInput: ((ArraySlice<UInt8>) -> Void)?
    var onFocus: (() -> Void)?
    /// Claude sessions read images from the clipboard themselves on Ctrl+V.
    var isClaude = true

    /// ⌘V: SwiftTerm only pastes text. With an image (screenshot, copied photo) and no text on
    /// the clipboard, send Ctrl+V so Claude attaches the clipboard image — like in Terminal.app.
    /// Copied Finder files paste as escaped paths.
    override func paste(_ sender: Any) {
        let pb = NSPasteboard.general
        let hasText = !(pb.string(forType: .string) ?? "").isEmpty
        if !hasText {
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                send(txt: urls.map { ShellEnvironment.escapedPath($0.path) }.joined(separator: " ") + " ")
                return
            }
            let hasImage = pb.canReadObject(forClasses: [NSImage.self], options: nil)
            if hasImage, isClaude {
                send(txt: "\u{16}")
                return
            }
        }
        super.paste(sender)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(data)
        super.send(source: source, data: data)
    }
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

    @ObservationIgnored private var clickMonitor: Any?

    override init() {
        super.init()
        // Clicking into a terminal focuses its session (TerminalView's responder methods aren't open).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                if let hit = event.window?.contentView?.hitTest(event.locationInWindow) {
                    var view: NSView? = hit
                    while let v = view, !(v is DeckTerminalView) { view = v.superview }
                    (view as? DeckTerminalView)?.onFocus?()
                }
            }
            return event
        }
    }

    func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    /// Font size for every terminal (existing and future); the pty is resized to the new grid.
    @ObservationIgnored var fontSize: CGFloat = 13 {
        didSet {
            guard fontSize != oldValue else { return }
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            for view in views.values { view.font = font }
        }
    }

    func view(for id: UUID) -> DeckTerminalView? { views[id] }

    func start(id: UUID, cwd: String, claudePath: String?, args: [String]) {
        let view = views[id] ?? DeckTerminalView(sessionID: id, fontSize: fontSize)
        view.processDelegate = self
        view.onInput = { [weak self] data in self?.onUserInput?(id, data) }
        view.onFocus = { [weak self] in self?.onFocus?(id) }
        view.onMagnify = { [weak self] step in self?.onZoom?(step) }
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
    /// A plain interactive login shell in `cwd` (no ClaudeDeck terminal id: claude started
    /// inside it is not tracked as this session).
    func startShell(id: UUID, cwd: String) {
        let view = views[id] ?? DeckTerminalView(sessionID: id, fontSize: fontSize)
        view.processDelegate = self
        view.onInput = { [weak self] data in self?.onUserInput?(id, data) }
        view.onFocus = { [weak self] in self?.onFocus?(id) }
        view.onMagnify = { [weak self] step in self?.onZoom?(step) }
        view.isClaude = false
        views[id] = view
        if running.contains(id) { return }
        let shell = ShellEnvironment.loginShell
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        var env = ShellEnvironment.cleanEnvironment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ClaudeDeck"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        view.getTerminal().resetToInitialState()
        view.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: dir
        )
        running.insert(id)
        titles[id] = nil
    }

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

    /// Ends the claude process. SwiftTerm's `terminate()` cancels its own exit monitor, so the
    /// exit is reported here and the child is reaped in the background (SIGKILL after 5 s).
    func terminate(_ id: UUID) {
        guard let view = views[id], running.contains(id) else { return }
        let pid = view.process.shellPid
        view.terminate()
        running.remove(id)
        onExit?(id, nil)
        if pid > 0 { Self.reap(pid) }
    }

    nonisolated static func reap(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<50 {
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                usleep(100_000)
            }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    /// Remaining input hook: called with every chunk the user types into a terminal.
    @ObservationIgnored var onUserInput: ((UUID, ArraySlice<UInt8>) -> Void)?
    @ObservationIgnored var onFocus: ((UUID) -> Void)?
    @ObservationIgnored var onZoom: ((CGFloat) -> Void)?

    func discard(_ id: UUID) {
        views[id]?.removeFromSuperview()
        views[id] = nil
        running.remove(id)
    }

    /// On quit: signal every process without reporting exits (quit keeps `isOpen` for auto-resume).
    func terminateAll() {
        for id in running {
            guard let view = views[id] else { continue }
            let pid = view.process.shellPid
            view.terminate()
            if pid > 0 { kill(pid, SIGHUP) }
        }
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
