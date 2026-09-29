import Foundation

/// Languages the built-in editor colors. Everything else is plain text.
public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case plain, swift, javascript, typescript, json, python, go, rust, shell, yaml, markdown, html, css, c

    /// Picks a language from a file name (extension, or a few well-known names).
    public static func detect(fileName: String) -> SyntaxLanguage {
        let lower = fileName.lowercased()
        switch lower {
        case "dockerfile", "makefile", ".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", ".env": return .shell
        case "package.json", "tsconfig.json", ".prettierrc", ".eslintrc": return .json
        default: break
        }
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "json", "jsonc", "json5", "jsonl": return .json
        case "py", "pyw", "pyi": return .python
        case "go": return .go
        case "rs": return .rust
        case "sh", "bash", "zsh", "fish", "command": return .shell
        case "yml", "yaml": return .yaml
        case "md", "markdown", "mdx": return .markdown
        case "html", "htm", "xml", "plist", "svg", "xib", "storyboard", "vue", "svelte": return .html
        case "css", "scss", "less": return .css
        case "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "java", "kt", "kts", "cs": return .c
        default: return .plain
        }
    }
}

public enum SyntaxTokenKind: Sendable, Equatable {
    case keyword, string, comment, number, type, attribute, heading, tag, variable
}

/// A colored span of one line, in UTF-16 offsets from the line start (NSString/NSRange units).
public struct SyntaxToken: Sendable, Equatable {
    public var kind: SyntaxTokenKind
    public var range: Range<Int>

    public init(_ kind: SyntaxTokenKind, _ range: Range<Int>) {
        self.kind = kind
        self.range = range
    }
}

/// What carries over from one line to the next.
public enum SyntaxLineState: Hashable, Sendable {
    case normal
    case blockComment
    /// Inside a multi-line string (or Markdown code fence) that ends with `close`.
    case string(close: String)
}

/// A small line-at-a-time tokenizer: keywords, strings, comments, numbers and a few
/// language-specific extras. Not a parser; good enough for coloring and fast enough to run
/// per keystroke on the edited lines.
public struct SyntaxTokenizer: Sendable {
    public let language: SyntaxLanguage
    private let spec: Spec

    public init(language: SyntaxLanguage) {
        self.language = language
        self.spec = Spec.for(language)
    }

    public func tokenize(_ line: String, from state: SyntaxLineState = .normal) -> (tokens: [SyntaxToken], end: SyntaxLineState) {
        tokenize(Array(line.utf16), from: state)
    }

    public func tokenize(_ s: [UInt16], from state: SyntaxLineState) -> (tokens: [SyntaxToken], end: SyntaxLineState) {
        guard language != .plain else { return ([], .normal) }
        var tokens: [SyntaxToken] = []
        var i = 0
        let n = s.count

        // Continue a construct from the previous line.
        switch state {
        case .normal: break
        case .blockComment:
            guard let close = spec.blockComment?.1 else { break }
            if let end = find(close, in: s, from: 0) {
                tokens.append(SyntaxToken(.comment, 0..<end + close.count))
                i = end + close.count
            } else {
                return (n > 0 ? [SyntaxToken(.comment, 0..<n)] : [], .blockComment)
            }
        case .string(let close):
            let closeUnits = Array(close.utf16)
            if language == .markdown {
                // Code fence: ends on a line that starts with the fence.
                let trimmed = s.drop { $0 == 32 }
                if Array(trimmed.prefix(closeUnits.count)) == closeUnits {
                    return (n > 0 ? [SyntaxToken(.string, 0..<n)] : [], .normal)
                }
                return (n > 0 ? [SyntaxToken(.string, 0..<n)] : [], state)
            }
            if let end = findUnescaped(closeUnits, in: s, from: 0) {
                tokens.append(SyntaxToken(.string, 0..<end + closeUnits.count))
                i = end + closeUnits.count
            } else {
                return (n > 0 ? [SyntaxToken(.string, 0..<n)] : [], state)
            }
        }

        switch language {
        case .markdown: return markdown(s, from: i, tokens: tokens)
        case .html: return html(s, from: i, tokens: tokens)
        default: break
        }

        let lineHasBrace = s.contains(123) // "{", for the CSS property heuristic
        let firstNonSpace = s.firstIndex { $0 != 32 && $0 != 9 } ?? n

        while i < n {
            let c = s[i]

            // Line comments.
            if let lc = spec.lineComments.first(where: { matches($0, in: s, at: i) }) {
                if !spec.hashNeedsSpace || lc != [35] || i == 0 || s[i - 1] == 32 || s[i - 1] == 9 {
                    tokens.append(SyntaxToken(.comment, i..<n))
                    return (tokens, .normal)
                }
            }
            // Block comments.
            if let (open, close) = spec.blockComment, matches(open, in: s, at: i) {
                if let end = find(close, in: s, from: i + open.count) {
                    tokens.append(SyntaxToken(.comment, i..<end + close.count))
                    i = end + close.count
                    continue
                }
                tokens.append(SyntaxToken(.comment, i..<n))
                return (tokens, .blockComment)
            }
            // Multi-line strings (""" ''' `).
            if let delim = spec.multilineStrings.first(where: { matches($0, in: s, at: i) }) {
                if let end = findUnescaped(delim, in: s, from: i + delim.count) {
                    tokens.append(SyntaxToken(.string, i..<end + delim.count))
                    i = end + delim.count
                    continue
                }
                tokens.append(SyntaxToken(.string, i..<n))
                return (tokens, .string(close: String(decoding: delim, as: UTF16.self)))
            }
            // Single-line strings.
            if spec.quotes.contains(c) {
                if language == .rust, c == 39, !isRustCharLiteral(s, at: i) { i += 1; continue }
                let end = stringEnd(s, from: i + 1, quote: c)
                let range = i..<end
                if isKey(s, after: end) && (language == .json || language == .yaml) {
                    tokens.append(SyntaxToken(.attribute, range))
                } else {
                    tokens.append(SyntaxToken(.string, range))
                }
                i = end
                continue
            }
            // Numbers.
            if isDigit(c) || (c == 46 && i + 1 < n && isDigit(s[i + 1]) && (i == 0 || !isIdent(s[i - 1]))) {
                if i > 0 && isIdent(s[i - 1]) { i += 1; continue }
                var j = i + 1
                while j < n && (isIdent(s[j]) || s[j] == 46 || ((s[j] == 43 || s[j] == 45) && (s[j - 1] == 101 || s[j - 1] == 69) && !isHexPrefix(s, i))) {
                    if s[j] == 46 && !(j + 1 < n && isDigit(s[j + 1])) { break }
                    j += 1
                }
                tokens.append(SyntaxToken(.number, i..<j))
                i = j
                continue
            }
            // CSS hex colors.
            if language == .css, c == 35, i + 1 < n, isHexDigit(s[i + 1]), !lineHasBrace {
                var j = i + 1
                while j < n && isIdent(s[j]) { j += 1 }
                tokens.append(SyntaxToken(.number, i..<j))
                i = j
                continue
            }
            // Attributes / decorators / at-rules.
            if c == 64, spec.atAttributes, i + 1 < n, isIdentStart(s[i + 1]) {
                var j = i + 1
                while j < n && (isIdent(s[j]) || (language == .css && s[j] == 45)) { j += 1 }
                tokens.append(SyntaxToken(language == .css ? .keyword : .attribute, i..<j))
                i = j
                continue
            }
            // Shell variables.
            if language == .shell, c == 36, i + 1 < n {
                var j = i + 1
                if s[j] == 123 { // ${...}
                    while j < n && s[j] != 125 { j += 1 }
                    j = min(j + 1, n)
                } else if isShellSpecial(s[j]) { // $? $1 $#
                    j += 1
                } else {
                    while j < n && isIdent(s[j]) { j += 1 }
                }
                if j > i + 1 {
                    tokens.append(SyntaxToken(.variable, i..<j))
                    i = j
                    continue
                }
            }
            // Identifiers and keywords.
            if isIdentStart(c) {
                var j = i + 1
                while j < n && (isIdent(s[j]) || (spec.dashInIdentifiers && s[j] == 45)) { j += 1 }
                let word = Array(s[i..<j])
                if language == .yaml, i == firstNonSpace || isAfterListDash(s, i), isKey(s, after: j) {
                    tokens.append(SyntaxToken(.attribute, i..<j))
                } else if language == .css, isKey(s, after: j), !lineHasBrace {
                    tokens.append(SyntaxToken(.attribute, i..<j))
                } else if spec.keywords.contains(word) {
                    tokens.append(SyntaxToken(.keyword, i..<j))
                } else if spec.capitalizedTypes, c >= 65, c <= 90 {
                    tokens.append(SyntaxToken(.type, i..<j))
                }
                i = j
                continue
            }
            i += 1
        }
        return (tokens, .normal)
    }

    // MARK: Markdown / HTML

    private func markdown(_ s: [UInt16], from start: Int, tokens: [SyntaxToken]) -> ([SyntaxToken], SyntaxLineState) {
        var tokens = tokens
        let n = s.count
        let indent = s.prefix { $0 == 32 }.count
        let rest = s[indent...]
        // Code fence opens: the rest of the block is "string" until the same fence.
        for fence in ["```", "~~~"] where rest.starts(with: fence.utf16) {
            tokens.append(SyntaxToken(.string, 0..<n))
            return (tokens, .string(close: fence))
        }
        let hashes = rest.prefix { $0 == 35 }.count
        if hashes >= 1, hashes <= 6, indent + hashes == n || s[indent + hashes] == 32 {
            tokens.append(SyntaxToken(.heading, 0..<n))
            return (tokens, .normal)
        }
        if rest.first == 62 { // "> quote"
            tokens.append(SyntaxToken(.comment, 0..<n))
            return (tokens, .normal)
        }
        var i = start
        while i < n {
            if s[i] == 96, let end = find([96], in: s, from: i + 1) { // `inline code`
                tokens.append(SyntaxToken(.string, i..<end + 1))
                i = end + 1
            } else {
                i += 1
            }
        }
        return (tokens, .normal)
    }

    private func html(_ s: [UInt16], from start: Int, tokens: [SyntaxToken]) -> ([SyntaxToken], SyntaxLineState) {
        var tokens = tokens
        let n = s.count
        let open = Array("<!--".utf16), close = Array("-->".utf16)
        var i = start
        var inTag = false
        while i < n {
            let c = s[i]
            if matches(open, in: s, at: i) {
                if let end = find(close, in: s, from: i + 4) {
                    tokens.append(SyntaxToken(.comment, i..<end + 3))
                    i = end + 3
                    continue
                }
                tokens.append(SyntaxToken(.comment, i..<n))
                return (tokens, .blockComment)
            }
            if c == 60 { // "<" tag name
                var j = i + 1
                if j < n && (s[j] == 47 || s[j] == 33 || s[j] == 63) { j += 1 }
                let nameStart = j
                while j < n && (isIdent(s[j]) || s[j] == 45 || s[j] == 58) { j += 1 }
                if j > nameStart {
                    tokens.append(SyntaxToken(.tag, i..<j))
                    inTag = true
                    i = j
                    continue
                }
            } else if c == 62 { // ">"
                inTag = false
            } else if inTag, c == 34 || c == 39 {
                let end = stringEnd(s, from: i + 1, quote: c)
                tokens.append(SyntaxToken(.string, i..<end))
                i = end
                continue
            } else if inTag, isIdentStart(c) {
                var j = i + 1
                while j < n && (isIdent(s[j]) || s[j] == 45 || s[j] == 58) { j += 1 }
                tokens.append(SyntaxToken(.attribute, i..<j))
                i = j
                continue
            } else if c == 38 { // &entity;
                var j = i + 1
                while j < n && (isIdent(s[j]) || s[j] == 35) { j += 1 }
                if j < n && s[j] == 59 {
                    tokens.append(SyntaxToken(.number, i..<j + 1))
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return (tokens, .normal)
    }

    // MARK: Scanning helpers

    private func matches(_ pattern: [UInt16], in s: [UInt16], at i: Int) -> Bool {
        guard !pattern.isEmpty, i + pattern.count <= s.count else { return false }
        for k in 0..<pattern.count where s[i + k] != pattern[k] { return false }
        return true
    }

    private func find(_ pattern: [UInt16], in s: [UInt16], from start: Int) -> Int? {
        var i = start
        while i + pattern.count <= s.count {
            if matches(pattern, in: s, at: i) { return i }
            i += 1
        }
        return nil
    }

    /// Like `find`, skipping backslash-escaped characters.
    private func findUnescaped(_ pattern: [UInt16], in s: [UInt16], from start: Int) -> Int? {
        var i = start
        while i + pattern.count <= s.count {
            if s[i] == 92 { i += 2; continue }
            if matches(pattern, in: s, at: i) { return i }
            i += 1
        }
        return nil
    }

    /// End (exclusive) of a string whose opening quote is just before `from`; the line end if unclosed.
    private func stringEnd(_ s: [UInt16], from: Int, quote: UInt16) -> Int {
        var j = from
        while j < s.count {
            if s[j] == 92 && spec.backslashEscapes { j += 2; continue }
            if s[j] == quote { return j + 1 }
            j += 1
        }
        return s.count
    }

    /// Followed (after spaces) by ":" — a JSON/YAML key or CSS property.
    private func isKey(_ s: [UInt16], after end: Int) -> Bool {
        var j = end
        while j < s.count && s[j] == 32 { j += 1 }
        guard j < s.count, s[j] == 58 else { return false }
        // "a::b" or YAML "key:value" without space is not a key (except at line end).
        if language == .yaml { return j + 1 == s.count || s[j + 1] == 32 }
        return j + 1 == s.count || s[j + 1] != 58
    }

    private func isAfterListDash(_ s: [UInt16], _ i: Int) -> Bool {
        guard i >= 2, s[i - 1] == 32, s[i - 2] == 45 else { return false }
        return s[..<(i - 2)].allSatisfy { $0 == 32 }
    }

    private func isRustCharLiteral(_ s: [UInt16], at i: Int) -> Bool {
        guard i + 2 < s.count else { return false }
        if s[i + 1] == 92 { return true } // '\n'
        return s[i + 2] == 39             // 'x'
    }

    private func isHexPrefix(_ s: [UInt16], _ i: Int) -> Bool {
        i + 1 < s.count && s[i] == 48 && (s[i + 1] == 120 || s[i + 1] == 88)
    }

    private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private func isHexDigit(_ c: UInt16) -> Bool { isDigit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) }
    private func isIdentStart(_ c: UInt16) -> Bool { (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 || (c == 36 && spec.dollarInIdentifiers) }
    private func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
    private func isShellSpecial(_ c: UInt16) -> Bool { [35, 63, 64, 42, 33, 36, 48].contains(c) || isDigit(c) } // # ? @ * ! $ digits
}

// MARK: Language tables

private struct Spec: Sendable {
    var lineComments: [[UInt16]] = []
    var blockComment: ([UInt16], [UInt16])?
    var quotes: Set<UInt16> = [34, 39]
    var multilineStrings: [[UInt16]] = []
    var keywords: Set<[UInt16]> = []
    var capitalizedTypes = false
    var atAttributes = false
    var dashInIdentifiers = false
    var dollarInIdentifiers = false
    var hashNeedsSpace = false
    var backslashEscapes = true

    static func u(_ s: String) -> [UInt16] { Array(s.utf16) }
    static func words(_ s: String) -> Set<[UInt16]> { Set(s.split(separator: " ").map { Array($0.utf16) }) }

    static let cComments: ([UInt16], [UInt16]) = (u("/*"), u("*/"))

    static func `for`(_ language: SyntaxLanguage) -> Spec {
        var spec = Spec()
        switch language {
        case .plain, .markdown:
            break
        case .html:
            spec.blockComment = (u("<!--"), u("-->"))
        case .swift:
            spec.lineComments = [u("//")]
            spec.blockComment = cComments
            spec.quotes = [34]
            spec.multilineStrings = [u("\"\"\"")]
            spec.capitalizedTypes = true
            spec.atAttributes = true
            spec.keywords = words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as false is nil self Self super throws true try await async actor nonisolated isolated some any consuming borrowing mutating nonmutating override final lazy weak unowned required convenience dynamic indirect get set willSet didSet macro package sending")
        case .javascript, .typescript:
            spec.lineComments = [u("//")]
            spec.blockComment = cComments
            spec.multilineStrings = [u("`")]
            spec.capitalizedTypes = language == .typescript
            spec.atAttributes = true
            spec.dollarInIdentifiers = true
            var kw = "break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return super switch this throw try typeof var void while with yield async await of static get set null undefined true false from as"
            if language == .typescript {
                kw += " type interface enum implements private protected public readonly abstract declare namespace module keyof infer is satisfies never unknown any string number boolean symbol bigint object override accessor"
            }
            spec.keywords = words(kw)
        case .json:
            spec.quotes = [34]
            spec.lineComments = [u("//")]
            spec.blockComment = cComments
            spec.keywords = words("true false null")
        case .python:
            spec.lineComments = [u("#")]
            spec.multilineStrings = [u("\"\"\""), u("'''")]
            spec.atAttributes = true
            spec.keywords = words("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls")
        case .go:
            spec.lineComments = [u("//")]
            spec.blockComment = cComments
            spec.multilineStrings = [u("`")]
            spec.keywords = words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false iota bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any")
        case .rust:
            spec.lineComments = [u("//")]
            spec.blockComment = cComments
            spec.quotes = [34, 39]
            spec.capitalizedTypes = true
            spec.keywords = words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while macro_rules union i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str")
        case .shell:
            spec.lineComments = [u("#")]
            spec.hashNeedsSpace = true
            spec.keywords = words("if then else elif fi case esac for select while until do done in function return exit local export readonly declare unset shift source alias set trap break continue eval exec true false echo printf cd test")
        case .yaml:
            spec.lineComments = [u("#")]
            spec.hashNeedsSpace = true
            spec.dashInIdentifiers = true
            spec.keywords = words("true false null yes no on off True False Null ~")
        case .css:
            spec.blockComment = cComments
            spec.lineComments = [] // "//" only in SCSS/Less; would break url(http://…)
            spec.dashInIdentifiers = true
            spec.atAttributes = true
            spec.keywords = words("important inherit initial unset none auto")
        case .c:
            spec.lineComments = [u("//")]
            spec.blockComment = cComments
            spec.capitalizedTypes = true
            spec.atAttributes = true
            spec.keywords = words("auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false nullptr NULL class namespace template typename public private protected virtual override new delete this throw try catch using import package interface extends implements final abstract synchronized val var fun when object is in null self super nil YES NO id")
        }
        return spec
    }
}
