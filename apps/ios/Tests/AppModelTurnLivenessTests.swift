import Foundation
import Testing
import YorozuWire

/// A turn stays one turn from the owner's send to an observed end: connection gaps don't end it (PR 1.13).
@MainActor
@Suite struct AppModelTurnLivenessTests {
    private let harness: ModelHarness
    private let messageId = WireEvent.newId()
    private let timeout: Duration = .milliseconds(150)
    private let wait: Duration = .milliseconds(400)

    init() throws {
        harness = try ModelHarness()
        _ = try harness.store(paired: true)
    }

    private var convId: String { harness.convId }
    private static var wallClock: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// A ready model whose conversation's last item is the owner's message, `age` old, at `status`.
    private func opened(age: Int64 = 11 * 60 * 1000, status: SendStatus = .delivered,
        window: Int64? = nil) async throws -> (AppModel, ScriptedTransport) {
        var conversation = Conversation(id: convId, createdAt: 1, updatedAt: 1)
        conversation.items = [ChatItem(id: messageId, kind: .user, text: "Hello", ts: Self.wallClock - age, status: status)]
        harness.seed([conversation])
        let model = try await harness.openFirstSession()
        model.typingTimeout = timeout
        model.stallTimeout = .seconds(60)
        if let window { model.awaitingWindow = window }
        return (model, try #require(harness.scripted))
    }

    /// `opened()` with the turn started and the session then lost.
    private func startedThenLost() async throws -> (AppModel, ScriptedTransport) {
        let (model, transport) = try await opened()
        await transport.emit(.event(.runStarted(MessageRef(convId: convId, messageId: messageId))))
        try #require(await harness.settled { model.typing.contains(convId) })
        await transport.emit(.state(.offline))
        try #require(await harness.settled { model.state != .ready })
        return (model, transport)
    }

    private func reopen(_ transport: ScriptedTransport, _ model: AppModel) async throws {
        let before = model.sessionsOpened
        await transport.emit(.state(.ready))
        await transport.emit(.sessionOpen(PeerInfo(app: "test")))
        try #require(await harness.settled { model.sessionsOpened > before })
    }

    @Test func typingSurvivesAGapWhileNotReady() async throws {
        let (model, _) = try await startedThenLost()
        try await Task.sleep(for: wait)
        #expect(model.state != .ready)
        #expect(model.awaitingReply.contains(convId))
        #expect(model.typing.contains(convId))
    }

    @Test func typingLapsesAfterAReadySessionStaysSilent() async throws {
        let (model, transport) = try await startedThenLost()
        try await Task.sleep(for: wait)
        try await reopen(transport, model)
        try await Task.sleep(for: wait)
        #expect(!model.typing.contains(convId))
        #expect(!model.awaitingReply.contains(convId))
    }

    @Test func aKeepaliveAfterReconnectKeepsTheSameRow() async throws {
        let (model, transport) = try await startedThenLost()
        try await Task.sleep(for: wait)
        try await reopen(transport, model)
        await transport.emit(.event(.typing(Typing(convId: convId, active: true))))
        try await Task.sleep(for: timeout / 2)
        #expect(model.typing.contains(convId))
        #expect(model.awaitingReply.contains(convId))
    }

    @Test func aTurnThatNeverStartedStillLeavesAfterTheWindow() async throws {
        let (model, _) = try await opened(age: 0, status: .sent, window: 500)
        #expect(model.awaitingReply.contains(convId))
        try await Task.sleep(for: .milliseconds(700))
        #expect(!model.awaitingReply.contains(convId))
    }

    @Test func aStallBannerStillShowsWhileTypingIsHeld() async throws {
        let (model, transport) = try await opened()
        model.stallTimeout = .milliseconds(250)
        await transport.emit(.event(.runStarted(MessageRef(convId: convId, messageId: messageId))))
        try #require(await harness.settled { model.typing.contains(convId) })
        await transport.emit(.state(.offline))
        try #require(await harness.settled { model.state != .ready })
        #expect(await harness.settled { model.stalled.contains(convId) })
        #expect(model.state != .ready)
    }

    @Test func unpairClearsTyping() async throws {
        let (model, transport) = try await opened()
        // A stall timer outliving unpair would raise the banner for a chat that no longer exists.
        model.stallTimeout = timeout
        model.typingTimeout = .seconds(60)
        await transport.emit(.event(.runStarted(MessageRef(convId: convId, messageId: messageId))))
        try #require(await harness.settled { model.typing.contains(convId) })
        model.unpair()
        #expect(model.typing.isEmpty)
        try await Task.sleep(for: wait)
        #expect(model.typing.isEmpty)
        #expect(model.stalled.isEmpty)
    }

    @Test func demoClearsTyping() async throws {
        let (model, transport) = try await opened()
        await transport.emit(.event(.runStarted(MessageRef(convId: convId, messageId: messageId))))
        try #require(await harness.settled { model.typing.contains(convId) })
        model.enterDemo()
        #expect(model.typing.isEmpty)
        try await Task.sleep(for: wait)
        #expect(model.typing.isEmpty)
    }

    @Test func aNewPairingClearsTyping() async throws {
        let (model, transport) = try await opened()
        model.stallTimeout = timeout
        await transport.emit(.event(.runStarted(MessageRef(convId: convId, messageId: messageId))))
        try #require(await harness.settled { model.typing.contains(convId) })
        let payload = QrPayload(v: 3, relayUrl: "wss://relay.example/ws", macPubkey: Data(repeating: 1, count: 32).base64URLEncodedString(),
            token: "tok", roomId: "room-new", secret: Data(repeating: 2, count: 32).base64URLEncodedString())
        model.confirm(payload)
        #expect(model.typing.isEmpty)
        try await Task.sleep(for: wait)
        #expect(model.typing.isEmpty)
        #expect(model.stalled.isEmpty)
        #expect(harness.stored()?.pairing.roomId == "room-new")
    }
}
