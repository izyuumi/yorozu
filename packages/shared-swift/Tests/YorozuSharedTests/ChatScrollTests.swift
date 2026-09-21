import SwiftUI
import Testing

@testable import YorozuShared

@Test func openingFollowSurvivesAsyncReplayAndLayoutGrowth() {
    var intent = NewestScrollIntent()

    #expect(intent.shouldPinLatest(during: .idle))
    intent.observe(atBottom: true, phase: .idle)
    // Sync replay or a self-sizing row can grow the content after the first layout. Geometry is
    // no longer at the bottom, but nobody asked to leave the newest content.
    intent.observe(atBottom: false, phase: .idle)
    #expect(intent.shouldPinLatest(during: .idle))
}

@Test func manualScrollingAlwaysWinsOverAsyncAutoFollow() {
    var intent = NewestScrollIntent()

    intent.observe(atBottom: true, phase: .tracking)
    #expect(!intent.shouldPinLatest(during: .tracking))
    #expect(!intent.shouldPinLatest(during: .interacting))
    #expect(!intent.shouldPinLatest(during: .decelerating))

    // More replay or another layout pass must not undo a reader's drag.
    intent.observe(atBottom: false, phase: .idle)
    #expect(!intent.shouldPinLatest(during: .idle))

    // Deliberately returning to the bottom opts back in to normal streaming follow.
    intent.observe(atBottom: true, phase: .idle)
    #expect(intent.shouldPinLatest(during: .idle))
}

@Test func targetedNavigationIsNotOverriddenByOpeningFollow() {
    var intent = NewestScrollIntent()

    intent.targetEvent()
    #expect(!intent.shouldPinLatest(during: .idle))

    intent.followLatest()
    #expect(intent.shouldPinLatest(during: .idle))
}

@Test func jumpToLatestNeedsMoreThanOneViewportOfDistance() {
    #expect(!showsJumpToLatest(contentHeight: 2_000, visibleBottom: 1_500, viewportHeight: 500))
    #expect(showsJumpToLatest(contentHeight: 2_001, visibleBottom: 1_500, viewportHeight: 500))
    #expect(!showsJumpToLatest(contentHeight: 2_000, visibleBottom: 500, viewportHeight: 0))
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

@Test func approvalNotificationResumesAtItsExactCard() {
    let rows = chatRows(from: [
        YorozuEvent(id: "first", threadId: "home", ts: 200, agentId: "main",
            payload: .approvalCard(ApprovalCardData(
                actionId: "first-action", actionClass: "send-message", target: "first"
            ))),
        YorozuEvent(id: "second", threadId: "home", ts: 300, agentId: "main",
            payload: .approvalCard(ApprovalCardData(
                actionId: "second-action", actionClass: "send-message", target: "second"
            ))),
    ])

    #expect(resumeRowId(
        rows: rows,
        lastReadAt: 100,
        notificationClass: "approval",
        notificationEventRef: YorozuCrypto.threadRef("second")
    ) == "second")
    #expect(resumeRowId(
        rows: rows,
        lastReadAt: 100,
        notificationClass: "approval",
        notificationEventRef: YorozuCrypto.threadRef("not-loaded")
    ) == nil)
}

@Test func exactNotificationEventWinsEvenWhenThreadHasNeverBeenRead() {
    let rows = chatRows(from: [
        YorozuEvent(id: "first", threadId: "home", ts: 200, agentId: "main",
            payload: .message(MessageData(role: .agent, text: "First"))),
        YorozuEvent(id: "notified", threadId: "home", ts: 300, agentId: "main",
            payload: .message(MessageData(role: .agent, text: "Notified", done: true))),
        YorozuEvent(id: "later", threadId: "home", ts: 400, agentId: "main",
            payload: .message(MessageData(role: .agent, text: "Later", done: true))),
    ])

    #expect(resumeRowId(
        rows: rows,
        lastReadAt: nil,
        notificationClass: "reply",
        notificationEventRef: YorozuCrypto.threadRef("notified")
    ) == "notified")
}
