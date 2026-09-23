import Testing

@testable import YorozuShared

private func message(_ id: String, _ role: MessageData.Role, done: Bool? = nil) -> YorozuEvent {
    YorozuEvent(id: id, threadId: "t", ts: 1, agentId: "main", payload: .message(MessageData(role: role, text: "x", done: done)))
}

@Test func onlyAnUnfinishedReplyAtTheEndIsStreaming() {
    #expect(streamingMessageId(in: [message("u1", .user), message("a1", .agent)]) == "a1")
    // Finished reply: rendered Markdown, not the plain streaming text.
    #expect(streamingMessageId(in: [message("u1", .user), message("a1", .agent, done: true)]) == nil)
    // A new user message after a finished reply starts a turn; the old reply is not streaming again.
    #expect(streamingMessageId(in: [message("u1", .user), message("a1", .agent), message("u2", .user)]) == nil)
    #expect(streamingMessageId(in: []) == nil)
}
