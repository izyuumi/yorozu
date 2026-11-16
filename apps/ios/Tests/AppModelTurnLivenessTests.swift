import Foundation
import Testing
import YorozuWire

/// A turn stays one turn from the owner's send to an observed end: connection gaps don't end it (PR 1.13).
/// The model's timers are set too long to fire; tests set `now` and call the timers' fired paths.
@MainActor
@Suite struct AppModelTurnLivenessTests {
    private let harness: ModelHarness
    private let messageId = WireEvent.newId()
    private let start = Int64(Date().timeIntervalSince1970 * 1000)

    init() throws {
        harness = try ModelHarness()
        _ = try harness.store(paired: true)
    }

    private var convId: String { harness.convId }

    /// A ready model at `start` whose conversation's last item is the owner's message, `age` old, at `status`.
    private func opened(age: Int64 = 11 * 60 * 1000, status: SendStatus = .delivered) async throws -> (AppModel, ScriptedTransport) {
        var conversation = Conversation(id: convId, createdAt: 1, updatedAt: 1)
        conversation.items = [ChatItem(id: messageId, kind: .user, text: "Hello", ts: start - age, status: status)]
        harness.seed([conversation])
        let model = try await harness.openFirstSession()
        model.typingTimeout = .seconds(3600)
        model.stallTimeout = .seconds(3600)
        let start = self.start
        model.now = { start }
        return (model, try #require(harness.scripted))
    }

    private func started(_ model: AppModel, _ transport: ScriptedTransport) async throws {
        await transport.emit(.event(.runStarted(MessageRef(convId: convId, messageId: messageId))))
        try #require(await harness.settled { model.typing.contains(convId) })
    }

    /// `opened()` with the turn started and the session then lost.
    private func startedThenLost() async throws -> (AppModel, ScriptedTransport) {
        let (model, transport) = try await opened()
        try await started(model, transport)
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

    /// A late timeout after the turns were cleared must bring back neither typing nor the stall banner.
    private func expectNoTurns(_ model: AppModel) {
        #expect(model.typing.isEmpty)
        #expect(model.stalled.isEmpty)
        #expect(model.typingTimers.isEmpty)
        #expect(model.stallTimers.isEmpty)
        model.typingTimerFired(convId)
        model.stallTimerFired(convId)
        #expect(model.typing.isEmpty)
        #expect(model.stalled.isEmpty)
    }

    @Test func typingSurvivesAGapWhileNotReady() async throws {
        let (model, _) = try await startedThenLost()
        model.typingTimerFired(convId)
        #expect(model.state != .ready)
        #expect(model.awaitingReply.contains(convId))
        #expect(model.typing.contains(convId))
        #expect(model.typingTimers[convId] != nil)
    }

    @Test func typingLapsesAfterAReadySessionStaysSilent() async throws {
        let (model, transport) = try await startedThenLost()
        model.typingTimerFired(convId)
        try await reopen(transport, model)
        model.typingTimerFired(convId)
        #expect(!model.typing.contains(convId))
        #expect(!model.awaitingReply.contains(convId))
    }

    @Test func aKeepaliveAfterReconnectKeepsTheSameRow() async throws {
        let (model, transport) = try await startedThenLost()
        model.typingTimerFired(convId)
        try await reopen(transport, model)
        let armed = try #require(model.typingTimers[convId])
        await transport.emit(.event(.typing(Typing(convId: convId, active: true))))
        #expect(await harness.settled { model.typingTimers[convId] != armed })
        #expect(model.typing.contains(convId))
        #expect(model.awaitingReply.contains(convId))
    }

    @Test func heldTypingEndsAfterTheAwaitingWindow() async throws {
        let (model, transport) = try await opened()
        try await started(model, transport)
        let gap = ContinuousClock.now, window = Duration.milliseconds(model.awaitingWindow)
        model.clock = { gap }
        await transport.emit(.state(.offline))
        try #require(await harness.settled { model.state != .ready })
        model.clock = { gap + window / 2 }
        model.typingTimerFired(convId)
        #expect(model.typing.contains(convId))
        model.clock = { gap + window + .milliseconds(1) }
        model.typingTimerFired(convId)
        #expect(model.state != .ready)
        #expect(!model.typing.contains(convId))
        #expect(!model.awaitingReply.contains(convId))
        #expect(model.typingTimers[convId] == nil)
    }

    /// The cap counts the gap, not the turn: a long turn isn't dropped at its first short gap.
    @Test func aLongTurnSurvivesAShortGap() async throws {
        let (model, transport) = try await opened()
        try await started(model, transport)
        let start = self.start
        model.now = { start + 15 * 60 * 1000 }
        await transport.emit(.state(.offline))
        try #require(await harness.settled { model.state != .ready })
        model.typingTimerFired(convId)
        #expect(model.typing.contains(convId))
        #expect(model.awaitingReply.contains(convId))
    }

    /// Replies come in chunks and several blocks per run; none of them ends the turn's row.
    @Test func replyChunksKeepOneTurn() async throws {
        let (model, transport) = try await opened()
        try await started(model, transport)
        // Keep the chat in view so a Mac test doesn't post a user notification for the reply.
        model.setActive(true)
        model.setOnScreen(convId, true)
        let first = WireEvent.newId(), second = WireEvent.newId()
        await transport.emit(.event(.reply(Reply(convId: convId, messageId: first, text: "Hi", ts: start))))
        await transport.emit(.event(.reply(Reply(convId: convId, messageId: second, text: "There", ts: start + 1))))
        #expect(await harness.settled { model.conversations[convId]?.items.last?.id == second })
        let armed = try #require(model.typingTimers[convId])
        await transport.emit(.event(.typing(Typing(convId: convId, active: true))))
        #expect(await harness.settled { model.typingTimers[convId] != armed })
        #expect(model.typing.contains(convId))
        #expect(model.awaitingReply.contains(convId))
        #expect(model.typingTimers[convId] != nil)
    }

    @Test func aTurnThatNeverStartedStillLeavesAfterTheWindow() async throws {
        let (model, _) = try await opened(age: 0, status: .sent)
        #expect(model.awaitingReply.contains(convId))
        let window = model.awaitingWindow, start = self.start
        model.now = { start + window + 1 }
        #expect(!model.awaitingReply.contains(convId))
    }

    @Test func aStallBannerStillShowsWhileTypingIsHeld() async throws {
        let (model, _) = try await startedThenLost()
        model.typingTimerFired(convId)
        #expect(model.stallTimers[convId] != nil)
        model.stallTimerFired(convId)
        #expect(model.stalled.contains(convId))
        #expect(model.state != .ready)
    }

    @Test func unpairClearsTyping() async throws {
        let (model, transport) = try await opened()
        try await started(model, transport)
        model.unpair()
        expectNoTurns(model)
    }

    @Test func demoClearsTyping() async throws {
        let (model, transport) = try await opened()
        try await started(model, transport)
        model.enterDemo()
        expectNoTurns(model)
    }

    @Test func aNewPairingClearsTyping() async throws {
        let (model, transport) = try await opened()
        try await started(model, transport)
        model.notice = InAppNotice(convId: convId, title: "Chat", text: "Hi")
        let payload = QrPayload(v: 3, relayUrl: "wss://relay.example/ws", macPubkey: Data(repeating: 1, count: 32).base64URLEncodedString(),
            token: "tok", roomId: "room-new", secret: Data(repeating: 2, count: 32).base64URLEncodedString())
        model.confirm(payload)
        expectNoTurns(model)
        #expect(harness.stored()?.pairing.roomId == "room-new")
        // A new pairing ends turns, not the rest of the transient state.
        #expect(model.notice != nil)
    }

    @Test func aRebuiltTurnRowKeepsItsStart() {
        let sent: Int64 = 1_800_000_123_456
        let first = YorozuJob.turnStart(sent: sent, now: Date(timeIntervalSince1970: 1_800_000_200))
        let rebuilt = YorozuJob.turnStart(sent: sent, now: Date(timeIntervalSince1970: 1_800_000_900))
        #expect(first == rebuilt)
        #expect(first == Date(timeIntervalSince1970: Double(sent) / 1000))
        let now = Date(timeIntervalSince1970: 1_800_000_300)
        #expect(YorozuJob.turnStart(sent: nil, now: now) == now)
    }
}
