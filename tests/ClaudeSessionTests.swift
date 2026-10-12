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
            state: .thinking,
            eventTime: Date(timeIntervalSince1970: 1000)
        )
        check("creates a new entry",
              sessions.count == 1 &&
              sessions.first?.sessionId == "sid-a" &&
              sessions.first?.projectName == "proj-a" &&
              sessions.first?.state == .thinking,
              failures: &failures)

        // Insert a second session.
        sessions.upsert(
            sessionId: "sid-b",
            cwd: "/Users/me/proj-b",
            hostApp: nil,
            sessionBundleId: "com.microsoft.VSCode",
            projectName: "proj-b",
            state: .working,
            eventTime: Date(timeIntervalSince1970: 1001)
        )
        check("two sessions, most-recent first",
              sessions.count == 2 &&
              sessions.first?.sessionId == "sid-b",
              failures: &failures)

        // Update an existing session → promote to front, update cwd/state.
        sessions.upsert(
            sessionId: "sid-a",
            cwd: "/Users/me/proj-a-renamed",
            hostApp: "dev.warp.Warp-Stable",
            sessionBundleId: "dev.warp.Warp-Stable",
            projectName: "proj-a-renamed",
            state: .finished,
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
            projectName: "x", state: .working, eventTime: .now
        )
        sessions.upsert(
            sessionId: "unknown",
            cwd: "/x", hostApp: nil, sessionBundleId: nil,
            projectName: "x", state: .working, eventTime: .now
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

        // First upsert for a brand-new session assigns a curated bodyColor
        // and a real outfit (not .auto, not .none).
        // Read the palette rather than listing it: the hand-written copy fell
        // behind when White was added, which failed ~1 run in 7 at random.
        let avatarColors = Set(ClaudeSession.palette.map(\.hex))
        sessions.upsert(
            sessionId: "sid-c",
            cwd: "/Users/me/proj-c",
            hostApp: nil,
            sessionBundleId: "com.microsoft.VSCode",
            projectName: "proj-c",
            state: .working,
            eventTime: Date(timeIntervalSince1970: 2000)
        )
        let newSession = sessions.first { $0.sessionId == "sid-c" }
        check("new session gets a curated bodyColor",
              newSession.map { avatarColors.contains($0.bodyColor) } ?? false,
              failures: &failures)
        check("new session gets a real outfit",
              newSession.map { $0.outfit != .auto && $0.outfit != .none } ?? false,
              failures: &failures)

        // Re-upserting the same session id keeps its original bodyColor and outfit.
        let originalColor  = newSession?.bodyColor
        let originalOutfit = newSession?.outfit
        sessions.upsert(
            sessionId: "sid-c",
            cwd: "/Users/me/proj-c",
            hostApp: nil,
            sessionBundleId: "com.microsoft.VSCode",
            projectName: "proj-c-renamed",
            state: .finished,
            eventTime: Date(timeIntervalSince1970: 2001)
        )
        let afterReUpsert = sessions.first { $0.sessionId == "sid-c" }
        check("re-upsert keeps original bodyColor",
              afterReUpsert?.bodyColor == originalColor,
              failures: &failures)
        check("re-upsert keeps original outfit",
              afterReUpsert?.outfit == originalOutfit,
              failures: &failures)

        // Remove + fresh upsert of the same id gives another valid random combo.
        sessions.removeById("sid-c")
        sessions.upsert(
            sessionId: "sid-c",
            cwd: "/Users/me/proj-c",
            hostApp: nil,
            sessionBundleId: "com.microsoft.VSCode",
            projectName: "proj-c",
            state: .working,
            eventTime: Date(timeIntervalSince1970: 2002)
        )
        let afterRemoveAndReAdd = sessions.first { $0.sessionId == "sid-c" }
        check("remove + fresh upsert produces another valid bodyColor",
              afterRemoveAndReAdd.map { avatarColors.contains($0.bodyColor) } ?? false,
              failures: &failures)
        check("remove + fresh upsert produces another valid outfit",
              afterRemoveAndReAdd.map { $0.outfit != .auto && $0.outfit != .none } ?? false,
              failures: &failures)

        // Every IslandView needs an entry in viewLayouts. IslandWindowController
        // and IslandRootView both reach it with a force-unwrap, so a case added
        // without one compiles fine and then crashes on first display — the one
        // place where adding a view is a runtime hazard rather than a build
        // error. This is the only automated guard against that.
        for v in IslandView.allCases {
            check("viewLayouts covers .\(v.rawValue)",
                  IslandConst.viewLayouts[v] != nil,
                  failures: &failures)
        }
        check("viewLayouts has no entry for a view that does not exist",
              IslandConst.viewLayouts[.overview] != nil,
              failures: &failures)

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll tests passed.")
    }
}