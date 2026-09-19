import Foundation
import Testing

@testable import YorozuShared

/// A transport that can be told to refuse, so a send that fails is a test rather than an
/// unplugged cable. It answers every send with the runtime's receipt, as the runtime does —
/// unless told to swallow them, which is what a half-open socket looks like from here.
private actor QueueTransport: ChatTransport {
    private var updates: AsyncStream<TransportUpdate>.Continuation?
    private var held: [TransportUpdate] = []
    private(set) var sent: [YorozuEvent] = []
    private var refusing = false
    private var swallowing = false

    struct Refused: Error {}

    func connect() -> AsyncStream<TransportUpdate> {
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        updates = continuation
        for update in held { continuation.yield(update) }
        held = []
        return stream
    }

    func send(_ event: YorozuEvent) async throws {
        if refusing { throw Refused() }
        sent.append(event)
        guard !swallowing else { return }
        yield(.event(YorozuEvent(
            id: "r-\(event.id)", threadId: "", ts: 1, agentId: "main",
            payload: .receipt(ReceiptData(eventId: event.id))
        )))
    }

    func swallow(_ swallowing: Bool) { self.swallowing = swallowing }

    func close() {
        updates?.finish()
        updates = nil
    }

    func refuse(_ refusing: Bool) { self.refusing = refusing }

    func yield(_ update: TransportUpdate) {
        if let updates { updates.yield(update) } else { held.append(update) }
    }

    var messages: [YorozuEvent] { sent.filter { $0.payload.kind == .message } }
}

@MainActor
private func settle(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Brings the link up: paired, and the Mac awake behind it.
private func reconnect(_ transport: QueueTransport) async {
    await transport.yield(.state(.paired))
    await transport.yield(.ownerOnline(true))
}

@MainActor
@Test func messagesTypedWithNowhereToSendThemWaitAndGoOutInOrder() async throws {
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, device: "phone")
    model.start()

    // Still dialling: there is nowhere for these to go.
    #expect(!model.canDeliver)
    model.send("one", in: "home")
    model.send("two", in: "home")

    // They are in the thread all the same, captioned as waiting, and nothing has been sent.
    #expect(model.events["home"]?.count == 2)
    #expect(model.outbox.count == 2)
    #expect(model.outbox.allSatisfy { $0.status == .queued })
    #expect(await transport.sent.isEmpty)
    // And no turn has started: nothing is generating a reply to a message nobody has received.
    #expect(!model.generating.contains("home"))

    let queuedIds = model.outbox.map(\.id)
    await reconnect(transport)

    #expect(await settle { model.outbox.isEmpty })
    let sent = await transport.messages
    #expect(sent.map(\.id) == queuedIds)
    #expect(
        sent.compactMap {
            if case .message(let data) = $0.payload { return data.text }
            return nil
        } == ["one", "two"]
    )
}

@MainActor
@Test func aThreadStartedOfflineIsCreatedAheadOfTheMessageThatStartedIt() async throws {
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, device: "phone")
    model.start()

    let draft = model.newDraft()
    model.send("hi", in: draft.id)

    // The create and the message queue together, in that order: the other end cannot be told
    // about a message in a thread it has never heard of.
    #expect(model.outbox.map(\.event.payload.kind) == [.threadCreate, .message])
    await reconnect(transport)

    #expect(await settle { model.outbox.isEmpty })
    let sent = await transport.sent.filter { $0.threadId == draft.id }
    #expect(sent.map(\.payload.kind) == [.threadCreate, .message])
}

@MainActor
@Test func anArchiveRequestSurvivesDisconnectionAndFlushesOnReconnect() async throws {
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, device: "phone")
    model.start()
    let thread = ThreadSummary(id: "t1", title: "Kyoto", archived: false, lastActivity: 1)
    await transport.yield(.event(YorozuEvent(
        id: "threads", threadId: "", ts: 1, agentId: "main",
        payload: .threadList(ThreadListData(threads: [thread]))
    )))
    #expect(await settle { model.threads == [thread] })

    model.archive(model.threads[0])
    #expect(model.threads[0].archived)
    #expect(model.outbox.map(\.event.payload.kind) == [.threadArchive])
    #expect(await transport.sent.isEmpty)

    await reconnect(transport)
    #expect(await settle { model.outbox.isEmpty })
    // Beside pairing's own requests, which go out in tasks of their own around the flush.
    #expect(await transport.sent.map(\.payload).contains(.threadArchive(ThreadArchiveData(archived: true))))
}

@MainActor
@Test func aRefusedArchiveRequestRemainsQueuedInsteadOfDisappearing() async throws {
    let transport = QueueTransport()
    await transport.refuse(true)
    let model = ChatModel(transport: transport, device: "phone")
    model.start()
    await reconnect(transport)

    let thread = ThreadSummary(id: "t1", title: "Kyoto", archived: false, lastActivity: 1)
    model.setArchived(thread, true)
    #expect(await settle { model.outbox.first?.tries == 1 })
    #expect(model.outbox.first?.event.payload == .threadArchive(ThreadArchiveData(archived: true)))
}

@MainActor
@Test func aMessageThatWillNotGoGivesUpAfterThreeTriesAndOffersARetry() async throws {
    let transport = QueueTransport()
    await transport.refuse(true)
    let model = ChatModel(transport: transport, device: "phone")
    model.start()

    model.send("hi", in: "home")
    let id = try #require(model.outbox.first?.id)

    // Refused every time: after three tries the queue stops trying by itself. How many tries
    // one reconnection is worth is the transport's business, so this reconnects until the
    // message has spent them rather than counting them out one by one.
    for _ in 0..<3 {
        await reconnect(transport)
        _ = await settle { model.outboxStatus(of: id) == .failed }
    }
    #expect(model.outboxStatus(of: id) == .failed)
    // Exactly three, never more: a message it has given up on is stepped over, not retried.
    #expect(model.outbox.first?.tries == Outbox.maxTries)

    // A reconnection now leaves it alone — it is waiting on the person, not on the network.
    await reconnect(transport)
    #expect(await transport.messages.isEmpty)

    // Tapping the caption is a fresh three tries, and this time the send lands.
    await transport.refuse(false)
    model.retry(id)
    #expect(await settle { model.outbox.isEmpty })
    #expect(await transport.messages.map(\.id) == [id])
}

@MainActor
@Test func aQueuedMessageSurvivesTheAppBeingClosed() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))

    let first = ChatModel(transport: QueueTransport(), cache: cache, device: "phone")
    first.start()
    first.send("held", in: "home")
    let id = try #require(first.outbox.first?.id)

    // A second launch, reading the same cache: the message is still waiting, still queued.
    let transport = QueueTransport()
    let second = ChatModel(transport: transport, cache: cache, device: "phone")
    second.start()
    #expect(second.outbox.map(\.id) == [id])
    #expect(second.outboxStatus(of: id) == .queued)

    await reconnect(transport)
    #expect(await settle { second.outbox.isEmpty })
    #expect(await transport.messages.map(\.id) == [id])
    // And the flushed queue is written back, so a third launch does not send it again.
    #expect(cache.outbox().isEmpty)
}

@MainActor
@Test func aMessageSentOnAHalfOpenSocketIsKeptAndSentAgainUntilTheRuntimeReceiptsIt() async throws {
    let transport = QueueTransport()
    await transport.swallow(true)
    let model = ChatModel(transport: transport, device: "phone")
    model.start()
    await reconnect(transport)
    #expect(await settle { model.canDeliver })

    // The link looks fine, so the send goes straight out — and there is no caption, because
    // nothing is known to be wrong yet.
    model.send("hi", in: "home")
    let id = try #require(model.outbox.first?.id)
    var count = 0
    for _ in 0..<300 where count == 0 {
        count = await transport.messages.count
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(count == 1)
    #expect(model.outboxStatus(of: id) == nil)
    // But the runtime never said it had it, so it is still ours to deliver.
    #expect(model.outbox.map(\.id) == [id])

    // The socket turns out to have been dead: the next link sends it again, same id.
    await transport.yield(.ownerOnline(false))
    #expect(await settle { model.outboxStatus(of: id) == .queued })
    await transport.swallow(false)
    await reconnect(transport)
    #expect(await settle { model.outbox.isEmpty })
    #expect(await transport.messages.map(\.id) == [id, id])
}

@Test func theQueueStopsTryingAfterTwoDaysAndHoldsOnlyFifty() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func item(_ id: String, hoursAgo: Double) -> OutboxItem {
        OutboxItem(
            event: YorozuEvent(
                id: id,
                threadId: "home",
                ts: Int((now.timeIntervalSince1970 - hoursAgo * 3600) * 1000),
                agentId: "phone",
                payload: .message(MessageData(role: .user, text: id))
            )
        )
    }

    let pruned = Outbox.pruned([item("fresh", hoursAgo: 1), item("stale", hoursAgo: 49)], now: now)
    // Neither is dropped — both bubbles are in the transcript — but the old one has stopped
    // being sent by itself and says so.
    #expect(pruned.map(\.id) == ["fresh", "stale"])
    #expect(pruned.map(\.status) == [.queued, .failed])
    // A message exactly at the edge is still one to send.
    #expect(Outbox.pruned([item("edge", hoursAgo: 48)], now: now).map(\.status) == [.queued])

    // Sixty queued messages are the newest fifty: a queue is not an archive.
    let many = (0..<60).map { item("m\($0)", hoursAgo: Double(60 - $0)) }
    let capped = Outbox.pruned(many, now: now)
    #expect(capped.count == Outbox.capacity)
    #expect(capped.first?.id == "m10")
    #expect(capped.last?.id == "m59")
}
