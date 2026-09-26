import Foundation
import Testing

@testable import YorozuShared

private func summary(
    approval: Bool? = nil, question: Bool? = nil, interrupted: String? = nil,
    failed: Bool? = nil, active: String? = nil, unread: Bool = false
) -> ThreadSummary {
    ThreadSummary(
        id: "t", title: "Deploy", archived: false, lastActivity: 1,
        lastReadAt: 10, lastAgentAt: unread ? 20 : 5,
        awaitingApproval: approval, awaitingQuestion: question, needsAttention: failed,
        interruptedTurnId: interrupted, activeEventId: active
    )
}

/// One slot, one mark, ranked: the card asking the user beats a failure, which beats the host
/// working, which beats an unread reply. Every lower state is present in each case so the
/// order is what is being proved, not the presence of a single flag.
@Test(arguments: [
    (summary(approval: true, interrupted: "turn", unread: true), true, ThreadStatus.needsAnswer),
    (summary(question: true, interrupted: "turn", unread: true), true, .needsAnswer),
    (summary(failed: true, unread: true), true, .needsAttention),
    (summary(interrupted: "turn", unread: true), true, .needsAttention),
    (summary(active: "event", unread: true), false, .working),
    (summary(unread: true), true, .working),
    (summary(unread: true), false, .unread),
    (summary(), false, nil),
])
func aRowWearsItsHighestRankedStatus(thread: ThreadSummary, working: Bool, expected: ThreadStatus?) {
    #expect(ThreadStatus(thread, working: working) == expected)
}

/// The runtime spells the pending-question flag `awaitingQuestion`, beside `awaitingApproval`.
@Test func actionableStatusFlagsArriveOnTheWire() throws {
    let json = Data(#"{"id":"t1","title":"","archived":false,"lastActivity":1,"awaitingQuestion":true}"#.utf8)
    let thread = try JSONDecoder().decode(ThreadSummary.self, from: json)
    #expect(ThreadStatus(thread, working: false) == .needsAnswer)
    #expect(ThreadStatus(thread, working: false)?.label == "Needs your answer")
    let failed = try JSONDecoder().decode(ThreadSummary.self, from: Data(
        #"{"id":"t2","title":"","archived":false,"lastActivity":2,"needsAttention":true}"#.utf8
    ))
    #expect(ThreadStatus(failed, working: false) == .needsAttention)
}
