import Foundation

/// One line of a hunk with its line numbers on the old and new side.
public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable { case context, added, removed, noNewline }

    public var kind: Kind
    /// Text without the leading marker (' ', '+', '-').
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?

    /// The line number a reader means when pointing at this line: the new side, except for deletions.
    public var displayLine: Int? { kind == .removed ? oldLine : newLine }
}

public struct DiffHunk: Sendable, Equatable {
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]
    /// The hunk verbatim (header included), for rebuilding patches git can apply.
    public var raw: [String]
}

public struct DiffFile: Sendable, Equatable {
    /// `diff --git`, mode, index, `---` and `+++` lines, verbatim.
    public var header: [String]
    /// nil for `/dev/null` (added / deleted files).
    public var oldPath: String?
    public var newPath: String?
    public var hunks: [DiffHunk]
    public var isBinary: Bool

    public var path: String { newPath ?? oldPath ?? "" }
}

/// Parser for git's unified diff output (files → hunks → lines).
public enum UnifiedDiff {
    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var file: DiffFile?
        var hunk: DiffHunk?
        var oldNo = 0, newNo = 0

        func flushHunk() {
            if let h = hunk { file?.hunks.append(h) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let f = file { files.append(f) }
            file = nil
        }

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for line in lines {
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                flushFile()
                file = DiffFile(header: [line], oldPath: nil, newPath: nil, hunks: [], isBinary: false)
                let paths = gitHeaderPaths(line)
                file?.oldPath = paths.old
                file?.newPath = paths.new
                continue
            }
            if line.hasPrefix("@@"), file != nil, let parsed = parseHunkHeader(line) {
                flushHunk()
                hunk = DiffHunk(header: line, oldStart: parsed.oldStart, oldCount: parsed.oldCount,
                                newStart: parsed.newStart, newCount: parsed.newCount, lines: [], raw: [line])
                oldNo = parsed.oldStart
                newNo = parsed.newStart
                continue
            }
            if hunk != nil {
                // A line outside the hunk's body grammar ends it (e.g. trailing garbage).
                guard let marker = line.first else {
                    // An empty line inside a hunk is a context line whose space was stripped.
                    hunk?.lines.append(DiffLine(kind: .context, text: "", oldLine: oldNo, newLine: newNo))
                    hunk?.raw.append(" ")
                    oldNo += 1; newNo += 1
                    continue
                }
                let body = String(line.dropFirst())
                switch marker {
                case "+":
                    hunk?.lines.append(DiffLine(kind: .added, text: body, oldLine: nil, newLine: newNo))
                    newNo += 1
                case "-":
                    hunk?.lines.append(DiffLine(kind: .removed, text: body, oldLine: oldNo, newLine: nil))
                    oldNo += 1
                case " ":
                    hunk?.lines.append(DiffLine(kind: .context, text: body, oldLine: oldNo, newLine: newNo))
                    oldNo += 1; newNo += 1
                case "\\":
                    hunk?.lines.append(DiffLine(kind: .noNewline, text: line, oldLine: nil, newLine: nil))
                default:
                    flushHunk()
                    file?.header.append(line)
                    continue
                }
                hunk?.raw.append(line)
                continue
            }
            guard file != nil else { continue }
            file?.header.append(line)
            if line.hasPrefix("--- ") {
                file?.oldPath = headerPath(String(line.dropFirst(4)), prefix: "a/")
            } else if line.hasPrefix("+++ ") {
                file?.newPath = headerPath(String(line.dropFirst(4)), prefix: "b/")
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                file?.isBinary = true
            } else if line.hasPrefix("new file mode") {
                file?.oldPath = nil
            } else if line.hasPrefix("deleted file mode") {
                file?.newPath = nil
            } else if line.hasPrefix("rename from ") {
                file?.oldPath = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                file?.newPath = String(line.dropFirst("rename to ".count))
            }
        }
        flushFile()
        return files
    }

    /// A patch containing `file`'s header and only the hunks at `indexes`, suitable for `git apply`.
    public static func patch(_ file: DiffFile, hunks indexes: [Int]) -> String {
        var out = file.header
        for index in indexes.sorted() where file.hunks.indices.contains(index) {
            out += file.hunks[index].raw
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// `@@ -a,b +c,d @@ …` → numbers; an omitted count means 1. Combined diffs (`@@@`) use
    /// the first and last ranges.
    static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3,
              let old = parts.first(where: { $0.hasPrefix("-") }),
              let new = parts.first(where: { $0.hasPrefix("+") }) else { return nil }
        func range(_ s: Substring) -> (Int, Int)? {
            let nums = s.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(nums[0]) else { return nil }
            let count = nums.count > 1 ? Int(nums[1]) ?? 1 : 1
            return (start, count)
        }
        guard let o = range(old), let n = range(new) else { return nil }
        return (o.0, o.1, n.0, n.1)
    }

    private static func headerPath(_ raw: String, prefix: String) -> String? {
        var path = raw
        if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }   // `--- a/x\t<date>`
        if path == "/dev/null" { return nil }
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Paths from `diff --git a/x b/x` (used when there are no ---/+++ lines, e.g. binary or mode-only).
    private static func gitHeaderPaths(_ line: String) -> (old: String?, new: String?) {
        if line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
            let path = String(line.split(separator: " ", maxSplits: 2).last ?? "")
            return (path, path)
        }
        let rest = line.dropFirst("diff --git ".count)
        guard rest.hasPrefix("a/"), let range = rest.range(of: " b/", options: .backwards) else { return (nil, nil) }
        return (String(rest[rest.index(rest.startIndex, offsetBy: 2)..<range.lowerBound]),
                String(rest[range.upperBound...]))
    }
}
