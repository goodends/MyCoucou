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

    // MARK: - Session title

    /// What a session's transcript says it is called, and how much of the
    /// transcript we've read to find out.
    ///
    /// The transcript is append-only, so a later scan only has to look at the
    /// bytes written since the last one. Without that, every refresh would
    /// re-read a file that can run to tens of megabytes.
    struct SessionTitle: Equatable, Sendable {
        /// The newest `custom-title` — what `/rename` wrote.
        var custom: String? = nil
        /// The newest `ai-title` — Claude Code's own summary of the session.
        var ai: String? = nil
        /// The first thing the user asked in the session. Claude Code falls
        /// back to it when the session has no title of its own.
        var firstPrompt: String? = nil
        /// Bytes of the transcript already read.
        var offset: UInt64 = 0
    }

    /// The two kinds of title record a transcript carries.
    private enum TitleKind {
        case custom
        case ai
    }

    /// Read the bytes of a session transcript written since `title.offset` and
    /// pick up the title records in them.
    ///
    /// The newest record of each kind wins: Claude Code appends a new
    /// `custom-title` every time the session is renamed, so an earlier one
    /// says nothing about the current name.
    static func scanTitle(in url: URL, from title: SessionTitle) -> SessionTitle {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return title }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: title.offset)
        } catch {
            return title
        }

        var result = title
        // Bytes read but not yet terminated by a newline. A transcript's last
        // line can be half-written, so it waits for the next scan.
        var pending = Data()
        // Bytes that ended a line, and so are read for good.
        var consumed: UInt64 = 0

        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                consumed += UInt64(line.count + 1)
                // The first prompt is only wanted once: later ones say
                // nothing about what the session started as.
                if result.firstPrompt == nil, let prompt = prompt(in: line) {
                    result.firstPrompt = prompt
                }
                guard let record = titleRecord(in: line) else { continue }
                switch record.kind {
                case .custom: result.custom = record.value
                case .ai:     result.ai = record.value
                }
            }
        }
        // The tail that never got its newline is left behind: the next scan
        // seeks back to it and reads it again.
        result.offset = title.offset + consumed
        return result
    }

    /// The title record in one transcript line, if it is one.
    ///
    /// A title record is one line in a few thousand, and parsing all of them
    /// as JSON would cost more than the read itself, so the two type names
    /// are looked for in the raw bytes first.
    private static func titleRecord(in line: Data) -> (kind: TitleKind, value: String)? {
        let mentionsCustom = line.range(of: Data("\"custom-title\"".utf8)) != nil
        let mentionsAI = line.range(of: Data("\"ai-title\"".utf8)) != nil
        guard mentionsCustom || mentionsAI else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }
        switch type {
        case "custom-title":
            // An empty title is a cleared title, not a missing one: Claude
            // Code reads it as an empty string and falls back to the
            // generated name, so we have to as well.
            guard let value = obj["customTitle"] as? String else { return nil }
            return (.custom, value)
        case "ai-title":
            guard let value = obj["aiTitle"] as? String else { return nil }
            return (.ai, value)
        default:
            return nil
        }
    }

    /// The prompt in one transcript line, if it is the user speaking.
    ///
    /// The same rule the history reader uses: the content is plain text, not
    /// the array a tool result comes back as, and it is not one of the XML
    /// system messages Claude Code injects.
    private static func prompt(in line: Data) -> String? {
        guard line.range(of: Data("\"role\":\"user\"".utf8)) != nil
                || line.range(of: Data("\"role\": \"user\"".utf8)) != nil else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "user",
              obj["isMeta"] as? Bool != true,
              let message = obj["message"] as? [String: Any],
              let text = message["content"] as? String
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return trimmed
    }

    /// The transcript of a session, wherever it lives.
    ///
    /// A session's cwd doesn't always match the directory its transcript is
    /// in — Orca starts Claude Code with a different process cwd — so the
    /// projects are searched for the session id before the cwd is trusted.
    static func transcriptURL(sessionId: String, cwd: String) -> URL? {
        if let found = locateSessionAcrossProjects(sessionId) { return found }
        let guess = jsonlURL(cwd: cwd, sessionId: sessionId)
        return FileManager.default.fileExists(atPath: guess.path) ? guess : nil
    }

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

    /// Find the `.jsonl` for `sessionId` across ALL `~/.claude/projects/*/`.
    /// Used when the session's cwd doesn't match the JSONL's project directory
    /// (e.g. Orca launches Claude Code with a process cwd different from the
    /// session's logical project — the JSONL still lives in the project dir).
    static func locateSessionAcrossProjects(_ sessionId: String) -> URL? {
        let fm = FileManager.default
        let homes = [
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects"),
        ]
        for home in homes {
            guard let dirs = try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for dir in dirs {
                let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
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
        // Skip system-injected meta events (tool_result echoes, task notifications,
        // permission prompts, etc.) — they're not actual conversation turns.
        if ev["isMeta"] as? Bool == true { return }
        switch type {
        case "user":
            if let text = msg["content"] as? String, !text.isEmpty {
                // Belt-and-suspenders: skip anything that looks like an XML
                // system message (e.g. <task-notification>…</task-notification>).
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("<") { return }
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
