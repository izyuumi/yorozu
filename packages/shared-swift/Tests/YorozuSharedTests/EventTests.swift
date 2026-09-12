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
        case .threadRename: .threadRename(ThreadRenameData(title: "Weekend plans"))
        case .interrupt: .interrupt(InterruptData())
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

@Test func aFinishedDelegationFlagsItsLastMessage() throws {
    let event = YorozuEvent(
        id: "e1",
        threadId: "home",
        ts: 1,
        agentId: "calendar",
        parentAgentId: "main",
        payload: .message(MessageData(role: .agent, text: "booked", done: true))
    )
    #expect(try roundTrip(event) == event)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
    #expect((json?["data"] as? [String: Any])?["done"] as? Bool == true)

    // Absent on every other message, so the flag means exactly one thing on the wire.
    let plain = YorozuEvent(
        id: "e2",
        threadId: "home",
        ts: 1,
        agentId: "main",
        payload: .message(MessageData(role: .agent, text: "hi"))
    )
    let plainJson = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
    #expect((plainJson?["data"] as? [String: Any])?["done"] == nil)
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

@Test func pairingStringsAreParsedWhereverTheyCameFrom() throws {
    // What TypeScript's `encodePairingString` writes, percent-encoding and all.
    let code = "yorozu://pair?v=1&relay=ws%3A%2F%2F127.0.0.1%3A8791&key=AAA&token=t-_&room=r"
    #expect(
        try QrPayload.decode(code)
            == QrPayload(relayUrl: "ws://127.0.0.1:8791", macPubkey: "AAA", token: "t-_", roomId: "r")
    )
    // Whitespace is what a paste out of Messages brings with it.
    #expect(try QrPayload.decode("  \(code)\n").roomId == "r")
    #expect(try QrPayload.decode("yorozu://pair?v=1&relay=ws://r&key=AAA&token=t").roomId == nil)

    #expect(throws: (any Error).self) { try QrPayload.decode("yorozu://pair?v=1&relay=ws://r&token=t") }
    #expect(throws: (any Error).self) { try QrPayload.decode("yorozu://pair?v=1&key=AAA&token=t") }
    #expect(throws: (any Error).self) { try QrPayload.decode("yorozu://pair?v=1&relay=ws://r&key=AAA") }
    #expect(throws: (any Error).self) { try QrPayload.decode("yorozu://pair?v=2&relay=ws://r&key=AAA&token=t") }
    #expect(throws: (any Error).self) {
        try QrPayload.decode("yorozu://pair?v=1&relay=ws://r&key=not%20base64!&token=t")
    }
    #expect(throws: (any Error).self) { try QrPayload.decode("yorozu://nonsense") }
}
