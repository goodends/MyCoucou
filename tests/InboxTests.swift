import Foundation

@main
enum InboxTests {
    static func check(_ label: String, _ got: Bool, failures: inout Int) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func question(_ sid: String, in seconds: TimeInterval = 60) -> PendingQuestion {
        PendingQuestion(
            id: sid,
            question: AskQuestion(questions: [AskQuestionItem(
                question: "q?", header: "", options: [
                    AskQuestionOption(label: "a", description: ""),
                    AskQuestionOption(label: "b", description: "")], multiSelect: false)]),
            pillId: "integration_claude", sessionId: sid,
            arrivedAt: .now, deadline: .now.addingTimeInterval(seconds))
    }

    static func approval(_ aid: String, pill: String = "integration_claude") -> PendingApproval {
        PendingApproval(
            id: aid,
            info: ApprovalInfo(sessionId: "sid-\(aid)", tool: "Bash",
                               command: "rm -rf /", inputKey: "", pillId: pill),
            arrivedAt: .now, deadline: .now.addingTimeInterval(60))
    }

    static func finished(_ id: String) -> AgentNotification {
        AgentNotification(agentId: "integration_claude", sessionId: "sid-\(id)",
                          kind: .finished, finalLine: id)
    }

    static func main() {
        print("Inbox ordering and row identity")

        var failures = 0

        // Questions and permissions hold a hook open and run on a clock, so they
        // sort ahead of finished sessions, which have no deadline.
        let mixed = InboxItem.ordered(
            approvals: [approval("a1")],
            questions: [question("q1"), question("q2")],
            notifications: [finished("n1"), finished("n2")])
        // A finished row is keyed by its session id, so "sid-n1" reads "n:sid-n1".
        check("approvals, then questions, then finished sessions",
              mixed.map(\.id) == ["a:a1", "q:q1", "q:q2", "n:sid-n1", "n:sid-n2"],
              failures: &failures)

        // Order within a kind is preserved: the head is the oldest, i.e. the
        // one nearest its deadline.
        check("keeps queue order within a kind",
              InboxItem.ordered(approvals: [], questions: [question("q2"), question("q1")], notifications: [])
                .map(\.id) == ["q:q2", "q:q1"], failures: &failures)

        check("empty inbox is empty",
              InboxItem.ordered(approvals: [], questions: [], notifications: []).isEmpty,
              failures: &failures)

        // Ids are namespaced by kind — an approval and a question minted in the
        // same second must not collide in the ForEach.
        check("ids are namespaced by kind",
              InboxItem.ordered(approvals: [approval("x")], questions: [question("x")], notifications: [])
                .map(\.id) == ["a:x", "q:x"], failures: &failures)

        check("row routes to its own pill and session",
              InboxItem.ordered(approvals: [approval("a1", pill: "agent_codex")],
                                questions: [question("q1")], notifications: [])
                .map(\.pillId) == ["agent_codex", "integration_claude"],
              failures: &failures)
        check("approval row keeps its session",
              InboxItem.ordered(approvals: [approval("a1")], questions: [], notifications: [])
                .first?.sessionId == "sid-a1", failures: &failures)

        // A row whose deadline has passed reads 0, never negative — the countdown
        // would otherwise show "-3s" for the second before the hook gives up.
        check("seconds left never goes negative",
              question("q", in: -5).secondsLeft == 0 &&
              approval("a1").secondsLeft > 0 && approval("a1").secondsLeft <= 60,
              failures: &failures)

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll tests passed.")
    }
}
