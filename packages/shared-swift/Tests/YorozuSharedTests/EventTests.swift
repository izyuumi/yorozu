import Foundation
import Testing

@testable import YorozuShared

private func roundTrip(_ event: YorozuEvent) throws -> YorozuEvent {
    try JSONDecoder().decode(YorozuEvent.self, from: JSONEncoder().encode(event))
}

@Test(arguments: YorozuEvent.Kind.allCases)
func everyKindRoundTrips(kind: YorozuEvent.Kind) throws {
    let payload: YorozuEvent.Payload =
        switch kind {
        case .message: .message(MessageData(role: .user, text: "hi"))
        case .thought: .thought(ThoughtData(text: "checking the catalog"))
        case .toolCall: .toolCall(ToolCallData(callId: "c1", name: "shell", args: ["cmd": .string("ls")]))
        case .toolResult: .toolResult(ToolResultData(callId: "c1", ok: true, output: "README.md"))
        case .approvalCard:
            .approvalCard(ApprovalCardData(actionId: "a1", actionClass: "purchase", target: "amazon", amount: 12))
        case .approvalAnswer: .approvalAnswer(ApprovalAnswerData(actionId: "a1", answer: .never))
        case .threadCreate: .threadCreate(ThreadCreateData(title: "Groceries"))
        case .threadList:
            .threadList(ThreadListData(threads: [
                ThreadSummary(id: "home", title: "Home", archived: false, pinned: true)
            ]))
        case .threadArchive: .threadArchive(ThreadArchiveData())
        case .syncRequest: .syncRequest(SyncRequestData(lastSeen: ["home": "e9"]))
        case .syncDelta:
            .syncDelta(SyncDeltaData(events: [
                YorozuEvent(id: "e2", threadId: "home", ts: 2, agentId: "main", payload: .thought(ThoughtData(text: "x")))
            ]))
        }
    let event = YorozuEvent(
        id: "e1",
        threadId: "home",
        ts: 1_757_640_000_000,
        agentId: "researcher",
        parentAgentId: "main",
        payload: payload
    )
    #expect(event.payload.kind == kind)
    #expect(try roundTrip(event) == event)
}

@Test func eventJsonUsesTheSharedShape() throws {
    let event = YorozuEvent(
        id: "e1",
        threadId: "home",
        ts: 1,
        agentId: "main",
        payload: .message(MessageData(role: .agent, text: "hi"))
    )
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
    #expect(json?["kind"] as? String == "message")
    #expect((json?["data"] as? [String: Any])?["role"] as? String == "agent")
    #expect(json?["parentAgentId"] == nil)
}

@Test func qrPayloadsRoundTripAndUntrustedInputIsRejected() throws {
    let qr = QrPayload(relayUrl: "wss://relay.yumi.to", macPubkey: "AAA", token: "t", roomId: "r")
    #expect(try QrPayload.decode(qr.encoded()) == qr)
    // Payloads minted before rooms were carried in the QR still decode.
    let legacy = QrPayload(relayUrl: "wss://relay.yumi.to", macPubkey: "AAA", token: "t")
    #expect(try QrPayload.decode(legacy.encoded()).roomId == nil)
    #expect(throws: (any Error).self) { try QrPayload.decode(#"{"v":2,"relayUrl":"","macPubkey":"","token":""}"#) }
    #expect(throws: (any Error).self) { try QrPayload.decode("not json") }
}
