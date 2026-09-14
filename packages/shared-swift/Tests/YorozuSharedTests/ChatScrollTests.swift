import SwiftUI
import Testing

@testable import YorozuShared

@Test func manualScrollingAlwaysWinsOverStreamingAutoFollow() {
    #expect(followsNewest(atBottom: true, phase: .idle))
    #expect(followsNewest(atBottom: true, phase: .animating))
    #expect(!followsNewest(atBottom: true, phase: .tracking))
    #expect(!followsNewest(atBottom: true, phase: .interacting))
    #expect(!followsNewest(atBottom: true, phase: .decelerating))
    #expect(!followsNewest(atBottom: false, phase: .idle))
}

@Test func notificationResumeStartsAtFirstUnreadRowOrLatest() {
    func message(_ id: String, _ timestamp: Int) -> ChatRow {
        .message(YorozuEvent(
            id: id,
            threadId: "home",
            ts: timestamp,
            agentId: "main",
            payload: .message(MessageData(role: .agent, text: id))
        ))
    }

    let rows = [message("read", 100), message("first-unread", 200), message("latest", 300)]
    #expect(resumeRowId(rows: rows, lastReadAt: 150) == "first-unread")
    #expect(resumeRowId(rows: rows, lastReadAt: nil) == nil)
    #expect(resumeRowId(rows: rows, lastReadAt: 300) == nil)
}

@Test func notificationResumeSkipsGroupedActivityAndTargetsAssistantReply() {
    let events = [
        YorozuEvent(id: "call", threadId: "home", ts: 100, agentId: "main",
            payload: .toolCall(ToolCallData(callId: "tool", name: "read", args: [:]))),
        YorozuEvent(id: "result", threadId: "home", ts: 200, agentId: "main",
            payload: .toolResult(ToolResultData(callId: "tool", ok: true, output: "done"))),
        YorozuEvent(id: "reply", threadId: "home", ts: 300, agentId: "main",
            payload: .message(MessageData(role: .agent, text: "done", done: true))),
    ]
    let rows = chatRows(from: events)

    #expect(resumeRowId(rows: rows, lastReadAt: 150) == "reply")
}

@Test func notificationResumeWaitsWhenOnlyNewExecutionRowsHaveLoaded() {
    let rows = chatRows(from: [
        YorozuEvent(id: "progress", threadId: "home", ts: 200, agentId: "main",
            payload: .progressCard(ProgressCardData(
                cardId: "work", title: "Working", steps: []
            ))),
    ])

    #expect(resumeRowId(rows: rows, lastReadAt: 150) == nil)
    #expect(!notificationRefreshFinished(initialRevision: 4, currentRevision: 4))
    #expect(notificationRefreshFinished(initialRevision: 4, currentRevision: 5))
}

@Test func approvalNotificationResumesAtApprovalCard() {
    let rows = chatRows(from: [
        YorozuEvent(id: "reply", threadId: "home", ts: 200, agentId: "main",
            payload: .message(MessageData(role: .agent, text: "Before approval"))),
        YorozuEvent(id: "approval", threadId: "home", ts: 300, agentId: "main",
            payload: .approvalCard(ApprovalCardData(
                actionId: "card", actionClass: "send-message", target: "recipient"
            ))),
    ])

    #expect(resumeRowId(
        rows: rows,
        lastReadAt: 100,
        notificationClass: "approval"
    ) == "approval")
}
