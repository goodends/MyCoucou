import Foundation

// MARK: - Types

struct DiffLine: Equatable {
    enum Kind: Equatable { case context, added, removed }
    var kind: Kind
    var text: String
    var origLine: Int   // 1-based; -1 for pure adds
    var newLine: Int    // 1-based; -1 for pure removes
}

struct DiffHunk: Equatable {
    var origStart: Int
    var newStart: Int
    var lines: [DiffLine]
}

struct FileDiff: Equatable {
    var id: Int = 0         // stable identifier assigned by AppState.appendSessionDiff
    var path: String
    var added: Int
    var removed: Int
    var hunks: [DiffHunk]
    var tooLarge: Bool
    var isNewFile: Bool     // true when produced by DiffEngine.fromNew (Write tool)

    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    static let maxBytes = 200 * 1024
    static let maxLines = 4000
}

/// One row in the per-session changes list: everything one session did to one
/// file, rolled up.
///
/// `added` / `removed` accumulate over every edit to the path, so a line
/// touched twice counts twice. That is intentional — the number is "how much
/// churn", not a patch. To show the actual change, open `lastDiffId`, which is
/// the most recent single diff for this file.
struct FileChange: Identifiable {
    var id: String { path }
    let path: String
    var added: Int
    var removed: Int
    var editCount: Int
    var isNewFile: Bool
    var lastDiffId: Int
}

// MARK: - DiffLedger

enum DiffLedger {
    /// Roll one session's diffs up per file, most recently edited first.
    ///
    /// Ties on `lastDiffId` cannot happen: ids come from one monotonic counter
    /// in AppState, so the ordering is stable without a secondary key.
    static func fileChanges(from diffs: [FileDiff]) -> [FileChange] {
        var byPath: [String: FileChange] = [:]
        for d in diffs {
            if var existing = byPath[d.path] {
                existing.added += d.added
                existing.removed += d.removed
                existing.editCount += 1
                existing.lastDiffId = d.id
                // Once a file has been created by this session it stays
                // "new", even once it is edited again.
                existing.isNewFile = existing.isNewFile || d.isNewFile
                byPath[d.path] = existing
            } else {
                byPath[d.path] = FileChange(path: d.path, added: d.added,
                                            removed: d.removed, editCount: 1,
                                            isNewFile: d.isNewFile, lastDiffId: d.id)
            }
        }
        return byPath.values.sorted { $0.lastDiffId > $1.lastDiffId }
    }
}

// MARK: - DiffEngine

enum DiffEngine {

    // MARK: Public API

    static func fromEdit(old: String, new: String, path: String) -> FileDiff {
        // Size guard
        if old.utf8.count + new.utf8.count > FileDiff.maxBytes {
            return countFallback(old: old, new: new, path: path, tooLarge: true)
        }
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        if oldLines.count + newLines.count > FileDiff.maxLines {
            return countFallback(old: old, new: new, path: path, tooLarge: true)
        }
        // LCS is O(m*n) — bail out before quadratic blowup
        if oldLines.count * newLines.count > 1_000_000 {
            return countFallback(old: old, new: new, path: path, tooLarge: true)
        }
        let flat = buildDiffLines(oldLines: oldLines, newLines: newLines)
        let hunks = buildHunks(from: flat, context: 3)
        let added   = flat.filter { $0.kind == .added   }.count
        let removed = flat.filter { $0.kind == .removed }.count
        return FileDiff(path: path, added: added, removed: removed, hunks: hunks, tooLarge: false, isNewFile: false)
    }

    static func fromNew(content: String, path: String) -> FileDiff {
        // Size guard (same limits as fromEdit)
        if content.utf8.count > FileDiff.maxBytes {
            let lineCount = content.components(separatedBy: "\n").count
            return FileDiff(path: path, added: lineCount, removed: 0, hunks: [], tooLarge: true, isNewFile: true)
        }
        let lines = splitLines(content)
        if lines.count > FileDiff.maxLines {
            return FileDiff(path: path, added: lines.count, removed: 0, hunks: [], tooLarge: true, isNewFile: true)
        }
        let diffLines = lines.enumerated().map { (i, text) in
            DiffLine(kind: .added, text: text, origLine: -1, newLine: i + 1)
        }
        let hunk = diffLines.isEmpty ? nil : DiffHunk(origStart: 0, newStart: 1, lines: diffLines)
        return FileDiff(
            path: path,
            added: diffLines.count,
            removed: 0,
            hunks: hunk.map { [$0] } ?? [],
            tooLarge: false,
            isNewFile: true
        )
    }

    // MARK: - Line splitting

    private static func splitLines(_ text: String) -> [String] {
        // Normalize CRLF → LF
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var parts = normalized.components(separatedBy: "\n")
        // Drop trailing empty element that results from a trailing newline
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    // MARK: - LCS-based diff

    private static func buildDiffLines(oldLines: [String], newLines: [String]) -> [DiffLine] {
        let m = oldLines.count
        let n = newLines.count

        // Build LCS DP table
        // dp[i][j] = LCS length of oldLines[0..<i] and newLines[0..<j]
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...max(1, m) {
            for j in 1...max(1, n) {
                guard i <= m && j <= n else { continue }
                if oldLines[i - 1] == newLines[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to get matching pairs
        var matches: [(Int, Int)] = []  // (oldIdx 0-based, newIdx 0-based)
        var i = m, j = n
        while i > 0 && j > 0 {
            if oldLines[i - 1] == newLines[j - 1] {
                matches.append((i - 1, j - 1))
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        matches.reverse()

        // Build flat diff from LCS pairs
        var result: [DiffLine] = []
        var prevOld = -1
        var prevNew = -1

        for (oi, ni) in matches {
            // Removed lines between last match and this old match
            for k in (prevOld + 1)..<oi {
                result.append(DiffLine(kind: .removed, text: oldLines[k],
                                       origLine: k + 1, newLine: -1))
            }
            // Added lines between last match and this new match
            for k in (prevNew + 1)..<ni {
                result.append(DiffLine(kind: .added, text: newLines[k],
                                       origLine: -1, newLine: k + 1))
            }
            // Context line (the match)
            result.append(DiffLine(kind: .context, text: oldLines[oi],
                                   origLine: oi + 1, newLine: ni + 1))
            prevOld = oi
            prevNew = ni
        }

        // Remaining removes
        for k in (prevOld + 1)..<m {
            result.append(DiffLine(kind: .removed, text: oldLines[k],
                                   origLine: k + 1, newLine: -1))
        }
        // Remaining adds
        for k in (prevNew + 1)..<n {
            result.append(DiffLine(kind: .added, text: newLines[k],
                                   origLine: -1, newLine: k + 1))
        }

        return result
    }

    // MARK: - Hunk building

    private static func buildHunks(from lines: [DiffLine], context: Int) -> [DiffHunk] {
        guard !lines.isEmpty else { return [] }

        // Find indices of changed lines
        var changedIndices: [Int] = []
        for (i, line) in lines.enumerated() {
            if line.kind != .context { changedIndices.append(i) }
        }
        guard !changedIndices.isEmpty else { return [] }

        // Expand ±context around each changed line
        let ranges: [(Int, Int)] = changedIndices.map {
            (max(0, $0 - context), min(lines.count - 1, $0 + context))
        }

        // Merge overlapping ranges
        var merged: [(Int, Int)] = []
        for r in ranges {
            if let last = merged.last, r.0 <= last.1 + 1 {
                merged[merged.count - 1] = (last.0, max(last.1, r.1))
            } else {
                merged.append(r)
            }
        }

        // Build hunks
        var hunks: [DiffHunk] = []
        for (start, end) in merged {
            let hunkLines = Array(lines[start...end])
            let origStart = hunkLines.first(where: { $0.origLine > 0 })?.origLine ?? 1
            let newStart  = hunkLines.first(where: { $0.newLine > 0 })?.newLine  ?? 1
            hunks.append(DiffHunk(origStart: origStart, newStart: newStart, lines: hunkLines))
        }
        return hunks
    }

    // MARK: - Count fallback (tooLarge)

    private static func countFallback(old: String, new: String, path: String, tooLarge: Bool) -> FileDiff {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let oldSet = Set(oldLines)
        let newSet = Set(newLines)
        let added   = newLines.filter { !$0.isEmpty && !oldSet.contains($0) }.count
        let removed = oldLines.filter { !$0.isEmpty && !newSet.contains($0) }.count
        return FileDiff(path: path, added: added, removed: removed, hunks: [], tooLarge: tooLarge, isNewFile: false)
    }

    // MARK: - toOneLine

    /// Converts a possibly multi-line, markdown-formatted string to a single line of plain text.
    /// Uses only the first non-empty paragraph (stops at blank line, horizontal rule, or table row).
    /// Strips `**`, `__`, backticks, leading `#`, and leading bullet markers.
    static func toOneLine(_ text: String, maxChars: Int = 200) -> String {
        let lines = text.components(separatedBy: "\n")

        // Split into paragraphs. Separators: blank line, HR (3+ repeated -/*/_ chars), table row (starts with |).
        var paragraphs: [[String]] = []
        var current: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHR = trimmed.count >= 3 && (trimmed.allSatisfy { $0 == "-" } ||
                                               trimmed.allSatisfy { $0 == "*" } ||
                                               trimmed.allSatisfy { $0 == "_" })
            let isSep = trimmed.isEmpty || isHR || trimmed.hasPrefix("|")
            if isSep {
                if !current.isEmpty { paragraphs.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }

        // Find first paragraph that yields non-empty text after cleaning.
        for paraLines in paragraphs {
            var s = paraLines.joined(separator: "\n")
            s = s.replacingOccurrences(of: "**", with: "")
            s = s.replacingOccurrences(of: "__", with: "")
            s = s.replacingOccurrences(of: "`", with: "")
            let processed: [String] = s.components(separatedBy: "\n").compactMap { line in
                let cleaned = cleanMarkdownLine(line)
                return cleaned.isEmpty ? nil : cleaned
            }
            let joined = processed.joined(separator: " ")
            let collapsed = joined.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !collapsed.isEmpty { return String(collapsed.prefix(maxChars)) }
        }
        return ""
    }

    // MARK: - toTickerText

    /// The opening of an assistant message, kept across its blank lines, for the
    /// overview's left card.
    ///
    /// `toOneLine` stops at the first blank line, so on a structured answer —
    /// an opening sentence, then a heading, then a table — it returns only that
    /// sentence and the card showed one line where it had room for four. This
    /// keeps the lines instead and drops the blanks, so the row fills with the
    /// start of the answer rather than its first sentence.
    ///
    /// `maxChars` is a hard budget across the whole string, not per line: the
    /// card's width is fixed, so characters are what actually decide how tall
    /// the row comes out.
    static func toTickerText(_ text: String, maxLines: Int = 4, maxChars: Int = 160) -> String {
        var out: [String] = []
        var used = 0
        for raw in text.components(separatedBy: "\n") {
            let line = cleanMarkdownLine(raw)
            if line.isEmpty { continue }
            // Skip table rows and horizontal rules. Both render as pipe/dash
            // noise at 13pt, and `toOneLine` drops them for the same reason —
            // the rows underneath carry the actual content.
            guard !line.hasPrefix("|"), !isHorizontalRule(line) else { continue }
            let cost = line.count + 1   // + the newline joining it to the previous
            if used + cost > maxChars {
                let room = maxChars - used - 1
                if room > 4 { out.append(String(line.prefix(room)) + "…") }
                break
            }
            out.append(line)
            used += cost
            if out.count >= maxLines { break }
        }
        return out.joined(separator: "\n")
    }

    /// A markdown horizontal rule: 3+ of `-`, `*` or `_` and nothing else.
    /// Checked before bullet stripping, which would otherwise turn `---` into
    /// a stray `-`.
    private static func isHorizontalRule(_ line: String) -> Bool {
        line.count >= 3 && (line.allSatisfy { $0 == "-" } ||
                            line.allSatisfy { $0 == "*" } ||
                            line.allSatisfy { $0 == "_" })
    }

    /// Strip the markdown that reads as noise in a 13pt ticker row: heading
    /// hashes, `**`/`__`/backtick emphasis, and leading bullet markers.
    private static func cleanMarkdownLine(_ line: String) -> String {
        var l = line.trimmingCharacters(in: .whitespaces)
        while l.hasPrefix("#") { l = String(l.dropFirst()) }
        l = l.replacingOccurrences(of: "**", with: "")
        l = l.replacingOccurrences(of: "__", with: "")
        l = l.replacingOccurrences(of: "`", with: "")
        l = l.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("• ") {
            l = String(l.dropFirst(2))
        } else if let m = l.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            l = String(l[m.upperBound...])
        }
        return l.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - String diff step encoding

public extension String {
    /// Private-use character used as the diff step marker prefix.
    static let diffStepMarker = "\u{E001}"

    /// True if this step string encodes a file diff.
    var isDiffStep: Bool { hasPrefix(Self.diffStepMarker) }

    /// Parses a diff step string.
    /// Format: `"\u{E001}<filename>\t<added>:<removed>:<diffId>"`
    func parseDiffStep() -> (filename: String, added: Int, removed: Int, diffId: Int)? {
        guard isDiffStep else { return nil }
        let body = String(dropFirst())   // drop the marker character
        guard let tabIdx = body.firstIndex(of: "\t") else { return nil }
        let filename = String(body[body.startIndex..<tabIdx])
        let rest = String(body[body.index(after: tabIdx)...])
        let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let added  = Int(parts[0]),
              let removed = Int(parts[1]),
              let diffId  = Int(parts[2]) else { return nil }
        return (filename, added, removed, diffId)
    }

    /// Creates a diff step string from its components.
    static func makeDiffStep(filename: String, added: Int, removed: Int, diffId: Int) -> String {
        "\(diffStepMarker)\(filename)\t\(added):\(removed):\(diffId)"
    }
}
