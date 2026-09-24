import Foundation

/// The extra status line below the transcript, when its existing rows do not explain why
/// the agent is waiting. Waiting for a person is deliberately static, without a spinner.
enum ChatActivity: Hashable, Sendable {
    case thinking
    case waitingForApproval
    case waitingForAnswer

    var label: String {
        switch self {
        case .thinking: String(localized: "Thinking…")
        case .waitingForApproval: String(localized: "Waiting for your approval")
        case .waitingForAnswer: String(localized: "Waiting for your answer")
        }
    }

    var symbol: String? {
        switch self {
        case .thinking: nil
        case .waitingForApproval: "hand.raised"
        case .waitingForAnswer: "questionmark.bubble"
        }
    }
}

/// Uses the same answer state as the visible cards, including cards raised by a specialist.
/// A pending decision remains actionable even if the connection's generation flag is false.
func chatActivity(
    in rows: [ChatRow],
    generating: Bool,
    streamingId: String?,
    answeredApprovals: Set<String>,
    answeredQuestions: Set<String>
) -> ChatActivity? {
    var waitingForAnswer = false
    for row in rows {
        switch row {
        case .approval(let event):
            if case .approvalCard(let card) = event.payload,
                !answeredApprovals.contains(card.actionId)
            {
                return .waitingForApproval
            }
        case .question(let event):
            if case .questionCard(let card) = event.payload,
                !answeredQuestions.contains(card.questionId)
            {
                waitingForAnswer = true
            }
        default:
            break
        }
    }
    if waitingForAnswer { return .waitingForAnswer }

    guard generating, streamingId == nil else { return nil }
    if case .work(let work) = rows.last, work.running { return nil }
    return .thinking
}
