import Foundation

@main
enum NotificationQueueTests {
    static func check(_ label: String, _ got: Bool, failures: inout Int) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func note(_ agentId: String, _ sid: String?, _ line: String) -> AgentNotification {
        AgentNotification(agentId: agentId, sessionId: sid, kind: .finished, finalLine: line)
    }

    static func main() {
        print("Finished notification queue")

        var failures = 0
        var q: [AgentNotification] = []

        // Two sessions finishing back to back must both be kept — the bug this
        // queue replaces stored them in one slot each, so the second clobbered
        // the first.
        q = q.pushing(note("integration_claude", "sid-a", "first"))
        q = q.pushing(note("integration_claude", "sid-b", "second"))
        check("keeps both, newest first",
              q.count == 2 &&
              q.first?.sessionId == "sid-b" &&
              q.last?.sessionId == "sid-a" &&
              q.last?.finalLine == "first", failures: &failures)

        // A session finishing again refreshes its own row rather than stacking
        // a duplicate the user has to dismiss twice — and being the newest
        // finish, it moves back to the top.
        q = q.pushing(note("integration_claude", "sid-a", "first, again"))
        check("re-finishing a waiting session replaces its row at the top",
              q.count == 2 &&
              q.first?.finalLine == "first, again" &&
              q.first?.sessionId == "sid-a" &&
              q.last?.sessionId == "sid-b", failures: &failures)

        // Acknowledging one leaves the others alone.
        q = q.removing(id: "sid-b")
        check("removing one keeps the rest",
              q.count == 1 && q.first?.id == "sid-a", failures: &failures)

        // A session that resumes takes only its own row down.
        q = q.pushing(note("agent_codex", nil, "codex done"))
        q = q.pushing(note("integration_claude", "sid-c", "third"))
        check("looking a notification up by session id",
              q.first(sessionId: "sid-c")?.finalLine == "third" &&
              q.first(sessionId: "sid-a")?.finalLine == "first, again" &&
              q.first(sessionId: "sid-z") == nil, failures: &failures)
        check("a session without an id is not found by session lookup",
              q.first(sessionId: "agent_codex") == nil, failures: &failures)

        // Agents without a session id key their row by the pill.
        check("pill without a session id keys by pill",
              q.first?.id == "sid-c", failures: &failures)
        let noSid = note("agent_codex", nil, "codex done")
        check("no session id → id is the pill id", noSid.id == "agent_codex", failures: &failures)
        check("empty session id is treated as absent",
              note("agent_codex", "", "x").id == "agent_codex" && note("agent_codex", "", "x").sessionId == nil, failures: &failures)

        // A card that was shown and taken back stays in the tab: the countdown
        // gives the screen back, it doesn't take the notification away. It
        // keeps its own row, its line and its session.
        let kept = q.pushing(note("integration_claude", "sid-r", "shown and taken back"))
        check("a card that was taken back stays in the tab",
              kept.contains { $0.id == "sid-r" && $0.finalLine == "shown and taken back" },
              failures: &failures)

        // Height: the stack reserves exactly what its cards measure plus one
        // fixed margin, so the gap under the last card is the same for one
        // card as for five — then it stops at the chat's height and scrolls.
        let h = NotificationLayout.height(forCount:)
        let perCard = NotificationLayout.cardHeight + NotificationLayout.cardSpacing
        check("reserves chrome + cards + one margin",
              h(1) == NotificationLayout.chrome + NotificationLayout.cardHeight
                     + NotificationLayout.listPadding + NotificationLayout.bottomAir &&
              h(4) == NotificationLayout.chrome + 4 * NotificationLayout.cardHeight
                     + 3 * NotificationLayout.cardSpacing + NotificationLayout.listPadding
                     + NotificationLayout.bottomAir, failures: &failures)
        check("empty still reserves one card", h(0) == h(1), failures: &failures)
        check("each extra card adds one row",
              h(2) - h(1) == perCard && h(3) - h(2) == perCard, failures: &failures)
        check("caps at the chat height",
              NotificationLayout.maxHeight == IslandConst.chatHeight &&
              h(9) == NotificationLayout.maxHeight, failures: &failures)
        check("height never decreases as cards pile up",
              (1...12).allSatisfy { h($0) <= h($0 + 1) }, failures: &failures)
        // The stack must fit its own content until it hits the cap — otherwise
        // the last card gets clipped even though nothing forces a scroll.
        check("fits its cards before the cap",
              (1...5).allSatisfy { n in
                  let content = CGFloat(n) * NotificationLayout.cardHeight
                      + CGFloat(n - 1) * NotificationLayout.cardSpacing
                      + NotificationLayout.listPadding
                  return h(n) == NotificationLayout.maxHeight
                      || h(n) - NotificationLayout.chrome >= content
              }, failures: &failures)

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll tests passed.")
    }
}
