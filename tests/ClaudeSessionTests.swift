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

        // A session a hook event built carries no name — Claude Code's hook
        // payload never carries one — so it shows as its folder name until the
        // process scan tops the name up from the live-session registry.
        var named: [ClaudeSession] = []
        named.upsert(
            sessionId: "sid-named",
            cwd: "/Users/me/proj-named",
            hostApp: "dev.warp.Warp-Stable",
            sessionBundleId: nil,
            projectName: "proj-named",
            state: .working,
            eventTime: Date(timeIntervalSince1970: 3000)
        )
        check("a hook-built session starts nameless",
              named.first?.sessionName.isEmpty == true,
              failures: &failures)
        check("…and shows as its folder name until it gets one",
              named.first?.displayName == "proj-named",
              failures: &failures)

        named[0].adoptSessionName("proj-named-52")
        check("adopting the registry name makes it the display name",
              named.first?.displayName == "proj-named-52",
              failures: &failures)

        // The registry isn't always there — an older Claude Code writes no such
        // file — so an empty name has to leave the card alone.
        var nameless: [ClaudeSession] = []
        nameless.upsert(
            sessionId: "sid-nameless",
            cwd: "/Users/me/proj-nameless",
            hostApp: nil, sessionBundleId: nil,
            projectName: "proj-nameless",
            state: .working, eventTime: Date(timeIntervalSince1970: 3001)
        )
        nameless[0].adoptSessionName("")
        check("adopting an empty name is a no-op",
              nameless.first?.sessionName.isEmpty == true &&
              nameless.first?.displayName == "proj-nameless",
              failures: &failures)

        // A later scan must not rename a session that already has a name:
        // Claude renumbers its derived names on every restart.
        named[0].adoptSessionName("proj-named-99")
        check("adopting again does not overwrite a name we already have",
              named.first?.displayName == "proj-named-52",
              failures: &failures)

        // Hook events keep arriving for the life of a session; none of them
        // may drop the name the scan adopted.
        named.upsert(
            sessionId: "sid-named",
            cwd: "/Users/me/proj-named",
            hostApp: "dev.warp.Warp-Stable",
            sessionBundleId: nil,
            projectName: "proj-named",
            state: .finished, eventTime: Date(timeIntervalSince1970: 3002)
        )
        check("a later hook event keeps the adopted name",
              named.first?.displayName == "proj-named-52",
              failures: &failures)

        // A name typed in the wardrobe outranks Claude's own.
        var custom: [ClaudeSession] = []
        custom.upsert(
            sessionId: "sid-custom",
            cwd: "/Users/me/proj-custom",
            hostApp: nil, sessionBundleId: nil,
            projectName: "proj-custom",
            state: .working, eventTime: Date(timeIntervalSince1970: 3003)
        )
        custom[0].customName = "Review the diff"
        custom[0].adoptSessionName("proj-custom-7")
        check("a customName outranks the session name",
              custom.first?.displayName == "Review the diff",
              failures: &failures)

        // The path that already worked: a session the scan found first arrives
        // with its name attached.
        let scannedName = ClaudeSession.scanned(
            sessionId: "sid-scanned", pid: 4242,
            cwd: "/Users/me/proj-scanned", projectName: "proj-scanned",
            sessionName: "proj-scanned-3", state: .idle,
            startedAt: Date(timeIntervalSince1970: 3000), hostApp: nil
        )
        check("a session the scan found already shows its own name",
              scannedName.displayName == "proj-scanned-3",
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