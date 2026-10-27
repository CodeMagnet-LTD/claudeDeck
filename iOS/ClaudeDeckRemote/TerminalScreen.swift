import SwiftTerm
import SwiftUI
import UIKit

/// A terminal that keeps the Mac's grid whatever its frame (the Mac owns the size).
final class FixedGridTerminalView: TerminalView {
    var gridCols = 80
    var gridRows = 24

    override func layoutSubviews() {
        super.layoutSubviews()
        enforceGrid()
    }

    @discardableResult
    func enforceGrid() -> Bool {
        let terminal = getTerminal()
        guard terminal.cols != gridCols || terminal.rows != gridRows else { return false }
        terminal.resize(cols: gridCols, rows: gridRows)
        setNeedsDisplay()
        return true
    }
}

/// The Mac's terminal at its exact grid, inside a scroll view that pans both ways. The font
/// starts at "fit the width" (at least 6 pt); pinching changes the font size.
final class RemoteTerminalUIView: UIView, @preconcurrency TerminalViewDelegate, RemoteTerminalSink {
    let scroll = UIScrollView()
    let terminal = FixedGridTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    var onInput: ((Data) -> Void)?
    var onNeedsRedraw: (() -> Void)?
    /// Fit mode: the grid this screen holds at the reading font; the Mac sizes its terminal to it.
    var onFitGrid: ((Int, Int) -> Void)?
    var fitToScreen = true {
        didSet {
            guard fitToScreen != oldValue else { return }
            fittedWidth = -1
            lastFitGrid = nil
            setNeedsLayout()
            if !fitToScreen { onFitGrid?(0, 0) }
        }
    }
    private var lastFitGrid: (Int, Int)?
    static let readingFont: CGFloat = 11
    /// nil = fit the width.
    private var chosenFontSize: CGFloat?
    private var fontSize: CGFloat = 0
    private var fittedWidth: CGFloat = -1
    private var pinchStart: CGFloat = 0
    private var scrolledToBottom = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        scroll.backgroundColor = .black
        scroll.alwaysBounceVertical = true
        scroll.showsHorizontalScrollIndicator = true
        scroll.keyboardDismissMode = .interactive
        addSubview(scroll)
        terminal.terminalDelegate = self
        terminal.isScrollEnabled = false
        terminal.nativeBackgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.1, alpha: 1)
        terminal.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        scroll.addSubview(terminal)
        scroll.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        setFont(10)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        if bounds.width != fittedWidth { fit() }
        if fitToScreen { requestFitGrid() }
    }

    /// Columns x rows of this screen at the reading font.
    private func requestFitGrid() {
        guard bounds.width > 50, bounds.height > 50 else { return }
        let font = UIFont.monospacedSystemFont(ofSize: Self.readingFont, weight: .regular)
        let cell = ("W" as NSString).size(withAttributes: [.font: font])
        let cols = Int((bounds.width - 4) / ceil(cell.width))
        let rows = Int(bounds.height / ceil(font.lineHeight + 1))
        guard lastFitGrid.map({ $0 != (cols, rows) }) ?? true else { return }
        lastFitGrid = (cols, rows)
        onFitGrid?(cols, rows)
    }

    // MARK: RemoteTerminalSink

    func start(cols: Int, rows: Int, screen: Data) {
        let changed = cols != terminal.gridCols || rows != terminal.gridRows
        terminal.gridCols = max(cols, 2)
        terminal.gridRows = max(rows, 2)
        terminal.enforceGrid()
        if changed { fit() }
        terminal.feed(byteArray: ArraySlice(screen))
        if !scrolledToBottom { scrollToCursor() }
    }

    func feed(_ bytes: Data) {
        terminal.feed(byteArray: ArraySlice(bytes))
    }

    // MARK: Layout

    private func setFont(_ size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        terminal.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func fit() {
        guard bounds.width > 0 else { return }
        fittedWidth = bounds.width
        let before = fontSize
        if let chosenFontSize {
            setFont(chosenFontSize)
        } else if fitToScreen {
            // The Mac's terminal is (or is about to be) this screen's width.
            setFont(Self.readingFont)
        } else {
            // Measure at 10 pt, scale to the width, step down until it fits.
            setFont(10)
            terminal.enforceGrid()
            let width = terminal.getOptimalFrameSize().width
            // Not below 7.5 pt (readable); a wider terminal pans sideways instead.
            var size = max(7.5, (10 * bounds.width / max(width, 1) * 2).rounded(.down) / 2)
            setFont(size)
            terminal.enforceGrid()
            while terminal.getOptimalFrameSize().width > bounds.width, size > 7.5 {
                size -= 0.5
                setFont(size)
                terminal.enforceGrid()
            }
        }
        place()
        if fontSize != before { onNeedsRedraw?() }
    }

    private func place() {
        terminal.enforceGrid()
        let size = terminal.getOptimalFrameSize().size
        let x = max(0, (bounds.width - size.width) / 2)
        terminal.frame = CGRect(x: x, y: 0, width: size.width, height: size.height)
        scroll.contentSize = CGSize(width: max(size.width, bounds.width), height: size.height)
        terminal.enforceGrid()
    }

    /// Shows the cursor's row (the prompt) after the first screen.
    private func scrollToCursor() {
        scrolledToBottom = true
        let rowHeight = terminal.getOptimalFrameSize().height / CGFloat(terminal.gridRows)
        let cursorY = CGFloat(terminal.getTerminal().getCursorLocation().y + 1) * rowHeight
        let target = min(max(0, cursorY - scroll.bounds.height * 0.7), max(0, scroll.contentSize.height - scroll.bounds.height))
        scroll.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStart = fontSize
        case .changed, .ended:
            let size = min(24, max(5, (pinchStart * gesture.scale * 2).rounded() / 2))
            guard size != fontSize else { return }
            chosenFontSize = size
            fit()
        default:
            break
        }
    }

    func toggleKeyboard() {
        if terminal.isFirstResponder { _ = terminal.resignFirstResponder() } else { _ = terminal.becomeFirstResponder() }
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
        if let url = URL(string: link), url.scheme == "http" || url.scheme == "https" { UIApplication.shared.open(url) }
    }

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

struct RemoteTerminalRepresentable: UIViewRepresentable {
    let sessionID: UUID
    let store: RemoteStore
    let keyboardToggle: Int
    let fitToScreen: Bool

    final class Coordinator {
        let sessionID: UUID
        weak var store: RemoteStore?
        var lastToggle = 0
        init(sessionID: UUID, store: RemoteStore) {
            self.sessionID = sessionID
            self.store = store
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(sessionID: sessionID, store: store) }

    func makeUIView(context: Context) -> RemoteTerminalUIView {
        let view = RemoteTerminalUIView(frame: .zero)
        let id = sessionID
        view.onInput = { [weak store] data in store?.sendTerminalInput(id, data: data) }
        view.onNeedsRedraw = { [weak store] in store?.redrawTerminal(id) }
        view.onFitGrid = { [weak store] cols, rows in store?.fitTerminal(id, cols: cols, rows: rows) }
        view.fitToScreen = fitToScreen
        store.attachTerminal(id, sink: view)
        context.coordinator.lastToggle = keyboardToggle
        return view
    }

    func updateUIView(_ view: RemoteTerminalUIView, context: Context) {
        view.fitToScreen = fitToScreen
        if keyboardToggle != context.coordinator.lastToggle {
            context.coordinator.lastToggle = keyboardToggle
            view.toggleKeyboard()
        }
    }

    static func dismantleUIView(_ view: RemoteTerminalUIView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            view.onInput = nil
            view.onNeedsRedraw = nil
            view.onFitGrid = nil
            coordinator.store?.fitTerminal(coordinator.sessionID, cols: 0, rows: 0)
            coordinator.store?.detachTerminal(coordinator.sessionID, sink: view)
        }
    }
}

/// One session: status, Allow / Deny, and its live terminal.
struct SessionDetailView: View {
    @Environment(RemoteStore.self) private var store
    let sessionID: UUID
    @State private var keyboardToggle = 0
    /// Per window: two windows can show a conversation and a terminal side by side.
    @SceneStorage("detail.mode") private var mode = Mode.conversation
    @AppStorage("terminal.fit") private var fitToScreen = true

    enum Mode: String { case conversation, terminal }

    var body: some View {
        let session = store.snapshot?.session(sessionID)
        VStack(spacing: 0) {
            if let session {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        StatusPill(state: session.state)
                        if let detail = session.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    PermissionButtons(session: session)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
            // A plain terminal has no conversation.
            let isShell = session?.state == .shell
            if !isShell {
                Picker("View", selection: $mode) {
                    Text("Conversation").tag(Mode.conversation)
                    Text("Terminal").tag(Mode.terminal)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            if mode == .conversation, !isShell {
                ConversationView(sessionID: sessionID)
            } else {
                terminal
            }
        }
        .navigationTitle(session?.name ?? String(localized: "Session"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mode == .terminal || session?.state == .shell {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { fitToScreen.toggle() } label: {
                        Image(systemName: fitToScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { keyboardToggle += 1 } label: { Image(systemName: "keyboard") }
                        .disabled(store.terminalStates[sessionID] != .live)
                }
            }
        }
    }

    private var terminal: some View {
            RemoteTerminalRepresentable(sessionID: sessionID, store: store, keyboardToggle: keyboardToggle, fitToScreen: fitToScreen)
                .overlay {
                    if let message = overlayMessage {
                        VStack(spacing: 8) {
                            if store.terminalStates[sessionID] != .ended { ProgressView() }
                            Text(message).foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
    }

    private var overlayMessage: String? {
        guard store.connection == .connected else { return String(localized: "Waiting for the other Mac…") }
        switch store.terminalStates[sessionID] {
        case .live: return nil
        case .ended: return String(localized: "This session isn't running on the other Mac.")
        default: return String(localized: "Loading the terminal…")
        }
    }
}
