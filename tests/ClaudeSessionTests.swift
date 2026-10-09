import Foundation

@main
enum ClaudeSessionTests {
    static func check(_ label: String, _ got: Bool, failures: inout Int) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        print("ClaudeSession list upsert / remove")

        var failures = 0
        var sessions: [ClaudeSession] = []

        // Insert a new session.
        sessions.upsert(
            sessionId: "sid-a",
            cwd: "/Users/me/proj-a",
            hostApp: "dev.warp.Warp-Stable",
            sessionBundleId: "dev.warp.Warp-Stable",
            projectName: "proj-a",
            phase: .spawning,
            eventTime: Date(timeIntervalSince1970: 1000)
        )
        check("creates a new entry",
              sessions.count == 1 &&
              sessions.first?.sessionId == "sid-a" &&
              sessions.first?.projectName == "proj-a" &&
              sessions.first?.state == .spawning,
              failures: &failures)

        // Insert a second session.
        sessions.upsert(
            sessionId: "sid-b",
            cwd: "/Users/me/proj-b",
            hostApp: nil,
            sessionBundleId: "com.microsoft.VSCode",
            projectName: "proj-b",
            phase: .working,
            eventTime: Date(timeIntervalSince1970: 1001)
        )
        check("two sessions, most-recent first",
              sessions.count == 2 &&
              sessions.first?.sessionId == "sid-b",
              failures: &failures)

        // Update an existing session → promote to front, update cwd/phase.
        sessions.upsert(
            sessionId: "sid-a",
            cwd: "/Users/me/proj-a-renamed",
            hostApp: "dev.warp.Warp-Stable",
            sessionBundleId: "dev.warp.Warp-Stable",
            projectName: "proj-a-renamed",
            phase: .finished,
            eventTime: Date(timeIntervalSince1970: 1002)
        )
        check("updates in place and promotes to front",
              sessions.count == 2 &&
              sessions.first?.sessionId == "sid-a" &&
              sessions.first?.cwd == "/Users/me/proj-a-renamed" &&
              sessions.first?.state == .finished &&
              sessions.first?.projectName == "proj-a-renamed",
              failures: &failures)

        // Empty / unknown session id → no-op.
        sessions.upsert(
            sessionId: "",
            cwd: "/x", hostApp: nil, sessionBundleId: nil,
            projectName: "x", phase: .working, eventTime: .now
        )
        sessions.upsert(
            sessionId: "unknown",
            cwd: "/x", hostApp: nil, sessionBundleId: nil,
            projectName: "x", phase: .working, eventTime: .now
        )
        check("empty / \"unknown\" session id is a no-op",
              sessions.count == 2,
              failures: &failures)

        // Remove one session by id.
        sessions.removeById("sid-a")
        check("remove by id",
              sessions.count == 1 &&
              sessions.first?.sessionId == "sid-b",
              failures: &failures)

        // Remove missing id → no-op.
        sessions.removeById("sid-missing")
        check("remove missing id is a no-op",
              sessions.count == 1,
              failures: &failures)

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll tests passed.")
    }
}