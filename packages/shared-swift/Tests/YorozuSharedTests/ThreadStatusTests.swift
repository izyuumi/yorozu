import Foundation
import Testing

@testable import YorozuShared

private func summary(
    approval: Bool? = nil, question: Bool? = nil, interrupted: String? = nil,
    failed: Bool? = nil, active: String? = nil, unread: Bool = false, turnState: ThreadTurnState? = nil
) -> ThreadSummary {
    ThreadSummary(
        id: "t", title: "Deploy", archived: false, lastActivity: 1,
        lastReadAt: 10, lastAgentAt: unread ? 20 : 5,
        awaitingApproval: approval, awaitingQuestion: question, needsAttention: failed,
        interruptedTurnId: interrupted, activeEventId: active, turnState: turnState
    )
}

/// Every lower state is present, so these prove order rather than flag presence.
/// Labels are also what VoiceOver reads for both rows and group headings.
@Test(arguments: [
    (summary(approval: true, question: true, interrupted: "turn", unread: true), true, "Needs approval"),
    (summary(question: true, interrupted: "turn", unread: true), true, "Needs input"),
    (summary(failed: true, unread: true), true, "Failed"),
    (summary(interrupted: "turn", unread: true), true, "Failed"),
    (summary(active: "event", unread: true), false, "Working"),
    (summary(unread: true), true, "Working"),
    (summary(unread: true), false, "Done, unread"),
    (summary(), false, "Idle"),
    // A host-owned idle wins over stale legacy hints; every live host phase is working.
    (summary(active: "stale", turnState: .idle), true, "Idle"),
    (summary(unread: true, turnState: .idle), true, "Done, unread"),
    (summary(turnState: .starting), false, "Working"),
    (summary(turnState: .running), false, "Working"),
    (summary(turnState: .stopping), false, "Working"),
    (summary(turnState: .stoppedUnconfirmed), false, "Failed"),
])
func aRowWearsItsHighestRankedStatus(thread: ThreadSummary, working: Bool, expected: String) {
    #expect(ThreadStatus(thread, working: working).label == expected)
}

/// The runtime spells the pending-question flag `awaitingQuestion`, beside `awaitingApproval`.
@Test func actionableStatusFlagsArriveOnTheWire() throws {
    let json = Data(#"{"id":"t1","title":"","archived":false,"lastActivity":1,"awaitingQuestion":true}"#.utf8)
    let thread = try JSONDecoder().decode(ThreadSummary.self, from: json)
    #expect(ThreadStatus(thread, working: false) == .needsInput)
    #expect(ThreadStatus(thread, working: false).label == "Needs input")
    let failed = try JSONDecoder().decode(ThreadSummary.self, from: Data(
        #"{"id":"t2","title":"","archived":false,"lastActivity":2,"needsAttention":true}"#.utf8
    ))
    #expect(ThreadStatus(failed, working: false) == .failed)
}

@Test func groupHeaderReportsMostUrgentChild() {
    var working = summary()
    working.id = "working"
    let children = [summary(), summary(unread: true), working, summary(failed: true),
                    summary(question: true), summary(approval: true)]
    let labels = ["Idle", "Done, unread", "Working", "Failed", "Needs input", "Needs approval"]
    for count in 1...children.count {
        #expect(ThreadStatus.highest(in: Array(children.prefix(count)), workingThreads: ["working"])?.label
            == labels[count - 1])
        #expect(ThreadStatus.highest(in: Array(children.prefix(count).reversed()), workingThreads: ["working"])?.label
            == labels[count - 1])
    }
    #expect(ThreadStatus.highest(in: [], workingThreads: []) == nil)
}
