import Testing

@testable import YorozuShared

private func activityEvent(_ id: String, _ payload: YorozuEvent.Payload) -> YorozuEvent {
    YorozuEvent(id: id, threadId: "home", ts: 0, agentId: "main", payload: payload)
}

@Test func chatActivityWaitsForApprovalInsteadOfThinking() {
    let rows = chatRows(from: [activityEvent("card", .approvalCard(ApprovalCardData(
        actionId: "action", actionClass: "run", target: "echo hello"
    )))], generating: true)

    let activity = chatActivity(
        in: rows, generating: true, streamingId: nil,
        answeredApprovals: [], answeredQuestions: []
    )

    #expect(activity == .waitingForApproval)
    #expect(activity?.label == "Waiting for your approval")
    #expect(activity?.symbol != nil)

    // The answer set contains the action ID, which differs from the row's event ID.
    #expect(chatActivity(
        in: rows, generating: true, streamingId: nil,
        answeredApprovals: ["action"], answeredQuestions: []
    ) == .thinking)
    #expect(chatActivity(
        in: rows, generating: false, streamingId: nil,
        answeredApprovals: ["action"], answeredQuestions: []
    ) == nil)
}

@Test func chatActivityWaitsForQuestionAndResumesAfterItsAnswer() {
    let rows = chatRows(from: [activityEvent("question-card", .questionCard(QuestionCardData(
        questionId: "question", question: "Which folder?", options: ["Downloads", "Desktop"]
    )))], generating: true)

    #expect(chatActivity(
        in: rows, generating: true, streamingId: nil,
        answeredApprovals: [], answeredQuestions: []
    ) == .waitingForAnswer)
    #expect(ChatActivity.waitingForAnswer.symbol != nil)
    #expect(chatActivity(
        in: rows, generating: true, streamingId: nil,
        answeredApprovals: [], answeredQuestions: ["question"]
    ) == .thinking)
}

@Test func chatActivityDoesNotDuplicateStreamingOrLiveWork() {
    let reply = activityEvent("reply", .message(MessageData(role: .agent, text: "Checking")))
    #expect(chatActivity(
        in: chatRows(from: [reply], generating: true), generating: true, streamingId: "reply",
        answeredApprovals: [], answeredQuestions: []
    ) == nil)

    let work = activityEvent("work", .toolCall(ToolCallData(callId: "call", name: "Read", args: [:])))
    #expect(chatActivity(
        in: chatRows(from: [work], generating: true), generating: true, streamingId: nil,
        answeredApprovals: [], answeredQuestions: []
    ) == nil)

    // Finished work from an earlier turn must not suppress a new turn's initial status.
    let finished = activityEvent("finished", .message(MessageData(role: .agent, text: "Done", done: true)))
    let next = activityEvent("next", .message(MessageData(role: .user, text: "Continue")))
    #expect(chatActivity(
        in: chatRows(from: [work, finished, next], generating: true), generating: true, streamingId: nil,
        answeredApprovals: [], answeredQuestions: []
    ) == .thinking)
}

@Test func chatActivityKeepsActionableCardsVisibleAcrossGenerationAndDelegation() {
    var approval = activityEvent("delegated-card", .approvalCard(ApprovalCardData(
        actionId: "delegated-action", actionClass: "run", target: "echo hello"
    )))
    approval.agentId = "specialist"
    approval.parentAgentId = "main"
    let question = activityEvent("question-card", .questionCard(QuestionCardData(
        questionId: "question", question: "Which folder?", options: []
    )))
    let startup = activityEvent("startup", .thought(ThoughtData(text: "Working", transient: true)))
    let rows = chatRows(from: [question, approval, startup], generating: true)

    // Approval is the immediate decision even if live status or streamed text is also present.
    #expect(chatActivity(
        in: rows, generating: true, streamingId: "stream",
        answeredApprovals: [], answeredQuestions: []
    ) == .waitingForApproval)
    #expect(chatActivity(
        in: rows, generating: false, streamingId: nil,
        answeredApprovals: [], answeredQuestions: []
    ) == .waitingForApproval)
    #expect(chatActivity(
        in: rows, generating: false, streamingId: nil,
        answeredApprovals: ["delegated-action"], answeredQuestions: []
    ) == .waitingForAnswer)
    #expect(chatActivity(
        in: rows, generating: false, streamingId: nil,
        answeredApprovals: ["delegated-action"], answeredQuestions: ["question"]
    ) == nil)
}
