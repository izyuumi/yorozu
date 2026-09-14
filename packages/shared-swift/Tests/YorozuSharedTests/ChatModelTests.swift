import Foundation
import Testing

@testable import YorozuShared

/// A transport with no socket behind it: a test yields updates as if the runtime had sent them,
/// and reads back what the model emitted. Updates yielded before ``connect`` are held, so a test
/// does not have to race the model's own connecting task.
private actor FakeTransport: ChatTransport {
    private var updates: AsyncStream<TransportUpdate>.Continuation?
    private var held: [TransportUpdate] = []
    private(set) var sent: [YorozuEvent] = []

    func connect() -> AsyncStream<TransportUpdate> {
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        updates = continuation
        for update in held { continuation.yield(update) }
        held = []
        return stream
    }

    func send(_ event: YorozuEvent) async throws {
        sent.append(event)
    }

    func close() {
        updates?.finish()
        updates = nil
    }

    func yield(_ update: TransportUpdate) {
        if let updates { updates.yield(update) } else { held.append(update) }
    }
}

private func event(_ id: String, _ payload: YorozuEvent.Payload, thread: String = "home") -> YorozuEvent {
    YorozuEvent(id: id, threadId: thread, ts: 1, agentId: "main", payload: payload)
}

/// The model applies updates from a task of its own, so a test waits for the effect rather than
/// assuming it has already happened.
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// The model emits from a task of its own onto the transport's actor, so a test waits for the
/// sends to arrive rather than assuming that task has already run.
private func sent(by transport: FakeTransport, atLeast count: Int) async -> [YorozuEvent] {
    for _ in 0..<300 {
        let sent = await transport.sent
        if sent.count >= count { return sent }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await transport.sent
}

/// A model with a live link behind it: paired and the Mac awake. Anything less and a send goes
/// to the outbox instead of to the transport, which is what ``OutboxTests`` is about.
@MainActor
private func connected(_ transport: FakeTransport, device: String = "phone") async -> ChatModel {
    let model = ChatModel(transport: transport, device: device)
    await transport.yield(.state(.paired))
    await transport.yield(.ownerOnline(true))
    model.start()
    _ = await eventually { model.canDeliver }
    return model
}

@MainActor
@Test func reactingIsOptimisticAndTappingAgainRemovesIt() async {
    let transport = FakeTransport()
    let model = await connected(transport)

    model.react(to: "m1", with: "👍", in: "home")
    #expect(model.reactions(to: "m1", in: "home") == [MessageReaction(emoji: "👍", count: 1, selected: true)])
    model.react(to: "m1", with: "👍", in: "home")
    #expect(model.reactions(to: "m1", in: "home").isEmpty)

    let emitted = await sent(by: transport, atLeast: 3).filter { if case .reaction = $0.payload { true } else { false } }
    #expect(emitted.count == 2)
    if case .reaction(let last) = emitted.last?.payload { #expect(last.remove == true) }
}

@MainActor
@Test func theModelAppliesWhatTheTransportYieldsWhateverTransportItIs() async throws {
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, device: "mac")
    var paired = false
    model.onPaired = { paired = true }

    await transport.yield(.state(.paired))
    await transport.yield(.ownerOnline(true))
    await transport.yield(
        .event(
            event(
                "l1",
                .threadList(
                    ThreadListData(threads: [
                        ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1),
                        ThreadSummary(id: "t2", title: "Groceries", archived: false, lastActivity: 2),
                        ThreadSummary(id: "t3", title: "Gone", archived: true, lastActivity: 3),
                    ])
                )
            )
        )
    )
    // A reply streams as repeated events under one id, each carrying the whole text so far.
    await transport.yield(.event(event("r1", .message(MessageData(role: .agent, text: "po")))))
    await transport.yield(.event(event("r1", .message(MessageData(role: .agent, text: "pong")))))
    model.start()

    #expect(await eventually { model.state == .paired && !model.threads.isEmpty })
    #expect(model.ownerOnline)
    #expect(paired)
    // Archived threads are kept now — the phone's list draws them in a section of their own —
    // so what leaves them out is the ordering the lists ask for rather than the model.
    #expect(model.threads.map(\.title) == ["Home", "Groceries", "Gone"])
    #expect(visibleThreads(model.threads).map(\.title) == ["Groceries", "Home"])
    #expect(ThreadGroups(model.threads).archived.map(\.title) == ["Gone"])

    // The dot is the runtime's answer now rather than a guess from what this device happened
    // to witness, so the reply above raises nothing on its own.
    #expect(model.unreadCount == 0)

    #expect(await eventually { model.events["home"]?.count == 1 })
    let last = try #require(model.events["home"]?.last)
    guard case .message(let data) = last.payload else {
        Issue.record("not a message")
        return
    }
    #expect(data.text == "pong")
}

@MainActor
@Test func rapidStreamingDeltasAreCoalescedBeforeTheyInvalidateTheChat() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    var rendered = 0
    model.onEvent = { event in
        if case .message(let data) = event.payload, data.role == .agent { rendered += 1 }
    }

    for index in 0..<120 {
        await transport.yield(.event(event(
            "stream",
            .message(MessageData(role: .agent, text: String(repeating: "word ", count: index + 1)))
        )))
    }

    #expect(await eventually {
        guard case .message(let data) = model.events["home"]?.last?.payload else { return false }
        return data.text == String(repeating: "word ", count: 120)
    })
    #expect(rendered <= 3)

    await transport.yield(.event(event(
        "stream",
        .message(MessageData(role: .agent, text: "finished", done: true))
    )))
    #expect(await eventually {
        guard case .message(let data) = model.events["home"]?.last?.payload else { return false }
        return data.text == "finished" && data.done == true
    })
    try? await Task.sleep(for: .milliseconds(80))
    guard case .message(let final) = model.events["home"]?.last?.payload else {
        Issue.record("missing final streamed message")
        return
    }
    #expect(final.text == "finished")
}

@MainActor
@Test func pacedStreamingUpdatesOftenEnoughToLookSmooth() async throws {
    for (historyCount, chunkWidth) in [(0, 1), (50, 32), (500, 256)] {
        let transport = FakeTransport()
        let model = await connected(transport)
        for index in 0..<historyCount {
            await transport.yield(.event(event(
                "paced-history-\(index)",
                .message(MessageData(role: .user, text: "history \(index)", done: true))
            )))
        }
        #expect(await eventually { (model.events["home"]?.count ?? 0) == historyCount })

        var rendered = 0
        model.onEvent = { event in
            if event.id == "paced-stream" { rendered += 1 }
        }
        let unit = String(repeating: "x", count: chunkWidth)
        for index in 0..<24 {
            await transport.yield(.event(event(
                "paced-stream",
                .message(MessageData(role: .agent, text: String(repeating: unit, count: index + 1)))
            )))
            try await Task.sleep(for: .milliseconds(8))
        }

        #expect(await eventually {
            guard case .message(let data) = model.events["home"]?.last?.payload else { return false }
            return data.text.count == 24 * chunkWidth
        })
        // 50 ms batching visibly updates at only 20 Hz. One display-frame slice keeps a streamed
        // reply fluid without returning to one whole-tree invalidation per provider token.
        #expect(rendered >= 8)
        #expect(rendered <= 16)
    }
}

@MainActor
@Test func streamingCoalescingScalesAcrossMessageCountsAndLengths() async throws {
    for (historyCount, chunks, chunkWidth) in [
        (0, 12, 1),
        (10, 30, 8),
        (20, 60, 16),
        (200, 120, 64),
        (1_000, 240, 128),
    ] {
        let transport = FakeTransport()
        let model = await connected(transport)

        for index in 0..<historyCount {
            await transport.yield(.event(event(
                "history-\(index)",
                .message(MessageData(role: index.isMultiple(of: 2) ? .user : .agent, text: "history \(index)", done: true))
            )))
        }
        #expect(await eventually { (model.events["home"]?.count ?? 0) == historyCount })

        var rendered = 0
        model.onEvent = { event in
            if event.id == "matrix-stream" { rendered += 1 }
        }
        let unit = String(repeating: "x", count: chunkWidth)
        for index in 0..<chunks {
            await transport.yield(.event(event(
                "matrix-stream",
                .message(MessageData(role: .agent, text: String(repeating: unit, count: index + 1)))
            )))
        }

        let finalCount = chunks * chunkWidth
        #expect(await eventually {
            guard case .message(let data) = model.events["home"]?.last?.payload else { return false }
            return data.text.count == finalCount
        })
        #expect(rendered <= 3)
    }
}

@MainActor
@Test func anEventAfterStreamedTextKeepsItsWireOrder() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)

    await transport.yield(.event(event(
        "stream",
        .message(MessageData(role: .agent, text: "I checked"))
    )))
    await transport.yield(.event(event(
        "call",
        .toolCall(ToolCallData(callId: "call", name: "echo", args: [:]))
    )))

    #expect(await eventually { model.events["home"]?.count == 2 })
    #expect(model.events["home"]?.map(\.id) == ["stream", "call"])
}

/// The dot comes from the runtime's two timestamps and nothing else. In particular a reply that
/// arrived while this device was suspended, and was read on the other one, is not unread here —
/// which is what the per-device set got wrong.
@MainActor
@Test func aThreadIsUnreadOnlyWhenTheAgentHasSpokenSinceAnyoneReadIt() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    await transport.yield(
        .event(
            event(
                "l1",
                .threadList(
                    ThreadListData(threads: [
                        ThreadSummary(
                            id: "unread", title: "Unread", archived: false, lastActivity: 3,
                            lastReadAt: 10, lastAgentAt: 20
                        ),
                        ThreadSummary(
                            id: "read", title: "Read", archived: false, lastActivity: 2,
                            lastReadAt: 30, lastAgentAt: 20
                        ),
                        // Nothing has ever been said here, so it is not unread since the epoch.
                        ThreadSummary(id: "quiet", title: "Quiet", archived: false, lastActivity: 1),
                    ])
                )
            )
        )
    )
    #expect(await eventually { model.threads.count == 3 })
    #expect(model.threads.filter(\.isUnread).map(\.id) == ["unread"])
    #expect(model.unreadCount == 1)

    // A `sync_delta` carrying a reply older than that thread's mark — read on the other device
    // while this one was asleep — draws no dot.
    await transport.yield(
        .event(
            YorozuEvent(
                id: "r1", threadId: "read", ts: 20, agentId: "main",
                payload: .message(MessageData(role: .agent, text: "pong", done: true))
            )
        )
    )
    #expect(await eventually { model.events["read"]?.count == 1 })
    #expect(model.unreadCount == 1)
    #expect(model.threads.first { $0.id == "read" }?.isUnread == false)

    model.markAllRead()
    #expect(model.unreadCount == 0)
    let reads = await sent(by: transport, atLeast: 2).filter { $0.payload.kind == .threadRead }
    #expect(reads.map(\.threadId) == ["unread"])
}

/// "Genuinely reading" is both halves at once: the thread is on screen *and* the app is in
/// front. An app left open on a thread while it is backgrounded reports nothing — which is
/// exactly what used to mark replies read with nobody looking.
@MainActor
@Test func onlyAThreadOnScreenInAForegroundAppIsReportedRead() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    await transport.yield(
        .event(
            event(
                "l1",
                .threadList(
                    ThreadListData(threads: [
                        ThreadSummary(
                            id: "home", title: "Home", archived: false, lastActivity: 1,
                            lastReadAt: 1, lastAgentAt: 2
                        )
                    ])
                )
            )
        )
    )
    #expect(await eventually { !model.threads.isEmpty })
    #expect(model.unreadCount == 1)

    // Open, but the app is in the background: not reading, and nothing goes out.
    model.openThread = "home"
    #expect(!model.isReading("home"))
    let quiet = await transport.sent
    #expect(!quiet.contains { $0.payload.kind == .threadRead })

    // Brought to the front with it still open: now it is being read, and the runtime is told.
    model.foreground = true
    #expect(model.isReading("home"))
    #expect(!model.isReading("somewhere-else"))
    var reported: YorozuEvent?
    for _ in 0..<300 {
        reported = await transport.sent.last { $0.payload.kind == .threadRead }
        if reported != nil { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(try #require(reported).threadId == "home")
    // And the dot goes here and now rather than a round trip later.
    #expect(model.unreadCount == 0)
}

@MainActor
@Test func whatTheUserTypesReachesTheTransportTaggedWithThisDevice() async throws {
    let transport = FakeTransport()
    let model = await connected(transport, device: "mac")

    let thread = ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1)
    model.drafts[thread.id] = "  hi  "
    model.send(in: thread)
    // The draft is spent, and the message is in the thread before the runtime has said anything.
    #expect(model.drafts[thread.id] == "")
    #expect(model.events["home"]?.count == 1)

    model.answer("a1", in: "home", .always)
    #expect(model.answered.contains("a1"))

    var tries = 0
    while await transport.sent.count < 3, tries < 300 {
        try? await Task.sleep(for: .milliseconds(10))
        tries += 1
    }
    let sent = await transport.sent
    // Pairing asks for everything this device has not seen, and the typed message and the answer
    // follow it. Each goes out in a task of its own, so which lands first is not fixed — every
    // one of them carries its own ids, and the runtime matches on those rather than on order.
    #expect(Set(sent.map(\.payload.kind)) == [.syncRequest, .message, .approvalAnswer])
    #expect(sent.allSatisfy { $0.agentId == "mac" })
    let messages = sent.compactMap { event -> MessageData? in
        guard case .message(let data) = event.payload else { return nil }
        return data
    }
    guard let typed = messages.first else {
        Issue.record("no message reached the transport")
        return
    }
    #expect(typed.text == "hi")
    #expect(typed.role == .user)
}

@MainActor
@Test func aDraftThreadIsNowhereButHereUntilItsFirstMessage() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)

    // It is in the list, at the top, and the runtime has heard nothing about it.
    let draft = model.newDraft()
    #expect(model.threads.map(\.id) == [draft.id])
    #expect(draft.displayTitle == "New chat")
    #expect(await transport.sent.allSatisfy { $0.payload.kind != .threadCreate })

    // Backing out without sending leaves nothing behind.
    model.discardDraft(draft.id)
    #expect(model.threads.isEmpty)

    // Sending in one creates it, under the id it was typed in, and the message follows.
    let second = model.newDraft()
    model.send("hi", in: second.id)
    #expect(model.draft == nil)
    #expect(model.threads.map(\.id) == [second.id])
    var tries = 0
    while await transport.sent.count < 2, tries < 300 {
        try? await Task.sleep(for: .milliseconds(10))
        tries += 1
    }
    let sent = await transport.sent
    #expect(sent.filter { $0.payload.kind == .threadCreate }.map(\.threadId) == [second.id])
    #expect(sent.filter { $0.payload.kind == .message }.map(\.threadId) == [second.id])
    // And discarding it now is a no-op: it is a real thread, not a draft, any more.
    model.discardDraft(second.id)
    #expect(model.threads.map(\.id) == [second.id])
}

@Test func theThreadToOpenIsTheNewestOneWhileItIsStillWarm() {
    let now = Date(timeIntervalSince1970: 100_000)
    func thread(_ id: String, _ minutesAgo: Double, archived: Bool = false) -> ThreadSummary {
        ThreadSummary(
            id: id,
            title: id,
            archived: archived,
            lastActivity: (now.timeIntervalSince1970 - minutesAgo * 60) * 1000
        )
    }

    // Nothing to go back to: the app starts a fresh draft instead.
    #expect(threadToOpen([], now: now) == nil)
    // Newest wins, whatever order the list arrived in.
    #expect(threadToOpen([thread("old", 90), thread("new", 10)], now: now) == "new")
    #expect(threadToOpen([thread("new", 10), thread("old", 90)], now: now) == "new")
    // Newest still counts when it is inside the window, and nothing does once it is outside.
    #expect(threadToOpen([thread("edge", 119)], now: now) == "edge")
    #expect(threadToOpen([thread("cold", 121)], now: now) == nil)
    // An archived thread is not somewhere to be opened, however recent.
    #expect(threadToOpen([thread("gone", 1, archived: true), thread("warm", 30)], now: now) == "warm")
}

private func summary(
    _ id: String,
    minutesAgo: Double,
    archived: Bool = false,
    pinned: Bool = false,
    lastMessage: String? = nil
) -> ThreadSummary {
    ThreadSummary(
        id: id,
        title: id,
        archived: archived,
        lastActivity: (100_000 - minutesAgo * 60) * 1000,
        lastMessage: lastMessage,
        pinned: pinned
    )
}

@Test func theListPartitionsIntoPinnedRecentAndArchived() {
    let groups = ThreadGroups([
        summary("recent-old", minutesAgo: 90),
        summary("pinned-old", minutesAgo: 200, pinned: true),
        summary("recent-new", minutesAgo: 5),
        summary("pinned-new", minutesAgo: 10, pinned: true),
        summary("filed", minutesAgo: 1, archived: true),
        // Archived wins over pinned: a thread that was put away is put away.
        summary("filed-pin", minutesAgo: 2, archived: true, pinned: true),
    ])

    #expect(groups.pinned.map(\.id) == ["pinned-new", "pinned-old"])
    #expect(groups.recent.map(\.id) == ["recent-new", "recent-old"])
    #expect(groups.archived.map(\.id) == ["filed", "filed-pin"])
    #expect(!groups.isEmpty)
    #expect(ThreadGroups([]).isEmpty)
}

@Test func searchLooksAtTheTitleThePreviewAndTheThreadItself() {
    let thread = summary("t1", minutesAgo: 1, lastMessage: "and eggs")

    // An empty or blank query is not a filter: the unsearched list is the whole list.
    #expect(threadMatches(thread, query: ""))
    #expect(threadMatches(thread, query: "   "))
    // Title and preview, either case.
    #expect(threadMatches(thread, query: "T1"))
    #expect(threadMatches(thread, query: "EGGS"))
    // And what the device has cached of the thread, which is how a word said once is found.
    #expect(threadMatches(thread, query: "sourdough", body: "we settled on sourdough"))
    #expect(!threadMatches(thread, query: "sourdough"))

    // An untitled thread is searchable by the placeholder it is actually drawn with.
    let untitled = ThreadSummary(id: "t2", title: "", archived: false, lastActivity: 0)
    #expect(threadMatches(untitled, query: "new chat"))
}

@MainActor
@Test func aTurnIsInFlightFromTheSendUntilTheReplySaysItIsDone() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)

    #expect(!model.generating.contains("home"))
    model.send("hi", in: "home")
    #expect(model.generating.contains("home"))

    // Deltas arrive under one id and carry no `done`: the turn is not over yet.
    await transport.yield(.event(event("r1", .message(MessageData(role: .agent, text: "he")))))
    #expect(await eventually { model.events["home"]?.count == 2 })
    #expect(model.generating.contains("home"))

    await transport.yield(.event(event("r1", .message(MessageData(role: .agent, text: "hello", done: true)))))
    #expect(await eventually { !model.generating.contains("home") })
    // Same id, so the reply is still one bubble however many deltas drew it.
    #expect(model.events["home"]?.count == 2)
}

@MainActor
@Test func stoppingATurnReleasesTheComposerRatherThanWaitingForAReplyThatIsNotComing() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)

    model.send("hi", in: "home")
    model.interrupt(in: "home")
    #expect(!model.generating.contains("home"))
    #expect(await sent(by: transport, atLeast: 2).contains { $0.payload.kind == .interrupt })
}

@MainActor
@Test func aDelegatedAgentsLastMessageEndsItsCardAndNotTheWholeTurn() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    model.send("hi", in: "home")

    var delegated = event("d1", .message(MessageData(role: .agent, text: "booked", done: true)))
    delegated.agentId = "calendar"
    delegated.parentAgentId = "main"
    await transport.yield(.event(delegated))

    #expect(await eventually { model.events["home"]?.count == 2 })
    // The specialist finished; the main agent is still working, so the composer stays Stop.
    #expect(model.generating.contains("home"))
}

@MainActor
@Test func theComposerSendsItsAttachmentAndEmptiesItself() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    let thread = ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1)

    // A photo with no words is still a message worth sending.
    model.attachments["home"] = [MessageAttachment(name: "p.png", mime: "image/png", data: "aGk=")]
    model.send(in: thread)

    #expect(model.attachments["home"] == nil)
    #expect(model.drafts["home"] == "")
    // Two: pairing's own `sync_request` went first, and the message is behind it.
    let message = try #require(
        await sent(by: transport, atLeast: 2).first { $0.payload.kind == .message }
    )
    guard case .message(let data) = message.payload else {
        Issue.record("not a message")
        return
    }
    #expect(data.attachment?.name == "p.png")
    #expect(data.text == "")

    // And an empty composer sends nothing at all.
    let before = await transport.sent.count
    model.send(in: thread)
    #expect(await transport.sent.count == before)
}

@MainActor
@Test func deletingAMessageForgetsItHereAndLeavesTheThreadAlone() async throws {
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, device: "phone")
    model.start()

    await transport.yield(.event(event("e1", .message(MessageData(role: .user, text: "one")))))
    await transport.yield(.event(event("e2", .message(MessageData(role: .agent, text: "two")))))
    #expect(await eventually { model.events["home"]?.count == 2 })

    model.delete("e1", in: "home")
    #expect(model.events["home"]?.map(\.id) == ["e2"])
    // Local only: nothing about it goes out on the wire.
    #expect(await transport.sent.isEmpty)
    // Deleting something that is not there is not an error.
    model.delete("gone", in: "home")
    model.delete("e2", in: "nosuchthread")
    #expect(model.events["home"]?.map(\.id) == ["e2"])
}

@MainActor
@Test func theModelsOnOfferComeFromTheRuntimeAndPickingOneSetsTheThread() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    let options = [
        ModelOption(id: "claude/claude-opus-5", label: "claude-opus-5", providerLabel: "Claude"),
        ModelOption(id: "codex/gpt-5.6", label: "gpt-5.6", providerLabel: "Codex"),
    ]
    let thread = ThreadSummary(id: "t1", title: "Kyoto", archived: false, lastActivity: 1)

    // Until the runtime says otherwise there is nothing to pick from, and so only Default.
    #expect(model.models.isEmpty)
    await transport.yield(.event(event("m1", .modelList(ModelListData(models: options)))))
    await transport.yield(.event(event("l1", .threadList(ThreadListData(threads: [thread])))))
    #expect(await eventually { model.models == options && model.threads == [thread] })
    // A list is not a thread's history: it must not land in one as a bubble.
    #expect(model.events[""] == nil)

    model.setModel(model.threads[0], "codex/gpt-5.6")
    // Applied here and now, so the caption and the tick move under the tap rather than a round
    // trip later, and sent for the runtime to persist.
    #expect(model.threads[0].model == "codex/gpt-5.6")
    // Pairing already sent a `sync_request`, so it is the next one that is the pick.
    let picked = await sent(by: transport, atLeast: 2)
    #expect(picked.last?.threadId == "t1")
    #expect(picked.last?.payload == .threadSetModel(ThreadSetModelData(model: "codex/gpt-5.6")))

    model.setModel(model.threads[0], nil)
    #expect(model.threads[0].model == nil)
    let cleared = await sent(by: transport, atLeast: 3)
    #expect(cleared.last?.payload == .threadSetModel(ThreadSetModelData(model: nil)))
}

/// A model picked in a chat nothing has been sent in yet has no thread on the Mac to be set on.
/// It waits on the draft and goes out with the message that creates the thread, ahead of it, so
/// the very first turn already runs on what was picked.
@MainActor
@Test func aModelPickedInADraftGoesOutWithTheMessageThatCreatesTheThread() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    let draft = model.newDraft()

    // Pairing's own `sync_request` is all that has gone out so far.
    let before = await transport.sent.count

    model.setModel(draft, "claude/claude-opus-5")
    #expect(model.draft?.model == "claude/claude-opus-5")
    // Still nothing on the wire: there is no thread there to set anything on.
    #expect(await transport.sent.count == before)

    model.send("hi", in: draft.id)
    let created = await sent(by: transport, atLeast: before + 3)
    #expect(created.dropFirst(before).map(\.payload.kind) == [.threadCreate, .threadSetModel, .message])
    #expect(created.dropFirst(before).allSatisfy { $0.threadId == draft.id })
}

@MainActor
@Test func effortIsOptimisticAndAChoiceOnADraftPrecedesItsFirstMessage() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    let thread = ThreadSummary(id: "t1", title: "Kyoto", archived: false, lastActivity: 1)
    await transport.yield(.event(event("l1", .threadList(ThreadListData(threads: [thread])))))
    #expect(await eventually { model.threads == [thread] })

    model.setEffort(model.threads[0], .high)
    #expect(model.threads[0].effort == .high)
    let picked = await sent(by: transport, atLeast: 2)
    #expect(picked.last?.payload == .threadSetEffort(ThreadSetEffortData(effort: .high)))

    let draft = model.newDraft()
    let before = await transport.sent.count
    model.setEffort(draft, .low)
    #expect(model.draft?.effort == .low)
    #expect(await transport.sent.count == before)
    model.send("hi", in: draft.id)
    let created = await sent(by: transport, atLeast: before + 3)
    #expect(created.dropFirst(before).map(\.payload.kind) == [.threadCreate, .threadSetEffort, .message])
}

@MainActor
@Test func approvalSettingsAreRequestedAndUpdatedAcrossTheWire() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    let before = await transport.sent.count

    model.requestApprovalSettings()
    var events = await sent(by: transport, atLeast: before + 1)
    #expect(events.last?.payload == .approvalSettings(ApprovalSettingsData()))
    await transport.yield(.event(event("s1", .approvalSettings(ApprovalSettingsData(yolo: true)))))
    #expect(await eventually { model.yoloMode })

    model.setYoloMode(false)
    events = await sent(by: transport, atLeast: before + 2)
    #expect(events.last?.payload == .approvalSettings(ApprovalSettingsData(yolo: false)))
    #expect(model.yoloMode == false)
}
