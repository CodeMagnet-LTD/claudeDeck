import AppKit
import ClaudeDeckCore
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

// Live terminal for remote mode (RemoteScreen.swift). Host: the screen is read back from the
// terminal's cells for a watcher's first frame. Remote: a terminal view pinned to the host's
// grid, fed with that screen and the raw output, sending keystrokes back.

// MARK: Host — screen capture

@MainActor
enum TerminalCapture {
    /// The visible screen plus up to `scrollback` lines above it.
    static func screen(of view: TerminalView, scrollback: Int = 500) -> TermScreen {
        let terminal = view.getTerminal()
        let rows = terminal.rows, cols = terminal.cols
        let trimmed = terminal.buffer.totalLinesTrimmed
        // `getLine(row:)` follows the user's scroll position; count the lines instead: the
        // visible screen is always the last `rows` of them.
        var count = terminal.buffer.yDisp + rows
        while terminal.getScrollInvariantLine(row: trimmed + count) != nil { count += 1 }
        let first = max(0, count - rows - scrollback)
        var lines: [[TermCell]] = []
        lines.reserveCapacity(count - first)
        for row in first..<count {
            guard let line = terminal.getScrollInvariantLine(row: trimmed + row) else {
                lines.append([])
                continue
            }
            lines.append((0..<min(cols, line.count)).map { cell(line[$0]) })
        }
        let cursor = terminal.getCursorLocation()
        var screen = TermScreen(cols: cols, rows: rows, lines: lines, cursorX: cursor.x, cursorY: cursor.y)
        screen.alternateBuffer = terminal.isCurrentBufferAlternate
        screen.applicationCursor = terminal.applicationCursor
        screen.bracketedPaste = terminal.bracketedPasteMode
        return screen
    }

    private static func cell(_ data: CharData) -> TermCell {
        let character = data.getCharacter()
        let text = character == "\u{0}" ? " " : String(character)
        let attribute = data.attribute
        return TermCell(
            text: text,
            width: Int(data.width),
            fg: color(attribute.fg),
            bg: color(attribute.bg),
            style: TermCell.Style(rawValue: attribute.style.rawValue)
        )
    }

    private static func color(_ color: Attribute.Color) -> TermCell.Color {
        switch color {
        case .ansi256(let code): .ansi(code)
        case .trueColor(let r, let g, let b): .rgb(r, g, b)
        case .defaultColor, .defaultInvertedColor: .default
        }
    }
}

// MARK: Remote — view

/// Receives one session's stream (RemoteController routes to it).
@MainActor
protocol RemoteTerminalSink: AnyObject {
    func start(cols: Int, rows: Int, screen: Data)
    func feed(_ bytes: Data)
}

/// A terminal that keeps the host's grid whatever its frame (the host owns the size).
final class FixedGridTerminalView: TerminalView {
    var gridCols = 80
    var gridRows = 24
    /// ⌘V with files or an image (no text) on the pasteboard: they go to the other Mac instead.
    var onPasteFiles: (([RemoteUpload]) -> Void)?

    override func paste(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        let urls = RemoteUploadReader.fileURLs(pasteboard)
        if !urls.isEmpty, let onPasteFiles {
            onPasteFiles(RemoteUploadReader.files(urls))
        } else if pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard),
                  let upload = RemoteUploadReader.image(image, name: "pasted-image"), let onPasteFiles {
            onPasteFiles([upload])
        } else {
            super.paste(sender)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        enforceGrid()
    }

    /// Undoes SwiftTerm's frame-based resize.
    @discardableResult
    func enforceGrid() -> Bool {
        let terminal = getTerminal()
        guard terminal.cols != gridCols || terminal.rows != gridRows else { return false }
        terminal.resize(cols: gridCols, rows: gridRows)
        needsDisplay = true
        return true
    }
}

/// Hosts the terminal at its exact grid size, top-centered; steps the font down until the host's
/// columns fit the width.
final class RemoteTerminalContainer: NSView, @preconcurrency TerminalViewDelegate, RemoteTerminalSink {
    let terminal = FixedGridTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    /// ⌘+ / ⌘-: refits right away (the width didn't change, so layout alone wouldn't) and asks
    /// the host for a fresh screen, since a font change reflows SwiftTerm's buffer.
    var preferredFontSize: CGFloat {
        didSet { if preferredFontSize != oldValue { fit(force: true) } }
    }
    var onInput: ((Data) -> Void)?
    /// The grid was disturbed (font change): ask the host for a fresh screen.
    var onNeedsRedraw: (() -> Void)?
    /// Files dropped on the terminal or pasted into it.
    var onFiles: (([RemoteUpload]) -> Void)? {
        didSet { terminal.onPasteFiles = onFiles }
    }
    private var fittedWidth: CGFloat = -1
    private var fontSize: CGFloat = 0

    init(fontSize: CGFloat) {
        preferredFontSize = fontSize
        super.init(frame: .zero)
        terminal.terminalDelegate = self
        terminal.optionAsMetaKey = true
        terminal.autoresizingMask = []
        applyColors()
        addSubview(terminal)
        setFont(fontSize)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFiles != nil && !RemoteUploadReader.fileURLs(sender.draggingPasteboard).isEmpty ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = RemoteUploadReader.fileURLs(sender.draggingPasteboard)
        guard let onFiles, !urls.isEmpty else { return false }
        onFiles(RemoteUploadReader.files(urls))
        window?.makeFirstResponder(terminal)
        return true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background = DeckTerminalView.background.usingColorSpace(.deviceRGB) ?? DeckTerminalView.background
            terminal.nativeBackgroundColor = background
            terminal.nativeForegroundColor = DeckTerminalView.foreground.usingColorSpace(.deviceRGB) ?? DeckTerminalView.foreground
            terminal.caretColor = terminal.nativeForegroundColor
            wantsLayer = true
            layer?.backgroundColor = background.cgColor
        }
    }

    override func layout() {
        super.layout()
        fit(force: false)
    }

    // MARK: RemoteTerminalSink

    func start(cols: Int, rows: Int, screen: Data) {
        let changed = cols != terminal.gridCols || rows != terminal.gridRows
        terminal.gridCols = max(cols, 2)
        terminal.gridRows = max(rows, 2)
        terminal.enforceGrid()
        if changed { fit(force: true) }
        terminal.feed(byteArray: ArraySlice(screen))
    }

    func feed(_ bytes: Data) {
        terminal.feed(byteArray: ArraySlice(bytes))
    }

    // MARK: Layout

    private func setFont(_ size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        terminal.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func fit(force: Bool) {
        guard bounds.width > 0, force || bounds.width != fittedWidth else {
            place()
            return
        }
        fittedWidth = bounds.width
        let before = fontSize
        setFont(preferredFontSize)
        terminal.enforceGrid()
        // Estimate from the cell width at the preferred size, then step down until it fits.
        var size = preferredFontSize
        let width = terminal.getOptimalFrameSize().width
        if width > bounds.width {
            size = max(8, (preferredFontSize * bounds.width / width * 2).rounded(.down) / 2)
            setFont(size)
            terminal.enforceGrid()
            while terminal.getOptimalFrameSize().width > bounds.width, size > 8 {
                size -= 0.5
                setFont(size)
                terminal.enforceGrid()
            }
        }
        place()
        if fontSize != before { onNeedsRedraw?() }
    }

    private func place() {
        let size = terminal.getOptimalFrameSize().size
        let x = max(0, (bounds.width - size.width) / 2)
        let frame = NSRect(x: x, y: 0, width: size.width, height: size.height)
        if terminal.frame != frame { terminal.frame = frame }
        terminal.enforceGrid()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminal)
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Data(data))
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), url.scheme == "http" || url.scheme == "https" { NSWorkspace.shared.open(url) }
    }

    func bell(source: TerminalView) { NSSound.beep() }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

struct RemoteTerminalRepresentable: NSViewRepresentable {
    let sessionID: UUID
    let remote: RemoteController
    let fontSize: CGFloat

    final class Coordinator {
        let sessionID: UUID
        weak var remote: RemoteController?
        init(sessionID: UUID, remote: RemoteController) {
            self.sessionID = sessionID
            self.remote = remote
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(sessionID: sessionID, remote: remote) }

    func makeNSView(context: Context) -> RemoteTerminalContainer {
        let view = RemoteTerminalContainer(fontSize: fontSize)
        let id = sessionID
        view.onInput = { [weak remote] data in remote?.sendTerminalInput(id, data: data) }
        view.onNeedsRedraw = { [weak remote] in remote?.redrawTerminal(id) }
        view.onFiles = { [weak remote] files in remote?.pasteFiles(id, files: files) }
        remote.attachTerminal(id, sink: view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view.terminal) }
        return view
    }

    func updateNSView(_ view: RemoteTerminalContainer, context: Context) {
        view.preferredFontSize = fontSize
    }

    static func dismantleNSView(_ view: RemoteTerminalContainer, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            view.onInput = nil
            view.onNeedsRedraw = nil
            coordinator.remote?.detachTerminal(coordinator.sessionID, sink: view)
        }
    }
}

// MARK: Remote — tab

/// A tab with the other Mac's session: header (name, state, Allow / Deny) over the live terminal.
struct RemoteTerminalTab: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID

    var body: some View {
        let remote = model.remote
        let session = remote.snapshot?.session(sessionID)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                Text(session?.name ?? remote.terminalNames[sessionID] ?? String(localized: "Session")).fontWeight(.semibold).lineLimit(1)
                if let host = remote.snapshot?.hostName {
                    Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let session {
                    StatusPill(display: session.state.display, unseen: session.unseen)
                    if let detail = session.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                if let session, let stamp = session.permissionStamp {
                    Button("Allow") { remote.answer(sessionID, stamp: stamp, approve: true) }
                        .buttonStyle(.borderedProminent)
                    Button("Deny", role: .destructive) { remote.answer(sessionID, stamp: stamp, approve: false) }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            Divider()
            RemoteTerminalRepresentable(sessionID: sessionID, remote: remote, fontSize: CGFloat(model.deck.settings.terminalFontSize))
                .overlay(alignment: .bottom) {
                    if let upload = remote.uploads[sessionID] {
                        HStack(spacing: 6) {
                            switch upload {
                            case .sending:
                                ProgressView().controlSize(.small)
                                Text("Sending files…")
                            case .failed(let message):
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                Text(message)
                            }
                        }
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                    }
                }
                .overlay {
                    if let message = overlayMessage(remote) {
                        VStack(spacing: 8) {
                            if remote.terminalStates[sessionID] != .ended { ProgressView().controlSize(.small) }
                            Text(message).foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
        }
    }

    private func overlayMessage(_ remote: RemoteController) -> String? {
        guard remote.connection == .connected else { return String(localized: "Waiting for the other Mac…") }
        switch remote.terminalStates[sessionID] {
        case .live: return nil
        case .ended: return String(localized: "This session isn't running on the other Mac.")
        default: return String(localized: "Loading the terminal…")
        }
    }
}

// MARK: Remote — files

/// Files and images for the other Mac (drop / ⌘V): big or odd-format images become a resized JPEG,
/// like the phone sends them.
enum RemoteUploadReader {
    static let maxPixels: CGFloat = 2000

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { !$0.hasDirectoryPath }
    }

    static func files(_ urls: [URL]) -> [RemoteUpload] {
        urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let ext = url.pathExtension.lowercased()
            let isImage = UTType(filenameExtension: ext)?.conforms(to: .image) == true && ext != "gif"
            if isImage, data.count > 1_500_000 || !RemoteUpload.imageExtensions.contains(ext), let image = NSImage(data: data) {
                return self.image(image, name: url.deletingPathExtension().lastPathComponent)
            }
            return RemoteUpload(name: url.lastPathComponent, data: data)
        }
    }

    /// PNG while small, else JPEG; at most `maxPixels` on the long side.
    static func image(_ image: NSImage, name: String) -> RemoteUpload? {
        guard var cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxPixels / CGFloat(max(cgImage.width, cgImage.height)))
        if scale < 1 {
            let width = Int(CGFloat(cgImage.width) * scale), height = Int(CGFloat(cgImage.height) * scale)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            cgImage = scaled
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if let png = rep.representation(using: .png, properties: [:]), png.count <= 1_500_000 {
            return RemoteUpload(name: name + ".png", data: png)
        }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return RemoteUpload(name: name + ".jpg", data: jpeg)
    }
}
