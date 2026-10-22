import Foundation

/// The session title is what the home view, the chat and the notification
/// card show in place of the identifier Claude Code derives. It comes out of
/// the session's transcript, so the reading of it is what these tests cover:
/// which record wins, what happens when the file grows, and what a half
/// written line does.
@main
enum SessionTitleTests {
    static func check(_ label: String, _ got: Bool, failures: inout Int) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func write(_ text: String, to url: URL) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func main() {
        print("Session title")

        var failures = 0
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coucou-title-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A transcript with a generated title and a manual one on top of it.
        let url = dir.appendingPathComponent("s1.jsonl")
        write("""
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"ai-title","aiTitle":"修复登录","sessionId":"s1"}
        {"type":"custom-title","customTitle":"我的名字","sessionId":"s1"}

        """, to: url)

        var title = SessionHistoryLoader.scanTitle(in: url, from: SessionHistoryLoader.SessionTitle())
        check("reads the generated title", title.ai == "修复登录", failures: &failures)
        check("reads the manual title", title.custom == "我的名字", failures: &failures)
        check("the manual title is kept apart from the generated one",
              title.custom != title.ai, failures: &failures)
        check("reads the first thing the user asked",
              title.firstPrompt == "hi", failures: &failures)

        // A rename appends a second manual title; the newest one is the name.
        write("{\"type\":\"custom-title\",\"customTitle\":\"改过的名字\",\"sessionId\":\"s1\"}\n", to: url)
        title = SessionHistoryLoader.scanTitle(in: url, from: title)
        check("the newest manual title wins", title.custom == "改过的名字", failures: &failures)
        check("the generated title is left alone", title.ai == "修复登录", failures: &failures)

        // A line that is not a title record is not a title, whatever it says.
        let chatty = dir.appendingPathComponent("s2.jsonl")
        write("""
        {"type":"assistant","message":{"content":"the type custom-title is not a record"}}
        {"type":"user","message":{"role":"user","content":"\\"ai-title\\""}}

        """, to: chatty)
        let chattyTitle = SessionHistoryLoader.scanTitle(in: chatty, from: SessionHistoryLoader.SessionTitle())
        check("a mention of a title is not a title",
              chattyTitle.ai == nil && chattyTitle.custom == nil, failures: &failures)

        // A line still being written waits for the rest of it.
        let partial = dir.appendingPathComponent("s3.jsonl")
        write("{\"type\":\"ai-title\",\"aiTitle\":\"半条", to: partial)
        var partialTitle = SessionHistoryLoader.scanTitle(in: partial, from: SessionHistoryLoader.SessionTitle())
        check("a half written line is not read yet", partialTitle.ai == nil, failures: &failures)
        write("标题\",\"sessionId\":\"s3\"}\n", to: partial)
        partialTitle = SessionHistoryLoader.scanTitle(in: partial, from: partialTitle)
        check("the line is read once it is finished", partialTitle.ai == "半条标题", failures: &failures)

        // A cleared name: the last record wins, and an empty one clears the
        // name rather than being ignored.
        let cleared = dir.appendingPathComponent("s6.jsonl")
        write("""
        {"type":"ai-title","aiTitle":"自动标题","sessionId":"s6"}
        {"type":"custom-title","customTitle":"手动标题","sessionId":"s6"}
        {"type":"custom-title","customTitle":"","sessionId":"s6"}

        """, to: cleared)
        let clearedTitle = SessionHistoryLoader.scanTitle(in: cleared, from: SessionHistoryLoader.SessionTitle())
        check("a cleared name is read as cleared", clearedTitle.custom == "", failures: &failures)
        check("the generated name is still there", clearedTitle.ai == "自动标题", failures: &failures)

        // A session that has only been talked to has no title of its own: the
        // first thing the user asked is what Claude Code calls it.
        let talking = dir.appendingPathComponent("s7.jsonl")
        write("""
        {"type":"user","message":{"role":"user","content":"今天日期"}}
        {"type":"user","message":{"role":"user","content":"第二句"}}

        """, to: talking)
        let talkingTitle = SessionHistoryLoader.scanTitle(in: talking, from: SessionHistoryLoader.SessionTitle())
        check("the first prompt is the one that names the session",
              talkingTitle.firstPrompt == "今天日期", failures: &failures)

        // A system message is not the user speaking.
        let injected = dir.appendingPathComponent("s8.jsonl")
        write("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"<task-notification>hi</task-notification>\"}}\n", to: injected)
        let injectedTitle = SessionHistoryLoader.scanTitle(in: injected, from: SessionHistoryLoader.SessionTitle())
        check("a system message is not a prompt", injectedTitle.firstPrompt == nil, failures: &failures)

        // A session with no title at all is named by Claude Code instead.
        func session(aiTitle: String = "", customTitle: String = "", firstPrompt: String = "", sessionName: String) -> ClaudeSession {
            var s = ClaudeSession(
                id: "s1", sessionId: "s1", cwd: "/Users/me/mycoucou",
                hostApp: nil, sessionBundleId: nil, projectName: "mycoucou",
                state: .idle, startedAt: Date(timeIntervalSince1970: 0),
                lastEventAt: Date(timeIntervalSince1970: 0)
            )
            s.aiTitle = aiTitle
            s.customTitle = customTitle
            s.firstPrompt = firstPrompt
            s.sessionName = sessionName
            return s
        }

        let titled = session(aiTitle: "修复登录", sessionName: "mycoucou-3c")
        check("the title is the name shown", titled.displayName == "修复登录", failures: &failures)

        let renamed = session(aiTitle: "修复登录", customTitle: "我的名字", sessionName: "mycoucou-3c")
        check("a name the user gave wins over the generated one",
              renamed.displayName == "我的名字", failures: &failures)

        let clearedName = session(aiTitle: "自动标题", customTitle: "", sessionName: "mycoucou-3c")
        check("a cleared name falls back to the generated one",
              clearedName.displayName == "自动标题", failures: &failures)

        let untitled = session(sessionName: "mycoucou-3c")
        check("without a title the identifier is the name",
              untitled.displayName == "mycoucou-3c", failures: &failures)

        let named = session(aiTitle: "修复登录", customTitle: "我起的名", sessionName: "mycoucou-3c")
        check("a name the user gave the session wins", named.displayName == "我起的名", failures: &failures)

        // A session Claude Code hasn't named yet is called what it was asked.
        let asked = session(firstPrompt: "今天日期", sessionName: "mycoucou-3c")
        check("a session with no title is called what it was asked",
              asked.displayName == "今天日期", failures: &failures)

        // A name the user gave beats what it was asked.
        let renamedAsked = session(customTitle: "改名字", firstPrompt: "今天日期",
                                   sessionName: "mycoucou-3c")
        check("a name the user gave beats the first prompt",
              renamedAsked.displayName == "改名字", failures: &failures)

        // Writing a name into a session, the way Claude Code's `/rename`
        // does: a record in the transcript, and a sidecar beside it.
        let transcript = dir.appendingPathComponent("s4.jsonl")
        write("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n", to: transcript)

        try? SessionTitleWriter.rename(sessionId: "s4", to: "改个名", transcript: transcript)
        let lines = (try? String(contentsOf: transcript, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        check("the name is appended to the transcript", lines.count == 2, failures: &failures)
        let record = lines.last.flatMap { line -> [String: Any]? in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        check("the record says what it is",
              record?["type"] as? String == "custom-title" &&
              record?["customTitle"] as? String == "改个名" &&
              record?["sessionId"] as? String == "s4",
              failures: &failures)
        check("what was already in the transcript is left alone",
              lines.first?.contains("\"content\":\"hi\"") == true, failures: &failures)

        let sidecar = dir.appendingPathComponent("s4/custom-title.json")
        check("the sidecar is written beside the transcript",
              (try? String(contentsOf: sidecar, encoding: .utf8)) == "{\"customTitle\":\"改个名\"}",
              failures: &failures)

        // Clearing the name: the record still goes in, and the sidecar goes
        // away — the same as Claude Code.
        try? SessionTitleWriter.rename(sessionId: "s4", to: "", transcript: transcript)
        check("the sidecar is removed",
              !FileManager.default.fileExists(atPath: sidecar.path), failures: &failures)
        let afterClear = (try? String(contentsOf: transcript, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        let clearRecord = afterClear.last.flatMap { line -> [String: Any]? in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        check("the cleared name is recorded as empty",
              clearRecord?["type"] as? String == "custom-title" &&
              clearRecord?["customTitle"] as? String == "", failures: &failures)

        // A transcript that ends mid-line — Claude Code writes a partial
        // record while a turn is running — must not swallow the name.
        let torn = dir.appendingPathComponent("s5.jsonl")
        write("{\"type\":\"user\"", to: torn)
        try? SessionTitleWriter.rename(sessionId: "s5", to: "名字", transcript: torn)
        let tornLines = (try? String(contentsOf: torn, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        check("the name lands on its own line", tornLines.count == 2, failures: &failures)
        check("the half-written line is left as it was",
              tornLines.first == "{\"type\":\"user\"", failures: &failures)

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll tests passed.")
    }
}
