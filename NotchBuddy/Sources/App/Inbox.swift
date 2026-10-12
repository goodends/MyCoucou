import Foundation

// The island's inbox: everything waiting on the user, in one list.
//
// Questions and permissions used to be single slots — a second request wrote
// "ask" to the first one's fd and took the card, so the displaced session fell
// back to its terminal with nothing on screen saying so. They are queues now,
// and each entry carries its own deadline: a hook held open past it hands the
// request back, exactly like an unanswered one always did.

// MARK: - Waiting requests

/// A question waiting to be answered. The hook fd stays open the whole time,
/// so a queued question that waits too long is handed back to its terminal.
struct PendingQuestion: Identifiable, Equatable {
    /// Unique per arrival — one session can ask again while an earlier
    /// question of its own is still waiting.
    let id: String
    var question: AskQuestion
    var pillId: String
    var sessionId: String
    var arrivedAt: Date
    var deadline: Date

    var secondsLeft: Int {
        max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
    }
}

/// A permission request waiting to be allowed or denied. Same contract as
/// `PendingQuestion`: queued, held open, and on its own clock.
struct PendingApproval: Identifiable {
    let id: String
    var info: ApprovalInfo
    var arrivedAt: Date
    var deadline: Date

    var secondsLeft: Int {
        max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
    }
}

// MARK: - Inbox row

/// One row of the notification stack.
enum InboxItem: Identifiable {
    case approval(PendingApproval)
    case question(PendingQuestion)
    case finished(AgentNotification)

    var id: String {
        switch self {
        case .approval(let a): return "a:" + a.id
        case .question(let q): return "q:" + q.id
        case .finished(let n): return "n:" + n.id
        }
    }

    var pillId: String {
        switch self {
        case .approval(let a): return a.info.pillId
        case .question(let q): return q.pillId
        case .finished(let n): return n.agentId
        }
    }

    var sessionId: String? {
        switch self {
        case .approval(let a): return a.info.sessionId
        case .question(let q): return q.sessionId
        case .finished(let n): return n.sessionId
        }
    }

    /// Questions and permissions hold a hook open, so they sort ahead of the
    /// finished sessions — which have no clock and can wait their turn. Oldest
    /// first within each kind: those are the ones nearest their deadline.
    static func ordered(
        approvals: [PendingApproval], questions: [PendingQuestion], notifications: [AgentNotification]
    ) -> [InboxItem] {
        approvals.map(InboxItem.approval)
            + questions.map(InboxItem.question)
            + notifications.map(InboxItem.finished)
    }
}
