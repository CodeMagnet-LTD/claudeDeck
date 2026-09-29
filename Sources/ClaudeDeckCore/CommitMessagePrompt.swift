import Foundation

/// Prompt for `claude -p` to write a commit message, and cleanup of its reply.
public enum CommitMessagePrompt {
    public static let patchLimit = 40_000

    // Adapted from MonoCode (MIT): buildCommitMessagePrompt, asking for plain text instead of JSON.
    public static func build(branch: String?, stat: String, patch: String) -> String {
        [
            "You write concise git commit messages.",
            "Do not call tools. Reply with the commit message only, as plain text: no code fences, no quotes, no preamble.",
            "Rules:",
            "- first line: a conventional-commit style subject (e.g. \"fix: …\", \"feat(ui): …\"), imperative, at most 72 characters, no trailing period",
            "- then optionally a blank line and a short body (a few lines or bullet points) explaining what and why",
            "- capture the primary user-visible or developer-visible change",
            "",
            "Branch: \(branch ?? "(detached)")",
            "",
            "Changed files:",
            limit(stat, 6_000),
            "",
            "Patch:",
            limit(patch, patchLimit),
        ].joined(separator: "\n")
    }

    static func limit(_ text: String, _ count: Int) -> String {
        text.count <= count ? text : String(text.prefix(count)) + "\n… (truncated)"
    }

    /// Strips code fences and surrounding blank lines the model may add anyway.
    public static func clean(_ reply: String) -> String {
        var lines = reply.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
