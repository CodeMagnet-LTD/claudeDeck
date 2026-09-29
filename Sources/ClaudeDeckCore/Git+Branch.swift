import Foundation

extension Git {
    /// Checked-out branch of the repository at `dir`; nil when detached or not a repository.
    public static func currentBranch(in dir: URL) -> String? {
        guard let out = run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir) else { return nil }
        let branch = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty || branch == "HEAD" ? nil : branch
    }
}
