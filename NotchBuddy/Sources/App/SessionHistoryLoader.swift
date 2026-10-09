import Foundation

/// Loads Claude Code's session log from
/// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` to populate
/// `AgentTask.history` with the full conversation — including events that
/// happened before Coucou was launched (which the hook pipe never sees).
///
/// JSONL line shapes we care about:
/// - `{"type":"user","message":{"role":"user","content":"<prompt>"}}` — real user prompt
/// - `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"…"}]}}`
///   — assistant text response (blocks of type `thinking` / `tool_use` are skipped)
/// - `{"type":"user","message":{"content":[{"tool_use_result":…}]}}` — tool result echo, skipped
enum SessionHistoryLoader {

    /// Path: `~/.claude/projects/-Users-foo-bar/<sessionId>.jsonl`
    /// (the project dir name is the cwd with `/` replaced by `-` and prefixed with `-`).
    static func jsonlURL(cwd: String, sessionId: String) -> URL {
        let encoded = "-" + cwd.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded)")
            .appendingPathComponent("\(sessionId).jsonl")
    }

    /// Most recently modified `.jsonl` in the project dir for `cwd`.
    /// Fallback when `task.sessionId` is nil (Coucou started after Claude Code).
    static func mostRecentSessionURL(cwd: String) -> URL? {
        let encoded = "-" + cwd.replacingOccurrences(of: "/", with: "-")
        return mostRecentSession(in: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded)"))
    }

    /// Most recently modified `.jsonl` across ALL `~/.claude/projects/*/`.
    /// Used when the task has no `sessionCwd` either (Coucou has never seen a
    /// SessionStart event for the pill).
    static func mostRecentSessionAcrossProjects() -> URL? {
        // Try homeDirectoryForCurrentUser first, then fall back to NSHomeDirectory
        // (the app's container can differ from $HOME in some Xcode runs).
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        if let url = mostRecentJSONL(in: home) { return url }
        let alt = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
        return mostRecentJSONL(in: alt)
    }

    private static func mostRecentJSONL(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        var best: (URL, Date)?
        for projectDir in projectDirs {
            guard let url = mostRecentSession(in: projectDir) else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if best == nil || mtime > best!.1 { best = (url, mtime) }
        }
        return best?.0
    }

    private static func mostRecentSession(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let jsonls = contents.filter { $0.pathExtension == "jsonl" }
        return jsonls.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    /// Parse a JSONL file into ordered `[HistoryEntry]`. Returns `[]` on any error.
    /// - `user` event: include only when `content` is a plain string (real prompt).
    /// - `assistant` event: concatenate `text` blocks (skip `thinking` / `tool_use`).
    static func loadHistory(from url: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var entries: [HistoryEntry] = []
        // Split on raw newlines; tolerate CRLF.
        var start = data.startIndex
        for i in data.indices {
            let byte = data[i]
            if byte == 0x0A { // \n
                if start < i {
                    parseLine(data[start..<i], into: &entries)
                }
                start = data.index(after: i)
            }
        }
        if start < data.endIndex {
            parseLine(data[start..<data.endIndex], into: &entries)
        }
        return entries
    }

    private static func parseLine(_ lineData: Data, into entries: inout [HistoryEntry]) {
        guard lineData.first != nil,
              let ev = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = ev["type"] as? String,
              let msg = ev["message"] as? [String: Any]
        else { return }
        switch type {
        case "user":
            if let text = msg["content"] as? String, !text.isEmpty {
                entries.append(HistoryEntry(role: .user, content: text))
            }
        case "assistant":
            if let blocks = msg["content"] as? [[String: Any]] {
                let texts = blocks.compactMap { $0["text"] as? String }
                let combined = texts.joined(separator: "\n\n")
                if !combined.isEmpty {
                    entries.append(HistoryEntry(role: .assistant, content: combined))
                }
            }
        default:
            break
        }
    }
}
