import Foundation

/// Start offsets (UTF-16) of every line of a text; "\n" separates lines.
public struct LineIndex: Sendable, Equatable {
    public private(set) var starts: [Int] = [0]
    public private(set) var length = 0

    public init(_ text: NSString = "") {
        length = text.length
        guard length > 0 else { return }
        var buffer = [UInt16](repeating: 0, count: length)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: length))
        starts.reserveCapacity(length / 30 + 1)
        for i in 0..<length where buffer[i] == 10 { starts.append(i + 1) }
    }

    public var count: Int { starts.count }

    /// Line number (0-based) of a UTF-16 offset.
    public func line(containing offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The line's range without its "\n".
    public func range(ofLine line: Int) -> NSRange {
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return NSRange(location: start, length: end - start)
    }
}

/// Tokenizer state at the start of every line, kept up to date incrementally: after an edit only
/// the edited lines are re-tokenized, plus following lines until the state matches the old one again
/// (so typing "/*" re-colors to the end of the file, but ordinary typing touches one line).
public struct SyntaxLineCache: Sendable {
    public let tokenizer: SyntaxTokenizer
    public private(set) var lines = LineIndex()
    public private(set) var states: [SyntaxLineState] = [.normal]

    public init(language: SyntaxLanguage) {
        tokenizer = SyntaxTokenizer(language: language)
    }

    public mutating func rebuild(_ text: NSString) {
        lines = LineIndex(text)
        var result: [SyntaxLineState] = []
        result.reserveCapacity(lines.count)
        var state = SyntaxLineState.normal
        for k in 0..<lines.count {
            result.append(state)
            state = tokenizer.tokenize(characters(of: k, in: text), from: state).end
        }
        states = result
    }

    /// Call after `text` changed in `editedRange` (new coordinates) by `delta` UTF-16 units.
    /// Returns the lines whose coloring may have changed.
    @discardableResult
    public mutating func update(_ text: NSString, editedRange: NSRange, delta: Int) -> Range<Int> {
        let old = states
        let oldCount = lines.count
        lines = LineIndex(text)
        let lineDelta = lines.count - oldCount
        let first = min(lines.line(containing: editedRange.location), max(old.count - 1, 0))
        let lastEdited = lines.line(containing: min(editedRange.location + editedRange.length, text.length))
        var result = Array(old.prefix(first))
        result.reserveCapacity(lines.count)
        var state = first < old.count ? old[first] : .normal
        var k = first
        while k < lines.count {
            if k > lastEdited {
                let oldK = k - lineDelta
                if oldK >= 0, oldK < old.count, old[oldK] == state {
                    result.append(contentsOf: old[oldK...])
                    break
                }
            }
            result.append(state)
            state = tokenizer.tokenize(characters(of: k, in: text), from: state).end
            k += 1
        }
        states = Array(result.prefix(lines.count))
        return first..<max(k, lastEdited + 1)
    }

    /// Tokens of one line, offsets relative to the line start.
    public func tokens(ofLine line: Int, in text: NSString) -> [SyntaxToken] {
        guard line < lines.count else { return [] }
        return tokenizer.tokenize(characters(of: line, in: text), from: states[line]).tokens
    }

    private func characters(of line: Int, in text: NSString) -> [UInt16] {
        let range = lines.range(ofLine: line)
        guard range.length > 0 else { return [] }
        var buffer = [UInt16](repeating: 0, count: range.length)
        text.getCharacters(&buffer, range: range)
        return buffer
    }
}
