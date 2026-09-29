import AppKit
import ClaudeDeckCore
import SwiftUI

/// Plain-text code editing view: TextKit 1 NSTextView with auto-indent, tab handling and a
/// current-line highlight. Syntax colors are layout-manager temporary attributes (see `SyntaxColorizer`),
/// so they never touch the text storage or the undo stack.
final class CodeTextView: NSTextView {
    var indentation = Indentation() { didSet { updateTabStops() } }
    var language: SyntaxLanguage = .plain

    static func make() -> CodeTextView {
        let view = CodeTextView(usingTextLayoutManager: false)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFontPanel = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.layoutManager?.allowsNonContiguousLayout = true
        return view
    }

    var codeFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { if codeFont != oldValue { applyStyle() } }
    }

    /// The live text without bridging it to a Swift String (which copies the whole file).
    var text: NSString { textStorage?.mutableString ?? "" }

    private func updateTabStops() { applyStyle() }

    /// Font, tab width and text color on the whole text and for typing.
    func applyStyle() {
        font = codeFont
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        let space = (" " as NSString).size(withAttributes: [.font: codeFont]).width
        style.defaultTabInterval = space * CGFloat(max(indentation.width, 1))
        defaultParagraphStyle = style
        typingAttributes = [.font: codeFont, .paragraphStyle: style, .foregroundColor: NSColor.textColor]
        if let storage = textStorage, storage.length > 0 {
            // Attribute-only change: keep it out of the undo stack.
            storage.beginEditing()
            storage.addAttributes([.font: codeFont, .paragraphStyle: style, .foregroundColor: NSColor.textColor], range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
    }

    // MARK: Editing behaviour

    /// Find bar keys, whether or not the menu bar has Find items: ⌘F, ⌥⌘F (replace), ⌘G / ⇧⌘G, ⌘E.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let action: NSTextFinder.Action? = switch (mods, key) {
        case ([.command], "f"): .showFindInterface
        case ([.command, .option], "f"): .showReplaceInterface
        case ([.command], "g"): .nextMatch
        case ([.command, .shift], "g"): .previousMatch
        case ([.command], "e"): .setSearchString
        default: nil
        }
        guard let action else { return super.performKeyEquivalent(with: event) }
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
        return true
    }

    /// New line keeps the current line's indentation, one level deeper after an opening bracket
    /// (or ":" in Python / YAML).
    override func insertNewline(_ sender: Any?) {
        let text = self.text
        let caret = selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        let beforeCaret = text.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        var indent = String(beforeCaret.prefix { $0 == " " || $0 == "\t" })
        let trimmed = beforeCaret.trimmingCharacters(in: .whitespaces)
        if let last = trimmed.last, "{[(".contains(last) || (last == ":" && (language == .python || language == .yaml)) {
            indent += indentation.unit
        }
        insertText("\n" + indent, replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        if selectedLinesSpanMultiple() { shiftSelectedLines(by: 1); return }
        insertText(indentation.unit, replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) { shiftSelectedLines(by: -1) }

    private func selectedLinesSpanMultiple() -> Bool {
        let range = selectedRange()
        guard range.length > 0 else { return false }
        return text.substring(with: range).contains("\n")
    }

    /// Indents (+1) or outdents (-1) every line touched by the selection, as one undo step.
    private func shiftSelectedLines(by direction: Int) {
        let text = self.text
        let lines = text.lineRange(for: selectedRange())
        let block = text.substring(with: lines)
        var out: [String] = []
        for line in block.components(separatedBy: "\n") {
            if direction > 0 {
                out.append(line.isEmpty ? line : indentation.unit + line)
            } else if line.hasPrefix("\t") {
                out.append(String(line.dropFirst()))
            } else {
                let spaces = min(line.prefix { $0 == " " }.count, indentation.width)
                out.append(String(line.dropFirst(spaces)))
            }
        }
        let replacement = out.joined(separator: "\n")
        guard replacement != block, shouldChangeText(in: lines, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: lines, with: replacement)
        didChangeText()
        let trailingNewline = replacement.hasSuffix("\n") ? 1 : 0
        setSelectedRange(NSRange(location: lines.location, length: (replacement as NSString).length - trailingNewline))
    }

    // MARK: Current line highlight

    static let currentLineColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.black.withAlphaComponent(0.045)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lineRect = currentLineRect() else { return }
        Self.currentLineColor.setFill()
        NSRect(x: 0, y: lineRect.minY, width: bounds.width, height: lineRect.height).intersection(rect).fill()
    }

    private func currentLineRect() -> NSRect? {
        let selection = selectedRange()
        guard selection.length == 0, let layout = layoutManager, let container = textContainer else { return nil }
        let text = self.text
        if selection.location >= text.length, text.length == 0 || text.character(at: text.length - 1) == 10 {
            let extra = layout.extraLineFragmentRect
            return extra.isEmpty ? nil : extra.offsetBy(dx: 0, dy: textContainerOrigin.y)
        }
        let line = text.lineRange(for: NSRange(location: min(selection.location, text.length), length: 0))
        let glyphs = layout.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return rect.offsetBy(dx: 0, dy: textContainerOrigin.y)
    }

    private var lastHighlightRect: NSRect?

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        let new = currentLineRect()
        for rect in [lastHighlightRect, new].compactMap({ $0 }) {
            setNeedsDisplay(NSRect(x: 0, y: rect.minY - 1, width: bounds.width, height: rect.height + 2))
        }
        lastHighlightRect = new
    }
}

// MARK: - Syntax colors

/// Keeps `SyntaxLineCache` in sync with the text storage and paints the visible lines.
@MainActor
final class SyntaxColorizer: NSObject, NSTextStorageDelegate {
    private weak var textView: CodeTextView?
    private(set) var cache: SyntaxLineCache
    private var scheduled = false

    init(textView: CodeTextView, language: SyntaxLanguage) {
        self.textView = textView
        cache = SyntaxLineCache(language: language)
        super.init()
        cache.rebuild(textView.text)
        textView.textStorage?.delegate = self
    }

    var lines: LineIndex { cache.lines }

    func rebuild() {
        guard let textView else { return }
        cache.rebuild(textView.text)
        scheduleRecolor()
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        nonisolated(unsafe) let storage = textStorage
        MainActor.assumeIsolated {
            cache.update(storage.mutableString, editedRange: editedRange, delta: delta)
            scheduleRecolor()
        }
    }

    /// Recolors on the next run-loop turn (temporary attributes can't change mid-edit).
    func scheduleRecolor() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.recolorVisible()
            }
        }
    }

    func recolorVisible() {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
              cache.tokenizer.language != .plain else { return }
        let text: NSString = textView.textStorage?.mutableString ?? ""
        guard text.length > 0 else { return }
        var visible = textView.visibleRect
        visible = visible.insetBy(dx: 0, dy: -visible.height / 2) // a little ahead while scrolling
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let firstLine = cache.lines.line(containing: chars.location)
        let lastLine = cache.lines.line(containing: max(chars.location, NSMaxRange(chars) - 1))
        let start = cache.lines.starts[firstLine]
        let endRange = cache.lines.range(ofLine: lastLine)
        let span = NSRange(location: start, length: min(NSMaxRange(endRange), text.length) - start)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: span)
        for line in firstLine...lastLine {
            let lineStart = cache.lines.starts[line]
            for token in cache.tokens(ofLine: line, in: text) {
                let range = NSRange(location: lineStart + token.range.lowerBound, length: token.range.count)
                guard NSMaxRange(range) <= text.length else { continue }
                layout.addTemporaryAttribute(.foregroundColor, value: SyntaxPalette.color(for: token.kind), forCharacterRange: range)
            }
        }
    }
}

/// Xcode-like colors, resolved at draw time for light / dark appearance.
enum SyntaxPalette {
    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    static let keyword = dynamic(light: 0x9B2393, dark: 0xFF7AB2)
    static let string = dynamic(light: 0xC41A16, dark: 0xFC6A5D)
    static let comment = dynamic(light: 0x5D6C79, dark: 0x7F8C98)
    static let number = dynamic(light: 0x1C00CF, dark: 0xD9C97C)
    static let type = dynamic(light: 0x0B4F79, dark: 0x5DD8FF)
    static let attribute = dynamic(light: 0x815F03, dark: 0xFD8F3F)
    static let heading = dynamic(light: 0x0F68A0, dark: 0x6BDFFF)

    static func color(for kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword, .tag: keyword
        case .string: string
        case .comment: comment
        case .number: number
        case .type, .variable: type
        case .attribute: attribute
        case .heading: heading
        }
    }
}

// MARK: - Line numbers

final class LineNumberRuler: NSRulerView {
    weak var colorizer: SyntaxColorizer?
    private var textView: NSTextView? { clientView as? NSTextView }

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { true }

    private var labelFont: NSFont {
        let size = (textView?.font?.pointSize ?? 13) * 0.85
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    /// Wide enough for the largest line number.
    func updateThickness() {
        let count = colorizer?.lines.count ?? 1
        let digits = max(String(count).count, 2)
        let width = (String(repeating: "8", count: digits) as NSString).size(withAttributes: [.font: labelFont]).width + 16
        if abs(ruleThickness - width) > 0.5 { ruleThickness = ceil(width) }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
              let lines = colorizer?.lines else { return }
        let text: NSString = textView.textStorage?.mutableString ?? ""
        let visible = textView.visibleRect
        let containerOrigin = textView.textContainerOrigin
        let caretLine = lines.line(containing: min(textView.selectedRange().location, text.length))
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let current: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]

        /// `fragment` is in text container coordinates; converting the rect works whether or not
        /// the ruler is flipped.
        func draw(_ number: Int, fragment: NSRect) {
            let rect = convert(fragment.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y), from: textView)
            let label = String(number + 1) as NSString
            let style = number == caretLine ? current : attrs
            let size = label.size(withAttributes: style)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: rect.midY - size.height / 2), withAttributes: style)
        }

        if text.length > 0 {
            let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
            let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            var line = lines.line(containing: chars.location)
            while line < lines.count, lines.starts[line] <= NSMaxRange(chars), lines.starts[line] < text.length {
                let glyph = layout.glyphIndexForCharacter(at: lines.starts[line])
                let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
                draw(line, fragment: fragment)
                line += 1
            }
        }
        let extra = layout.extraLineFragmentRect
        if !extra.isEmpty {
            draw(lines.count - 1, fragment: extra)
        }
    }
}

// MARK: - SwiftUI wrapper

struct CodeEditorView: NSViewRepresentable {
    let document: EditorDocument
    var fontSize: Double
    var wrapLines: Bool

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .noBorder

        let textView = CodeTextView.make()
        textView.language = document.language
        textView.indentation = document.indentation
        textView.codeFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.string = document.initialText
        textView.applyStyle()
        textView.delegate = context.coordinator
        scroll.documentView = textView

        let colorizer = SyntaxColorizer(textView: textView, language: document.language)
        let ruler = LineNumberRuler(textView: textView)
        ruler.colorizer = colorizer
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.attach(textView: textView, colorizer: colorizer, ruler: ruler, scroll: scroll)
        applyWrap(wrapLines, to: textView, in: scroll)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        document.attach(textView, colorizer: colorizer)
        ruler.updateThickness()
        colorizer.scheduleRecolor()
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? CodeTextView else { return }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.codeFont.pointSize != font.pointSize {
            textView.codeFont = font
            context.coordinator.ruler?.updateThickness()
            context.coordinator.colorizer?.scheduleRecolor()
        }
        if context.coordinator.wrap != wrapLines { applyWrap(wrapLines, to: textView, in: scroll) }
        context.coordinator.wrap = wrapLines
    }

    private func applyWrap(_ wrap: Bool, to textView: NSTextView, in scroll: NSScrollView) {
        guard let container = textView.textContainer else { return }
        scroll.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        container.widthTracksTextView = wrap
        if wrap {
            container.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            textView.frame.size.width = scroll.contentSize.width
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        textView.autoresizingMask = wrap ? [.width] : []
        (scroll.verticalRulerView as? LineNumberRuler)?.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let document: EditorDocument
        var wrap: Bool?
        private(set) weak var colorizer: SyntaxColorizer?
        private(set) weak var ruler: LineNumberRuler?
        private var colorizerRef: SyntaxColorizer?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        init(document: EditorDocument) { self.document = document }

        func attach(textView: CodeTextView, colorizer: SyntaxColorizer, ruler: LineNumberRuler, scroll: NSScrollView) {
            colorizerRef = colorizer
            self.colorizer = colorizer
            self.ruler = ruler
            scroll.contentView.postsBoundsChangedNotifications = true
            let center = NotificationCenter.default
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(center.addObserver(forName: name, object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.colorizer?.scheduleRecolor()
                        self?.ruler?.needsDisplay = true
                    }
                })
            }
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        func textDidChange(_ notification: Notification) {
            document.noteEdit()
            ruler?.updateThickness()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            document.updateCaret(textView.selectedRange())
            ruler?.needsDisplay = true
        }
    }
}
