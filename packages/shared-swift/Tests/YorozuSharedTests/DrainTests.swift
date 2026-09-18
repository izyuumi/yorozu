import Foundation
import Testing

@testable import YorozuShared

/// The background drain: what the phone does when the relay's silent push wakes it with the app
/// suspended. Dial, wait for the sync to land, hang up. See ``ChatModel/drain(timeout:)``.

/// A transport that only records what the drain does to it — how often it was dialled, how often
/// it hung up, and what was asked over it. Dialling answers the way the relay does, paired and
/// with the Mac awake, which is what makes the model ask for a sync at all.
private actor DrainTransport: ChatTransport {
    private var updates: AsyncStream<TransportUpdate>.Continuation?
    private(set) var connects = 0
    private(set) var closes = 0
    private(set) var sent: [YorozuEvent] = []

    func connect() -> AsyncStream<TransportUpdate> {
        connects += 1
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        updates = continuation
        continuation.yield(.state(.paired))
        continuation.yield(.ownerOnline(true))
        return stream
    }

    func send(_ event: YorozuEvent) async throws {
        sent.append(event)
    }

    func close() {
        closes += 1
        updates?.yield(.state(.closed))
        updates?.finish()
        updates = nil
    }

    /// The relay's answer landing, once the dial has been made.
    func deliver(_ update: TransportUpdate) {
        updates?.yield(update)
    }

    func asked() -> Bool {
        sent.contains {
            if case .syncRequest = $0.payload { return true }
            return false
        }
    }
}

private func delta(_ events: [YorozuEvent], more: Bool? = nil, id: String = "d1") -> TransportUpdate {
    .event(
        YorozuEvent(
            id: id,
            threadId: "",
            ts: 1,
            agentId: "main",
            payload: .syncDelta(SyncDeltaData(events: events, more: more))
        )
    )
}

private func reply(_ id: String, _ text: String, thread: String = "home") -> YorozuEvent {
    YorozuEvent(
        id: id,
        threadId: thread,
        ts: 1,
        agentId: "main",
        payload: .message(MessageData(role: .agent, text: text, done: true))
    )
}

/// The transport is an actor and the model applies on the main one, so a test waits for the
/// effect rather than assuming the hop between them has already happened.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
@Test func aBackgroundDrainDialsWaitsForTheDeltaAndHangsUp() async throws {
    let transport = DrainTransport()
    let model = ChatModel(transport: transport)

    async let drained = model.drain(timeout: .seconds(10))

    // Dialled by the drain itself: a suspended app has no socket left to reuse.
    #expect(await eventually { await transport.connects == 1 })
    // Connecting is what asks; the delta is the answer being waited for.
    #expect(await eventually { await transport.asked() })

    await transport.deliver(delta([reply("m1", "there you are")]))

    #expect(await drained)
    // Hung up rather than left open, so iOS suspends the app gracefully instead of tearing a
    // live socket out from under it.
    #expect(await eventually { await transport.closes == 1 })
    // Moved by the real events, not by anything the push claimed — it claimed nothing.
    #expect(model.events["home"]?.count == 1)
}

@MainActor
@Test func aDrainStaysOnTheLineUntilTheLastPageOfALongSync() async throws {
    let transport = DrainTransport()
    let model = ChatModel(transport: transport)

    async let drained = model.drain(timeout: .seconds(10))
    #expect(await eventually { await transport.asked() })

    // A phone far behind gets its sync in pages. Hanging up after the first would leave the
    // cache short of everything on the pages behind it.
    await transport.deliver(delta([reply("m1", "one")], more: true, id: "d1"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await transport.closes == 0)

    await transport.deliver(delta([reply("m2", "two")], id: "d2"))
    #expect(await drained)
    #expect(await eventually { await transport.closes == 1 })
    #expect(model.events["home"]?.count == 2)
}

private func card(_ id: String, actionId: String, thread: String = "home") -> YorozuEvent {
    YorozuEvent(
        id: id,
        threadId: thread,
        ts: 1,
        agentId: "main",
        payload: .approvalCard(ApprovalCardData(actionId: actionId, actionClass: "edit-file", target: "notes.md"))
    )
}

@MainActor
@Test func aLockScreenButtonAnswersTheCardThePushNamedAndHangsUp() async throws {
    let transport = DrainTransport()
    let model = ChatModel(transport: transport)
    let ref = YorozuCrypto.threadRef("card-1")

    async let answered = model.answerFromNotification(eventRef: ref, .yes, timeout: .seconds(10))
    #expect(await eventually { await transport.asked() })
    // The card was not in the cache: the sync connecting asked for is what brings it.
    await transport.deliver(delta([card("card-1", actionId: "a-1")]))

    #expect(await answered)
    let sent = await transport.sent
    let answer = sent.compactMap { event -> ApprovalAnswerData? in
        if case .approvalAnswer(let data) = event.payload { return data }
        return nil
    }
    // The same `approval_answer` the card would send, in the card's thread, and then hang up
    // so iOS suspends the app cleanly.
    #expect(answer == [ApprovalAnswerData(actionId: "a-1", answer: .yes)])
    #expect(sent.first { $0.payload.kind == .approvalAnswer }?.threadId == "home")
    #expect(model.answered.contains("a-1"))
    #expect(await eventually { await transport.closes == 1 })
}

@MainActor
@Test func aLockScreenButtonForACardThatNeverArrivesAnswersNothing() async throws {
    let transport = DrainTransport()
    let model = ChatModel(transport: transport)

    let answered = await model.answerFromNotification(
        eventRef: YorozuCrypto.threadRef("missing"), .no, timeout: .milliseconds(300)
    )

    // Left for the app to show rather than guessed at: no answer went out.
    #expect(!answered)
    #expect(await transport.sent.allSatisfy { $0.payload.kind != .approvalAnswer })
    #expect(await eventually { await transport.closes == 1 })
}

@MainActor
@Test func aDrainNothingAnswersGivesUpAndStillHangsUp() async throws {
    let transport = DrainTransport()
    let model = ChatModel(transport: transport)

    // Nothing is ever delivered: the Mac is away, or there was nothing to send after all. The
    // wake-up is reported as `.noData`, which is what the timeout here stands for.
    let drained = await model.drain(timeout: .milliseconds(200))

    #expect(!drained)
    #expect(await eventually { await transport.closes == 1 })
}

@MainActor
@Test func aSecondDrainDialsAgainRatherThanReusingASocketThatHungUp() async throws {
    let transport = DrainTransport()
    let model = ChatModel(transport: transport)

    _ = await model.drain(timeout: .milliseconds(100))
    _ = await model.drain(timeout: .milliseconds(100))

    // Two wake-ups, two dials: the first hang-up must not leave a model that can never
    // reconnect — which is also what the next foreground depends on.
    #expect(await eventually { await transport.connects == 2 })
    #expect(await eventually { await transport.closes == 2 })
}
