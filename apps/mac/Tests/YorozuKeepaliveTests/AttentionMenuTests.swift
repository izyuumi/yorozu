import CryptoKit
import Foundation
import Testing
import YorozuShared

@testable import YorozuMac

private actor IdleAttentionTransport: ChatTransport {
    func connect() -> AsyncStream<TransportUpdate> { AsyncStream { $0.finish() } }
    func send(_ event: YorozuEvent) async throws {}
    func close() {}
}

@MainActor @Test func needsAttentionShowsEveryLiveCardAndNoResolvedCard() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("yorozu-attention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: SymmetricKey(size: .bits256))
    cache.save(threads: [ThreadSummary(id: "thread", title: "Build", archived: false,
                                       lastActivity: 100, awaitingApproval: true, awaitingQuestion: true)])
    func event(_ id: String, _ ts: Int, _ payload: YorozuEvent.Payload) -> YorozuEvent {
        YorozuEvent(id: id, threadId: "thread", ts: ts, agentId: "main", payload: payload)
    }
    cache.save(events: [
        event("approval-1", 1, .approvalCard(ApprovalCardData(actionId: "action-1", actionClass: "shell", target: "pwd"))),
        event("approval-2", 2, .approvalCard(ApprovalCardData(actionId: "action-2", actionClass: "shell", target: "ls"))),
        event("approval-expired", 3, .approvalCard(ApprovalCardData(actionId: "action-expired", actionClass: "shell", target: "date"))),
        event("approval-status", 4, .approvalStatus(ApprovalStatusData(requestId: "request", actionId: "action-expired", status: .expired))),
        event("question-1", 5, .questionCard(QuestionCardData(questionId: "question-1", question: "First?", options: ["A"]))),
        event("question-2", 6, .questionCard(QuestionCardData(questionId: "question-2", question: "Second?", options: ["B"]))),
        event("question-answered", 7, .questionCard(QuestionCardData(questionId: "question-answered", question: "Done?", options: ["C"]))),
        event("question-answer", 8, .questionAnswer(QuestionAnswerData(questionId: "question-answered", answer: "C")))
    ], threadId: "thread")

    let model = ChatModel(transport: IdleAttentionTransport(), cache: cache)
    let items = MacAttentionItem.pending(in: model)

    #expect(Set(items.compactMap(\.eventID)) == ["approval-1", "approval-2", "question-1", "question-2"])
    #expect(Set(items.map(\.id)).count == 4)
}
