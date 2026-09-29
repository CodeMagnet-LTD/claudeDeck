import Foundation

/// Fuzzy path matching for Quick Open: the query's characters must appear in order
/// (case-insensitive). Contiguous runs, word starts and matches in the file name score higher;
/// long paths score lower.
public enum FuzzyMatch {
    public struct Result: Sendable, Equatable {
        public var path: String
        public var score: Int
        /// Matched character offsets in `path` (for highlighting).
        public var positions: [Int]

        public init(path: String, score: Int, positions: [Int]) {
            self.path = path
            self.score = score
            self.positions = positions
        }
    }

    public static func score(_ query: String, in path: String) -> Result? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return Result(path: path, score: 0, positions: []) }
        let chars = Array(path)
        let lower = chars.map { Character($0.lowercased()) }
        guard q.count <= chars.count else { return nil }
        let nameStart = (chars.lastIndex(of: "/") ?? -1) + 1

        // Prefer a match that lies entirely in the file name; fall back to the whole path.
        let candidates = [nameStart, 0].compactMap { match(q, lower, chars, from: $0, nameStart: nameStart) }
        guard let best = candidates.max(by: { $0.score < $1.score }) else { return nil }
        return Result(path: path, score: best.score - chars.count, positions: best.positions)
    }

    /// Greedy left-to-right match starting at `from`, preferring word starts ahead of plain hits.
    private static func match(_ q: [Character], _ lower: [Character], _ chars: [Character],
                              from start: Int, nameStart: Int) -> (score: Int, positions: [Int])? {
        var positions: [Int] = []
        var i = start
        for (qi, c) in q.enumerated() {
            // Look ahead for a word-start occurrence before settling for the first one — unless
            // the previous match is adjacent (keep contiguous runs).
            var first: Int?
            var boundary: Int?
            var j = i
            while j < lower.count {
                if lower[j] == c {
                    if first == nil { first = j }
                    if let last = positions.last, j == last + 1 { boundary = j; break }
                    if isWordStart(chars, j) { boundary = j; break }
                }
                j += 1
            }
            guard let pick = boundary ?? first else { return nil }
            // A word start far away only wins over a nearer hit when the rest still matches.
            if let first, let boundary, boundary != first,
               !remainingMatches(Array(q[(qi + 1)...]), lower, from: boundary + 1) {
                positions.append(first); i = first + 1; continue
            }
            positions.append(pick)
            i = pick + 1
        }
        var score = 0
        for (k, p) in positions.enumerated() {
            score += 10
            if k > 0, positions[k - 1] == p - 1 { score += 25 }
            if isWordStart(chars, p) { score += 20 }
            if p >= nameStart { score += 10 }
            if p == nameStart { score += 15 }
        }
        // Gaps cost a little.
        if let firstPos = positions.first, let lastPos = positions.last {
            score -= (lastPos - firstPos + 1 - positions.count)
        }
        return (score, positions)
    }

    private static func remainingMatches(_ rest: [Character], _ lower: [Character], from: Int) -> Bool {
        var i = from
        for c in rest {
            while i < lower.count, lower[i] != c { i += 1 }
            if i == lower.count { return false }
            i += 1
        }
        return true
    }

    static func isWordStart(_ chars: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let prev = chars[i - 1], c = chars[i]
        if "/_-. ".contains(prev) { return true }
        return prev.isLowercase && c.isUppercase
    }

    /// Best `limit` matches, highest score first (ties: shorter path, then alphabetical).
    public static func rank(_ query: String, paths: [String], limit: Int = 200) -> [Result] {
        let results = paths.compactMap { score(query, in: $0) }
        return Array(results.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
            return $0.path < $1.path
        }.prefix(limit))
    }
}
