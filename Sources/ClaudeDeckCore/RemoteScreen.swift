import Foundation

// Live terminal for remote mode: the host sends the current screen once (rendered back to ANSI
// from the terminal's cells), then the raw pty output as it arrives. The remote feeds both into a
// terminal of the same size.

/// One screen cell, independent of SwiftTerm (the app maps its `CharData` to this).
public struct TermCell: Equatable, Sendable {
    public enum Color: Equatable, Sendable {
        case `default`
        case ansi(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    public struct Style: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        // Same bits as SwiftTerm's CharacterStyle.
        public static let bold = Style(rawValue: 1)
        public static let underline = Style(rawValue: 2)
        public static let blink = Style(rawValue: 4)
        public static let inverse = Style(rawValue: 8)
        public static let invisible = Style(rawValue: 16)
        public static let dim = Style(rawValue: 32)
        public static let italic = Style(rawValue: 64)
        public static let crossedOut = Style(rawValue: 128)
    }

    public var text: String
    /// Columns used: 1, 2 (wide), or 0 for the second half of a wide character (skipped).
    public var width: Int
    public var fg: Color
    public var bg: Color
    public var style: Style

    public init(text: String, width: Int = 1, fg: Color = .default, bg: Color = .default, style: Style = []) {
        self.text = text
        self.width = width
        self.fg = fg
        self.bg = bg
        self.style = style
    }

    var sameLook: (Color, Color, Style) { (fg, bg, style) }

    /// A blank that can be dropped from the end of a line.
    var isTrailingBlank: Bool { (text == " " || text.isEmpty) && bg == .default && !style.contains(.inverse) }
}

public struct TermScreen: Equatable, Sendable {
    public var cols: Int
    public var rows: Int
    /// Scrollback lines followed by the `rows` visible lines (the last `rows` entries).
    public var lines: [[TermCell]]
    /// Cursor in the visible area, 0-based.
    public var cursorX: Int
    public var cursorY: Int
    public var alternateBuffer = false
    public var applicationCursor = false
    public var bracketedPaste = false

    public init(cols: Int, rows: Int, lines: [[TermCell]], cursorX: Int, cursorY: Int) {
        self.cols = cols
        self.rows = rows
        self.lines = lines
        self.cursorX = cursorX
        self.cursorY = cursorY
    }

    /// The visible rows as plain text, trailing blanks trimmed (diagnostics, tests).
    public var visibleText: String {
        lines.suffix(rows).map { line in
            line.filter { $0.width != 0 }.map { $0.text.isEmpty ? " " : $0.text }.joined()
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    /// ANSI that redraws this screen on a fresh terminal of the same size.
    public func ansi() -> Data {
        var out = ""
        if alternateBuffer { out += "\u{1b}[?1049h" }
        out += "\u{1b}[0m\u{1b}[H\u{1b}[2J\u{1b}[3J"
        // Fewer lines than rows: pad so the visible lines land on the right rows.
        var all = lines
        if all.count < rows { all += Array(repeating: [], count: rows - all.count) }
        for (index, line) in all.enumerated() {
            if index > 0 { out += "\r\n" }
            Self.render(line, into: &out)
        }
        out += "\u{1b}[0m"
        let x = min(max(cursorX, 0), cols - 1)
        let y = min(max(cursorY, 0), rows - 1)
        out += "\u{1b}[\(y + 1);\(x + 1)H"
        if applicationCursor { out += "\u{1b}[?1h" }
        if bracketedPaste { out += "\u{1b}[?2004h" }
        return Data(out.utf8)
    }

    private static func render(_ line: [TermCell], into out: inout String) {
        var end = line.count
        while end > 0, line[end - 1].isTrailingBlank || line[end - 1].width == 0 { end -= 1 }
        var current: (TermCell.Color, TermCell.Color, TermCell.Style) = (.default, .default, [])
        for cell in line[..<end] where cell.width != 0 {
            if cell.sameLook != current {
                out += sgr(cell)
                current = cell.sameLook
            }
            out += cell.text.isEmpty ? " " : cell.text
        }
        if current != (.default, .default, []) { out += "\u{1b}[0m" }
    }

    static func sgr(_ cell: TermCell) -> String {
        var codes = ["0"]
        let styles: [(TermCell.Style, String)] = [
            (.bold, "1"), (.dim, "2"), (.italic, "3"), (.underline, "4"),
            (.blink, "5"), (.inverse, "7"), (.invisible, "8"), (.crossedOut, "9"),
        ]
        for (style, code) in styles where cell.style.contains(style) { codes.append(code) }
        if let fg = color(cell.fg, foreground: true) { codes.append(fg) }
        if let bg = color(cell.bg, foreground: false) { codes.append(bg) }
        return "\u{1b}[\(codes.joined(separator: ";"))m"
    }

    static func color(_ color: TermCell.Color, foreground: Bool) -> String? {
        switch color {
        case .default: return nil
        case .ansi(let c) where c < 8: return "\((foreground ? 30 : 40) + Int(c))"
        case .ansi(let c) where c < 16: return "\((foreground ? 90 : 100) + Int(c) - 8)"
        case .ansi(let c): return "\(foreground ? 38 : 48);5;\(c)"
        case .rgb(let r, let g, let b): return "\(foreground ? 38 : 48);2;\(r);\(g);\(b)"
        }
    }
}

/// Raw output of one session: 16 UUID bytes, then the bytes.
public enum RemoteTerminalOutput {
    public static func frame(sessionID: UUID, bytes: Data) -> RemoteFrame {
        var payload = withUnsafeBytes(of: sessionID.uuid) { Data($0) }
        payload.append(bytes)
        return RemoteFrame(kind: RemoteFrameKind.terminalOutput.rawValue, payload: payload)
    }

    public static func decode(_ frame: RemoteFrame) -> (sessionID: UUID, bytes: Data)? {
        guard frame.kind == RemoteFrameKind.terminalOutput.rawValue, frame.payload.count >= 16 else { return nil }
        let start = frame.payload.startIndex
        var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: frame.payload[start..<(start + 16)]) }
        return (UUID(uuid: raw), Data(frame.payload[(start + 16)...]))
    }
}
