import Foundation

/// What a ⌘-clicked link in a terminal points to. SwiftTerm detects URLs and paths
/// (`src/a.swift`, `./x`, `~/y`, `/abs`, optionally `:line[:col]`) but resolves relative paths
/// against the app's own working directory; this resolves them against the session's folder.
public enum TerminalLink: Equatable, Sendable {
    case url(URL)
    case file(URL, line: Int?)

    /// - Parameters:
    ///   - link: the text SwiftTerm matched (or an OSC 8 target).
    ///   - directories: folders to resolve relative paths against, most specific first
    ///     (the shell's reported directory, then the session's project or worktree folder).
    public static func resolve(_ link: String, in directories: [String],
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> TerminalLink? {
        let text = link.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme.count > 1 {
            if scheme == "file" { return fileExists(url.path) ? .file(url, line: nil) : nil }
            return .url(url)
        }

        // Try the text as a path first, then without a ":line[:col]" suffix.
        var attempts: [(path: String, line: Int?)] = [(text, nil)]
        if let range = text.range(of: #":[0-9]+(?::[0-9]+)?$"#, options: .regularExpression) {
            let line = text[range].dropFirst().split(separator: ":").first.flatMap { Int($0) }
            attempts.append((String(text[..<range.lowerBound]), line))
        }
        for attempt in attempts {
            let path = (attempt.path as NSString).expandingTildeInPath
            let candidates = path.hasPrefix("/")
                ? [path]
                : directories.map { (($0 as NSString).appendingPathComponent(path) as NSString).standardizingPath }
            for candidate in candidates where fileExists(candidate) {
                return .file(URL(fileURLWithPath: candidate), line: attempt.line)
            }
        }
        return nil
    }

    /// Path from an OSC 7 `hostCurrentDirectory` value (`file://host/path` or a bare path).
    public static func directory(fromHostURI uri: String?) -> String? {
        guard let uri, !uri.isEmpty else { return nil }
        if uri.hasPrefix("/") { return uri }
        guard let url = URL(string: uri), url.scheme == "file", !url.path.isEmpty else { return nil }
        return url.path
    }
}
