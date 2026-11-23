import Foundation

/// Unified diff hunks between two texts, for providers that report an edit as old and new text
/// (ACP `diff` content) instead of a patch.
enum LineDiff {
    /// Above this many old × new lines the diff is one hunk replacing the whole text, instead of
    /// a quadratic longest-common-subsequence table.
    static let maxCells = 4_000_000

    /// `@@ -a,b +c,d @@` hunks with `context` unchanged lines around each change; nil when the
    /// texts are equal.
    static func hunks(old: String, new: String, context: Int = 3) -> String? {
        guard old != new else { return nil }
        let oldLines = lines(old)
        let newLines = lines(new)
        let script = edits(oldLines, newLines)
        // Indexes of changed entries, grouped into hunks that share context.
        let changed = script.indices.filter { script[$0].marker != " " }
        guard !changed.isEmpty else { return nil }
        var groups: [ClosedRange<Int>] = []
        for index in changed {
            let range = max(0, index - context)...min(script.count - 1, index + context)
            if let last = groups.last, range.lowerBound <= last.upperBound + 1 {
                groups[groups.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                groups.append(range)
            }
        }
        var output: [String] = []
        for group in groups {
            let entries = script[group]
            let oldCount = entries.filter { $0.marker != "+" }.count
            let newCount = entries.filter { $0.marker != "-" }.count
            let first = entries.first!
            let oldStart = oldCount == 0 ? first.oldLine - 1 : first.oldLine
            let newStart = newCount == 0 ? first.newLine - 1 : first.newLine
            output.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            output.append(contentsOf: entries.map { "\($0.marker)\($0.text)" })
        }
        return output.joined(separator: "\n")
    }

    private struct Entry {
        var marker: Character
        var text: String
        /// 1-based line in the old text this entry is at (the next old line for an insertion).
        var oldLine: Int
        var newLine: Int
    }

    /// Lines without terminators; a trailing newline adds no empty last line.
    private static func lines(_ text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private static func edits(_ old: [String], _ new: [String]) -> [Entry] {
        // Common prefix and suffix first: most edits touch a few lines of a long file.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let a = Array(old[prefix..<(old.count - suffix)])
        let b = Array(new[prefix..<(new.count - suffix)])

        var entries: [Entry] = (0..<prefix).map { Entry(marker: " ", text: old[$0], oldLine: $0 + 1, newLine: $0 + 1) }
        var oldLine = prefix + 1
        var newLine = prefix + 1
        func append(_ marker: Character, _ text: String) {
            entries.append(Entry(marker: marker, text: text, oldLine: oldLine, newLine: newLine))
            if marker != "+" { oldLine += 1 }
            if marker != "-" { newLine += 1 }
        }
        if a.count * b.count > maxCells || a.isEmpty || b.isEmpty {
            for line in a { append("-", line) }
            for line in b { append("+", line) }
        } else {
            // lengths[i][j] = LCS length of a[i...] and b[j...].
            var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
            var i = 0
            var j = 0
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, a[i] == b[j] {
                    append(" ", a[i])
                    i += 1
                    j += 1
                } else if i < a.count, j == b.count || lengths[i + 1][j] >= lengths[i][j + 1] {
                    append("-", a[i])
                    i += 1
                } else {
                    append("+", b[j])
                    j += 1
                }
            }
        }
        for offset in 0..<suffix {
            append(" ", old[old.count - suffix + offset])
        }
        return entries
    }
}
