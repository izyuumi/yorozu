import CryptoKit
import Foundation
import Testing

@testable import YorozuShared

/// A transport with no socket behind it: a test yields updates as if the runtime had sent them,
/// and reads back what the model emitted. Updates yielded before ``connect`` are held, so a test
/// does not have to race the model's own connecting task.
private actor FakeTransport: ChatTransport {
    private let autoReceipt: Bool
    private var updates: AsyncStream<TransportUpdate>.Continuation?
    private var held: [TransportUpdate] = []
    private(set) var sent: [YorozuEvent] = []
    private var blockAttachmentChunks = false
    private var heldChunks: [CheckedContinuation<Void, Never>] = []

    init(autoReceipt: Bool = false) { self.autoReceipt = autoReceipt }

    func connect() -> AsyncStream<TransportUpdate> {
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        updates = continuation
        for update in held { continuation.yield(update) }
        held = []
        return stream
    }

    func send(_ event: YorozuEvent) async throws {
        sent.append(event)
        if blockAttachmentChunks && event.payload.kind == .attachmentChunk {
            await withCheckedContinuation { heldChunks.append($0) }
        }
        if autoReceipt {
            yield(.event(YorozuEvent(id: "receipt-\(event.id)", threadId: "", ts: 1, agentId: "main",
                                     payload: .receipt(ReceiptData(eventId: event.id)))))
        }
    }

    func close() {
        for release in heldChunks { release.resume() }
        heldChunks.removeAll()
        updates?.finish()
        updates = nil
    }

    func yield(_ update: TransportUpdate) {
        if let updates { updates.yield(update) } else { held.append(update) }
    }

    func holdChunks() { blockAttachmentChunks = true }
    func releaseChunks() {
        for release in heldChunks { release.resume() }
        heldChunks.removeAll()
    }

}

/// Holds every send open until released, exposing whether the model starts a later wire send
/// before the earlier one has finished.
private actor BlockingTransport: ChatTransport {
    private(set) var started: [YorozuEvent.Kind] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func connect() -> AsyncStream<TransportUpdate> { AsyncStream { _ in } }
    func send(_ event: YorozuEvent) async throws {
        started.append(event.payload.kind)
        await withCheckedContinuation { releases.append($0) }
    }
    func close() {}
    func releaseFirst() { releases.removeFirst().resume() }
}

private func event(_ id: String, _ payload: YorozuEvent.Payload, thread: String = "home") -> YorozuEvent {
    YorozuEvent(id: id, threadId: thread, ts: 1, agentId: "main", payload: payload)
}

/// The model applies updates from a task of its own, so a test waits for the effect rather than
/// assuming it has already happened.
@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
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

private func sent(by transport: FakeTransport, payload: YorozuEvent.Payload, in threadID: String) async -> YorozuEvent? {
    for _ in 0..<300 {
        if let event = await transport.sent.first(where: { $0.threadId == threadID && $0.payload == payload }) { return event }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await transport.sent.first { $0.threadId == threadID && $0.payload == payload }
}

private func started(by transport: BlockingTransport, atLeast count: Int) async -> [YorozuEvent.Kind] {
    for _ in 0..<300 {
        let started = await transport.started
        if started.count >= count { return started }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await transport.started
}

@MainActor
@Test func updateRestartPreservesDraftsAttachmentsSelectionAndPendingMessages() async throws {
    let cache = ThreadCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString), key: SymmetricKey(size: .bits256))
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, cache: cache)
    model.start()
    await transport.yield(.ownerOnline(true))
    await transport.yield(.state(.paired))
    #expect(await eventually { model.canDeliver })
    await transport.yield(.event(event("update", .updateStatus(UpdateStatusData(phase: .installing, updateId: "u1")))))
    #expect(await eventually { !model.canDeliver })
    let queuedThread = model.newDraft()
    model.send("during restart", in: queuedThread.id)
    let pending = model.outbox.map(\.id)
    #expect(pending.count == 2)
    let draft = model.newDraft(agent: .codex, cwd: "/project")
    model.drafts[draft.id] = "unfinished draft"
    model.attachments[draft.id] = [MessageAttachment(name: "p.png", mime: "image/png", data: "aGk=")]
    model.openThread = draft.id
    try model.saveForRestart()
    let restoredTransport = FakeTransport(autoReceipt: true)
    let restored = ChatModel(transport: restoredTransport, cache: cache)
    #expect(restored.drafts[draft.id] == "unfinished draft")
    #expect(restored.attachments[draft.id] == model.attachments[draft.id])
    #expect(restored.openThread == draft.id)
    #expect(restored.draft == draft)
    #expect(restored.outbox.map(\.id) == pending)
    #expect(restored.events[queuedThread.id]?.count == 1)
    restored.start()
    await restoredTransport.yield(.ownerOnline(true))
    await restoredTransport.yield(.state(.paired))
    #expect(await eventually { restored.canDeliver })
    var commands: [YorozuEvent] = []
    for _ in 0..<100 {
        commands = await restoredTransport.sent.filter { pending.contains($0.id) }
        if commands.count == 2 { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(commands.map(\.id) == pending)
    for id in pending { await restoredTransport.yield(.event(event("receipt-" + id, .receipt(ReceiptData(eventId: id))))) }
    #expect(await eventually { restored.outbox.isEmpty })
    model.close(); restored.close()
}

@MainActor
@Test func backgroundFlushPersistsComposerBeforeItsDebounce() async {
    let cache = ThreadCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString), key: SymmetricKey(size: .bits256))
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let model = ChatModel(transport: FakeTransport(), cache: cache)
    let draft = model.newDraft()
    model.drafts[draft.id] = "unsent"
    model.attachments[draft.id] = [MessageAttachment(name: "photo.png", mime: "image/png", data: "aGk=")]
    model.openThread = draft.id
    let position = ThreadCache.ReadingPosition(rowID: "older-reply", distanceFromTop: -18)
    model.rememberReadingPosition(position, in: draft.id)

    await model.flushCache()

    let resumed = ChatModel(transport: FakeTransport(), cache: cache)
    #expect(resumed.drafts[draft.id] == "unsent")
    #expect(resumed.attachments[draft.id] == model.attachments[draft.id])
    #expect(resumed.openThread == draft.id)
    #expect(resumed.readingPosition(in: draft.id) == position)
}

@MainActor
@Test func failedRestartSnapshotIsReportedInsteadOfLosingDrafts() throws {
    let file = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let cache = ThreadCache(directory: file, key: SymmetricKey(size: .bits256))
    let model = ChatModel(transport: FakeTransport(), cache: cache)
    #expect(throws: (any Error).self) { try model.saveForRestart() }
}

@MainActor
@Test func returningHostClearsInstallingWithoutReconnectingPhoneAndReplaysOutbox() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    await transport.yield(.event(event("installing", .updateStatus(UpdateStatusData(phase: .installing, updateId: "u1")))))
    #expect(await eventually { !model.canDeliver })
    await transport.yield(.ownerOnline(false))
    #expect(await eventually { !model.ownerOnline })
    model.send("while updating", in: "home")
    let messageId = model.outbox.first!.id
    let before = await sent(by: transport, atLeast: pairingSends).count
    await transport.yield(.ownerOnline(true))
    #expect(await eventually {
        await transport.sent.dropFirst(before).contains {
            $0.payload == .updateControl(UpdateControlData(action: .status))
        }
    })
    let requests = await transport.sent
    #expect(!requests.contains { $0.id == messageId })
    await transport.yield(.event(event("restarted", .updateStatus(UpdateStatusData(phase: .none)))))
    #expect(await eventually { model.canDeliver })
    #expect(await eventually { await transport.sent.contains { $0.id == messageId } })
    let delivered = await transport.sent
    #expect(delivered.filter { $0.id == messageId }.count == 1)
    model.close()
}

@MainActor
@Test func taskRecoveryRemainsDurableDuringInstallation() async throws {
    let cache = ThreadCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString), key: SymmetricKey(size: .bits256))
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, cache: cache)
    model.start()
    await transport.yield(.state(.paired))
    await transport.yield(.ownerOnline(true))
    #expect(await eventually { model.canDeliver })
    await transport.yield(.event(event("install", .updateStatus(UpdateStatusData(phase: .installing)))))
    #expect(await eventually { !model.canDeliver })
    var thread = ThreadSummary(id: "work", title: "Work", archived: false, lastActivity: 1)
    thread.interruptedTurnId = "turn"
    model.recover(thread, action: .continue)
    try model.saveForRestart()
    let restored = ChatModel(transport: FakeTransport(), cache: cache)
    #expect(restored.outbox.map(\.event.payload.kind) == [.threadRecover])
    #expect(restored.outbox.map(\.id) == model.outbox.map(\.id))
    model.close()
}

@MainActor
@Test func connectionPresentationFreezesInBackgroundAndDelaysDisconnection() async throws {
    // Delays are long next to the short "not yet" checks, and the final change is polled for,
    // so a slow CI VM that oversleeps cannot flip either kind of expectation.
    let grace = Duration.milliseconds(300)
    let presentation = ConnectionPresentation(.connected)

    presentation.update(.reconnecting, active: false, grace: grace)
    try await Task.sleep(for: .milliseconds(400))
    #expect(presentation.state == .connected)

    presentation.update(.reconnecting, active: true, grace: grace)
    try await Task.sleep(for: .milliseconds(20))
    #expect(presentation.state == .connected)
    presentation.update(.connected, active: true, grace: grace)
    try await Task.sleep(for: .milliseconds(400))
    #expect(presentation.state == .connected)

    presentation.update(.offline, active: true, grace: grace)
    await settled(presentation, at: .offline)
    #expect(presentation.state == .offline)
}

@MainActor
@Test func connectionToastAppearsOncePerOutageAndDismisses() async throws {
    let toast = ConnectionToastPresentation(duration: .milliseconds(30))
    let link = ConnectionPresentation(.connected)
    link.onStateChange = { toast.declared($0) }

    link.update(.offline, active: true, since: .now - .seconds(6))
    #expect(toast.visible == .offline)
    for _ in 0..<20 where toast.visible != nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(toast.visible == nil)
    link.update(.reconnecting, active: true, since: .now - .seconds(6))
    #expect(toast.visible == nil)

    link.update(.connected, active: true)
    link.update(.offline, active: true, since: .now - .seconds(6))
    #expect(toast.visible == .offline)
    toast.dismiss()
    #expect(toast.visible == nil)
}

@MainActor
@Test func copiedConnectionDiagnosticsExcludeComposerContent() {
    let model = ChatModel(transport: FakeTransport())
    model.drafts["thread-secret"] = "private draft sentence"
    let text = ConnectionDiagnostics.snapshot(for: model)
    #expect(text.contains("Transport:"))
    #expect(!text.contains("private draft sentence"))
    #expect(!text.contains("thread-secret"))
}

/// The grace is anchored to when the link was lost: a change of *how* it is lost, part way
/// through, is declared at the original deadline rather than a fresh one.
@MainActor
@Test func connectionPresentationDoesNotRestartGraceWhenInterruptionChangesKind() async throws {
    let grace = Duration.milliseconds(1200)
    let presentation = ConnectionPresentation(.connected)

    presentation.update(.reconnecting, active: true, grace: grace)
    try await Task.sleep(for: .milliseconds(700))
    #expect(presentation.state == .connected)

    let changed = ContinuousClock.now
    presentation.update(.offline, active: true, grace: grace)
    await settled(presentation, at: .offline)
    #expect(presentation.state == .offline)
    // About 500ms is left of the original window; a restarted one takes at least 1200ms.
    #expect(ContinuousClock.now - changed < grace)
}

/// A view opened mid-outage counts from the host's moment, so one past the grace says so at
/// once rather than waiting out a grace of its own.
@MainActor
@Test func connectionPresentationHonoursAnEarlierAnchor() {
    let presentation = ConnectionPresentation(.connected)
    presentation.update(.offline, active: true, since: .now - .seconds(60))
    #expect(presentation.state == .offline)
}

@MainActor
@Test func interruptionAnchorFollowsTheLinkAndClearsOnSuspension() async throws {
    let transport = FakeTransport()
    let model = ChatModel(transport: transport)
    #expect(model.interruptedSince == nil)
    model.start()
    #expect(model.interruptedSince != nil)
    await transport.yield(.ownerOnline(true))
    await transport.yield(.state(.paired))
    #expect(await eventually { model.interruptedSince == nil })

    await transport.yield(.ownerOnline(false))
    #expect(await eventually { model.interruptedSince != nil })
    let lost = try #require(model.interruptedSince)
    // The loss changing kind is the same interruption.
    await transport.yield(.state(.closed))
    #expect(await eventually { model.state == .closed })
    #expect(model.interruptedSince == lost)

    // Hanging up for suspension is not an interruption; the next start is a fresh one.
    model.suspend()
    #expect(model.interruptedSince == nil)
    model.start()
    #expect(try #require(model.interruptedSince) > lost)
    model.close()
}

/// Short losses separated by genuine recovery each get their own window; they do not add up.
@MainActor
@Test func connectionPresentationDoesNotAccumulateSeparateInterruptions() async throws {
    let grace = Duration.milliseconds(1000)
    let presentation = ConnectionPresentation(.connected)

    for _ in 0..<3 {
        presentation.update(.reconnecting, active: true, grace: grace)
        try await Task.sleep(for: .milliseconds(400))
        presentation.update(.connected, active: true, grace: grace)
    }
    presentation.update(.reconnecting, active: true, grace: grace)
    try await Task.sleep(for: .milliseconds(400))
    #expect(presentation.state == .connected)
}

/// Backgrounding forgets the window; coming back starts a fresh one rather than declaring a
/// loss the timer counted down while nothing was running.
@MainActor
@Test func connectionPresentationRestartsGraceOnForeground() async throws {
    let grace = Duration.milliseconds(1000)
    let presentation = ConnectionPresentation(.connected)

    // The old deadline expires while backgrounded, when no presentation timer is active.
    presentation.update(.reconnecting, active: true, since: .now - .milliseconds(600), grace: grace)
    presentation.update(.reconnecting, active: false, grace: grace)
    try await Task.sleep(for: .milliseconds(500))
    presentation.update(.reconnecting, active: true, grace: grace)
    // A stale anchor declares reconnecting synchronously; a fresh one starts a new grace.
    #expect(presentation.state == .connected)
    await settled(presentation, at: .reconnecting)
    #expect(presentation.state == .reconnecting)
}

@MainActor
private func settled(_ presentation: ConnectionPresentation, at state: ConnectionState) async {
    for _ in 0..<200 where presentation.state != state {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Test func wireSendsFinishInEmissionOrder() async {
    let transport = BlockingTransport()
    let model = ChatModel(transport: transport)

    model.requestSync()
    model.requestDevices()

    #expect(await started(by: transport, atLeast: 1) == [.syncRequest])
    await transport.releaseFirst()
    #expect(await started(by: transport, atLeast: 2) == [.syncRequest, .deviceList])
    await transport.releaseFirst()
}

/// What pairing itself puts on the wire before a test sends anything: pull is truth, so every
/// join asks for the thread list, a sync, the devices and the rules rather than trusting what
/// was last pushed. Tests that count sends start from here.
private let pairingSends = pairingKinds.count
private let pairingKinds: Set<YorozuEvent.Kind> = [.threadList, .syncRequest, .deviceList, .ruleList, .updateControl]

/// A model with a live link behind it: paired and the Mac awake. Anything less and a send goes
/// to the outbox instead of to the transport, which is what ``OutboxTests`` is about.
@MainActor
private func connected(_ transport: FakeTransport, device: String = "phone") async -> ChatModel {
    let model = ChatModel(transport: transport, device: device)
    await transport.yield(.state(.paired))
    await transport.yield(.ownerOnline(true))
    model.start()
    #expect(await eventually { model.canDeliver })
    // Becoming deliverable schedules these controls; it does not mean they finished sending.
    let requests = await sent(by: transport, atLeast: pairingSends)
    #expect(Set(requests.map(\.payload.kind)).isSuperset(of: pairingKinds))
    return model
}

@MainActor
@Test func deviceRequestAnnouncesReadableOSName() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    let requests = await sent(by: transport, atLeast: pairingSends)
    let name = requests.compactMap { event -> String? in
        guard case .deviceList(let data) = event.payload else { return nil }
        return data.name
    }.first
    #expect(name?.hasPrefix("macOS ") == true)
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
    defer { model.close() }
    var rendered = 0
    model.onEvent = { event in
        if case .message(let data) = event.payload, data.role == .agent { rendered += 1 }
    }

    // Feed the reducer synchronously: actor hops could turn a burst into paced input when
    // other tests occupy MainActor. The paced-stream test separately exercises real frames.
    for index in 0..<120 {
        model.applyEvent(event(
            "stream",
            .message(MessageData(role: .agent, text: String(repeating: "word ", count: index + 1)))
        ))
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
        let started = ContinuousClock.now
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
        // The ceiling is one render per 16 ms slice actually elapsed: a slow CI VM oversleeps
        // the 8 ms gaps, so fewer chunks share a slice there and a fixed 16 would be flaky.
        let slices = Int((ContinuousClock.now - started) / .milliseconds(16))
        #expect(rendered >= 8)
        #expect(rendered <= max(16, slices + 2))
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
        defer { model.close() }

        for index in 0..<historyCount {
            model.applyEvent(event(
                "history-\(index)",
                .message(MessageData(role: index.isMultiple(of: 2) ? .user : .agent, text: "history \(index)", done: true))
            ))
        }
        #expect((model.events["home"]?.count ?? 0) == historyCount)

        var rendered = 0
        model.onEvent = { event in
            if event.id == "matrix-stream" { rendered += 1 }
        }
        let unit = String(repeating: "x", count: chunkWidth)
        // Test the reducer's burst boundary without scheduler-inserted frame gaps. Transport
        // iteration and real frame cadence remain covered by the paced/wire-order tests.
        for index in 0..<chunks {
            model.applyEvent(event(
                "matrix-stream",
                .message(MessageData(role: .agent, text: String(repeating: unit, count: index + 1)))
            ))
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
    let reads = await sent(by: transport, atLeast: pairingSends + 1).filter { $0.payload.kind == .threadRead }
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
    #expect(model.isReading(threadRef: YorozuCrypto.threadRef("home")))
    #expect(!model.isReading(threadRef: YorozuCrypto.threadRef("somewhere-else")))
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
@Test func olderNotificationFindsItsThreadFromTheAuthenticatedEventAfterSync() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    let reply = event("older-host-reply", .message(MessageData(role: .agent, text: "Done", done: true)),
                      thread: "second-host-thread")
    let ref = YorozuCrypto.threadRef(reply.id)
    #expect(model.threadRef(containingEventRef: ref) == nil)
    await transport.yield(.event(reply))
    #expect(await eventually { model.threadRef(containingEventRef: ref) == YorozuCrypto.threadRef(reply.threadId) })
    #expect(model.threadRef(containingEventRef: YorozuCrypto.threadRef("unknown")) == nil)
}

/// Opening a thread updates read state optimistically. A thread-list response already in flight
/// must not resurrect its unread dot while the runtime is still applying that read event.
@MainActor
@Test func staleThreadListCannotUndoAnOptimisticRead() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    var lists = 0
    model.onThreads = { lists += 1 }
    let stale = ThreadSummary(
        id: "home", title: "Home", archived: false, lastActivity: 2,
        lastReadAt: 1, lastAgentAt: 2
    )
    await transport.yield(.event(event("l1", .threadList(ThreadListData(threads: [stale])))))
    #expect(await eventually { lists == 1 })
    #expect(model.unreadCount == 1)

    model.foreground = true
    model.openThread = "home"
    #expect(model.unreadCount == 0)

    await transport.yield(.event(event("l2", .threadList(ThreadListData(threads: [stale])))))
    #expect(await eventually { lists == 2 })
    #expect(model.unreadCount == 0)
}

@MainActor
@Test func whatTheUserTypesReachesTheTransportTaggedWithThisDevice() async throws {
    let transport = FakeTransport(autoReceipt: true)
    let model = await connected(transport, device: "mac")

    let thread = ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1)
    model.drafts[thread.id] = "  hi  "
    model.send(in: thread)
    // The draft is spent, and the message is in the thread before the runtime has said anything.
    #expect(model.drafts[thread.id] == "")
    #expect(model.events["home"]?.count == 1)

    model.answer("a1", in: "home", .always)
    #expect(model.approvalPending("a1"))
    #expect(!model.answered.contains("a1"))

    let sent = await sent(by: transport, atLeast: pairingSends + 2)
    // Pairing asks for everything this device has not seen, and the typed message and the answer
    // follow it. Each goes out in a task of its own, so which lands first is not fixed — every
    // one of them carries its own ids, and the runtime matches on those rather than on order.
    #expect(Set(sent.map(\.payload.kind)) == pairingKinds.union([.message, .approvalAnswer]))
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
    let answer = try #require(sent.first { $0.payload.kind == .approvalAnswer })
    await transport.yield(.event(event("approval-applied", .approvalStatus(ApprovalStatusData(
        requestId: answer.id, actionId: "a1", status: .applied)))))
    #expect(await eventually { model.answered.contains("a1") && !model.approvalPending("a1") })
}

@MainActor
@Test func aDraftThreadIsNowhereButHereUntilItsFirstMessage() async throws {
    let transport = FakeTransport(autoReceipt: true)
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
    let sent = await sent(by: transport, atLeast: pairingSends + 2)
    #expect(sent.filter { $0.payload.kind == .threadCreate }.map(\.threadId) == [second.id])
    #expect(sent.filter { $0.payload.kind == .message }.map(\.threadId) == [second.id])
    // And discarding it now is a no-op: it is a real thread, not a draft, any more.
    model.discardDraft(second.id)
    #expect(model.threads.map(\.id) == [second.id])
}

@MainActor
@Test func draftsWithInputSurviveNavigationNewSessionsAndSync() async throws {
    let transport = FakeTransport(autoReceipt: true)
    let model = await connected(transport)
    let first = model.newDraft(agent: .codex, cwd: "/tmp/project")
    model.drafts[first.id] = "  finish this later  "
    model.discardDraft(first.id)
    #expect(model.isDraft(first.id))

    let second = model.newDraft()
    model.drafts[second.id] = "another thought"
    #expect(model.threads.map(\.id) == [second.id, first.id])
    // Settings on an older draft stay local, including after a runtime refresh.
    model.setModel(first, "codex-model")
    model.setEffort(first, .low)
    model.foreground = true
    model.openThread = first.id
    await transport.yield(.event(event("refresh", .threadList(ThreadListData(threads: [])))))
    #expect(await eventually { model.listed })
    #expect(model.threads.map(\.id) == [second.id, first.id])
    #expect(model.drafts[first.id] == "  finish this later  ")
    #expect(await transport.sent.allSatisfy { $0.threadId != first.id })

    model.send(in: first)
    #expect(!model.isDraft(first.id))
    #expect(model.isDraft(second.id))
    #expect(model.drafts[first.id] == "")
    #expect(model.drafts[second.id] == "another thought")
    let sent = await sent(by: transport, atLeast: pairingSends + 4)
        .filter { $0.threadId == first.id }
    #expect(sent.map(\.payload.kind) == [.threadCreate, .threadSetModel, .threadSetEffort, .message])
    guard case .threadCreate(let creation) = sent.first?.payload else {
        Issue.record("draft was not created before sending")
        return
    }
    #expect(creation.agent == .codex)
    #expect(creation.cwd == "/tmp/project")
    #expect(model.threads.first { $0.id == first.id }?.model == "codex-model")
    #expect(model.threads.first { $0.id == first.id }?.effort == .low)
}

@MainActor
@Test func attachmentDraftsAreKeptUntilClearedOrExplicitlyArchived() async {
    let model = await connected(FakeTransport())
    let first = model.newDraft()
    let attachment = MessageAttachment(name: "p.png", mime: "image/png", data: "aGk=")
    model.attachments[first.id] = [attachment]
    model.discardDraft(first.id)
    let empty = model.newDraft()
    model.drafts[empty.id] = " \n "
    let newest = model.newDraft()
    #expect(model.threads.map(\.id) == [newest.id, first.id])
    #expect(model.drafts[empty.id] == nil)
    #expect(model.attachments[first.id] == [attachment])

    model.archive(first)
    #expect(!model.isDraft(first.id))
    #expect(model.attachments[first.id] == nil)
    model.drafts[newest.id] = "changed my mind"
    model.discardDraft(newest.id)
    #expect(model.isDraft(newest.id))
    model.drafts[newest.id] = ""
    model.discardDraft(newest.id)
    #expect(model.threads.isEmpty)
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

    // And by who answers it and where, so "claude" is a filter and "yorozu" finds the repo's.
    let coding = ThreadSummary(id: "cc", title: "Fix tests", archived: false, lastActivity: 0, agent: .claudeCode, cwd: "/Users/yumi/Projects/yorozu")
    #expect(coding.repoName == "yorozu")
    #expect(threadMatches(coding, query: "claude"))
    #expect(threadMatches(coding, query: "yorozu"))
    #expect(!threadMatches(coding, query: "codex"))
    #expect(threadMatches(thread, query: "yorozu"))
    #expect(!threadMatches(thread, query: "claude"))
}

@MainActor
@Test func aCodingDraftCarriesItsAgentAndFolderIntoTheThreadItCreates() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    let before = await sent(by: transport, atLeast: pairingSends).count

    // A Yorozu draft says nothing new on the wire, exactly as before there was anyone else.
    let plain = model.newDraft()
    #expect(plain.agent == nil && plain.cwd == nil)
    let coding = model.newDraft(agent: .claudeCode, cwd: "/Users/yumi/Projects/yorozu")
    #expect(coding.agent == .claudeCode)
    #expect(coding.repoName == "yorozu")
    #expect(model.threads.map(\.id) == [coding.id])

    model.send("fix the tests", in: coding.id)
    let sent = await sent(by: transport, atLeast: before + 2)
    guard case .threadCreate(let create) = sent[before].payload else {
        Issue.record("expected thread_create first, got \(sent[before].payload.kind)")
        return
    }
    #expect(create == ThreadCreateData(title: nil, agent: .claudeCode, cwd: "/Users/yumi/Projects/yorozu"))

    // The folder list rides in like the model list, and the picker reads it.
    await transport.yield(.event(event("p1", .projectList(ProjectListData(projects: [ProjectFolder(path: "/Users/yumi/Projects/yorozu", name: "yorozu", lastUsed: 1)])))))
    #expect(await eventually { model.projects.map(\.name) == ["yorozu"] })
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
@Test func syncRestoresWorkingTurnsAfterClientRelaunch() async {
    let transport = FakeTransport()
    let model = ChatModel(transport: transport)
    model.start()

    await transport.yield(
        .event(event("sync", .syncDelta(SyncDeltaData(events: [], workingThreadIds: ["home"]))))
    )
    #expect(await eventually { model.generating == Set(["home"]) })

    await transport.yield(
        .event(event("sync-2", .syncDelta(SyncDeltaData(events: [], workingThreadIds: []))))
    )
    #expect(await eventually { model.generating.isEmpty })
}

@MainActor
@Test func stopWaitsForHostCessationEvenAfterReceipt() async throws {
    let transport = FakeTransport(autoReceipt: true)
    let model = await connected(transport)

    model.send("hi", in: "home")
    let target = try #require(model.events["home"]?.first?.id)
    await transport.yield(.event(event("active", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1,
            activeEventId: target)
    ])))))
    #expect(await eventually { model.activeEventId(in: "home") == target })
    model.interrupt(in: "home")
    let stop = try #require(await sent(by: transport, atLeast: pairingSends + 2)
        .first { $0.payload == .interrupt(InterruptData(targetEventId: target)) })
    #expect(model.stopPending(in: "home"))
    #expect(model.generating.contains("home"))
    await transport.yield(.event(event("requested", .stopStatus(StopStatusData(
        targetEventId: target, requestId: stop.id, status: .requested)))))
    #expect(model.stopPending(in: "home"))
    await transport.yield(.event(event("stopped", .stopStatus(StopStatusData(
        targetEventId: target, requestId: stop.id, status: .stopped)))))
    #expect(await eventually { !model.stopPending(in: "home") && !model.generating.contains("home") })
}

@MainActor
@Test func unconfirmedStopEndsPendingStateWithoutClaimingCessation() async throws {
    let transport = FakeTransport(autoReceipt: true)
    let model = await connected(transport)
    model.send("hi", in: "home")
    let target = try #require(model.events["home"]?.first?.id)
    await transport.yield(.event(event("active", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1, activeEventId: target)
    ])))))
    #expect(await eventually { model.activeEventId(in: "home") == target })
    model.interrupt(in: "home")
    let stop = try #require(await sent(by: transport, atLeast: pairingSends + 2)
        .first { $0.payload == .interrupt(InterruptData(targetEventId: target)) })
    await transport.yield(.event(event("unconfirmed", .stopStatus(StopStatusData(
        targetEventId: target, requestId: stop.id, status: .unconfirmed)))))
    #expect(await eventually { !model.stopPending(in: "home") && model.hasUnconfirmedStop(in: "home") })
    #expect(!model.generating.contains("home"))
}

@MainActor
@Test func sendingWhileATurnRunsSteersItWithoutStoppingIt() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)

    model.send("start", in: "home")
    model.send("change course", in: "home")

    #expect(model.generating.contains("home"))
    let messages = await sent(by: transport, atLeast: pairingSends + 2).filter { $0.payload.kind == .message }
    #expect(messages.count == 2)
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
    // Pairing's own requests went first, and the message is behind them.
    let message = try #require(
        await sent(by: transport, atLeast: pairingSends + 1).first { $0.payload.kind == .message }
    )
    guard case .message(let data) = message.payload else {
        Issue.record("not a message")
        return
    }
    #expect(data.attachments.first?.name == "p.png")
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
@Test(arguments: [0, 4, 5])
func finalStreamedReplyFollowsToolHistory(finalTimestamp: Int) async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    let stream = YorozuEvent(id: "reply", threadId: "home", ts: finalTimestamp == 0 ? 0 : 2, agentId: "main",
                            payload: .message(MessageData(role: .agent, text: "Checking")))
    let call = YorozuEvent(id: "call", threadId: "home", ts: finalTimestamp == 0 ? 0 : 3, agentId: "main",
                          payload: .toolCall(ToolCallData(callId: "c1", name: "shell", args: [:])))
    let result = YorozuEvent(id: "result", threadId: "home", ts: finalTimestamp == 0 ? 0 : 4, agentId: "main",
                            payload: .toolResult(ToolResultData(callId: "c1", ok: true, output: "ok")))
    let final = YorozuEvent(id: "reply", threadId: "home", ts: finalTimestamp, agentId: "main",
                           payload: .message(MessageData(role: .agent, text: "Finished", done: true)))
    for item in [stream, call, result] { await transport.yield(.event(item)) }
    #expect(await eventually { model.events["home"]?.count == 3 })
    await transport.yield(.event(final))
    #expect(await eventually { model.events["home"]?.contains(final) == true })
    #expect(model.timeline("home").rows(generating: false).map(\.id) == ["work-call", "reply"])
    #expect(model.events["home"]?.map(\.id) == ["call", "result", "reply"])

    // A reconnect replay must preserve the corrected position without duplicating rows.
    await transport.yield(.event(event("sync", .syncDelta(SyncDeltaData(events: [call, result, final])))))
    await transport.yield(.event(event("marker", .thought(ThoughtData(text: "other thread")), thread: "other")))
    #expect(await eventually { model.events["other"]?.count == 1 })
    #expect(model.timeline("home").rows(generating: false).map(\.id) == ["work-call", "reply"])
}

@MainActor
@Test func cachedFinalReplyReturnsBelowEarlierToolHistory() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: SymmetricKey(size: .bits256))
    cache.save(threads: [ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 5)])
    let final = YorozuEvent(id: "reply", threadId: "home", ts: 5, agentId: "main",
                           payload: .message(MessageData(role: .agent, text: "Finished", done: true)))
    let call = YorozuEvent(id: "call", threadId: "home", ts: 3, agentId: "main",
                          payload: .toolCall(ToolCallData(callId: "c1", name: "shell", args: [:])))
    let result = YorozuEvent(id: "result", threadId: "home", ts: 4, agentId: "main",
                            payload: .toolResult(ToolResultData(callId: "c1", ok: true, output: "ok")))
    cache.save(events: [final, call, result], threadId: "home")
    let model = ChatModel(transport: FakeTransport(), cache: cache)
    #expect(model.timeline("home").rows(generating: false).map(\.id) == ["work-call", "reply"])
}

@MainActor
@Test(arguments: [10, 11], [false, true])
func queuedMessageMovesAfterStoppedReplyAndSurvivesCacheRestore(
    finalTimestamp: Int, reverseDelivery: Bool
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SymmetricKey(size: .bits256)
    let cache = ThreadCache(directory: directory, key: key)
    cache.save(threads: [ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 21)])
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, cache: cache)
    model.start()

    let queued = YorozuEvent(id: "next", threadId: "home", ts: 11, agentId: "phone",
                             payload: .message(MessageData(role: .user, text: "next")))
    let stopped = YorozuEvent(id: "reply", threadId: "home", ts: finalTimestamp, agentId: "main",
                              payload: .message(MessageData(role: .agent, text: "partial", done: true,
                                                            interrupted: true)))
    let ordered = YorozuEvent(id: "next", threadId: "home", ts: finalTimestamp + 1, clientTs: 11, agentId: "phone",
                              payload: queued.payload)
    for item in reverseDelivery ? [queued, ordered, stopped, queued] : [queued, stopped, ordered, queued] {
        await transport.yield(.event(item))
    }
    #expect(await eventually { model.events["home"]?.first?.id == "reply" &&
        model.events["home"]?.last?.clientTs == 11 })
    #expect(model.events["home"]?.map(\.id) == ["reply", "next"])
    #expect(model.events["home"]?.last?.clientTs == 11)

    cache.save(events: model.events["home"]!, threadId: "home")
    try cache.savePending([OutboxItem(event: queued)])
    let restored = ChatModel(transport: FakeTransport(), cache: ThreadCache(directory: directory, key: key))
    #expect(restored.events["home"]?.map(\.id) == ["reply", "next"])
    #expect(restored.events["home"]?.last?.clientTs == 11)
}

@MainActor
@Test func lateSyncEventReturnsToWireOrderInsteadOfArrivalOrder() async throws {
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, device: "phone")
    model.start()

    let newer = YorozuEvent(id: "new", threadId: "home", ts: 3, agentId: "main",
                            payload: .message(MessageData(role: .agent, text: "new")))
    let older = YorozuEvent(id: "old", threadId: "home", ts: 2, agentId: "main",
                            payload: .thought(ThoughtData(text: "old")))
    await transport.yield(.event(newer))
    await transport.yield(.event(event("sync", .syncDelta(SyncDeltaData(events: [older])))))

    #expect(await eventually { model.events["home"]?.map(\.id) == ["old", "new"] })
}

@MainActor
@Test func liveEventsCannotMoveSyncPastUnseenPages() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    _ = await sent(by: transport, atLeast: pairingSends)
    let live = YorozuEvent(id: "live", threadId: "home", ts: 100, agentId: "main",
                          payload: .message(MessageData(role: .agent, text: "Newest reply", done: true)))
    let older = event("older", .thought(ThoughtData(text: "First page")))
    await transport.yield(.event(live))
    await transport.yield(.event(event("page", .syncDelta(SyncDeltaData(events: [older], more: true)))))

    let requests = await sent(by: transport, atLeast: pairingSends + 1)
    let next = try #require(requests.last)
    guard case .syncRequest(let data) = next.payload else {
        Issue.record("The next sync page was not requested")
        return
    }
    #expect(data.lastSeen == ["home": "older"])
    #expect(model.events["home"]?.map(\.id) == ["older", "live"])
}

@MainActor
@Test func currentFinalSurvivesOlderReplayWithoutSkippingHistory() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    model.openThread = "home"
    model.requestSync()
    let requests = await sent(by: transport, atLeast: pairingSends + 1)
    guard case .syncRequest(let request) = requests.last?.payload else {
        Issue.record("Current conversation sync was not requested")
        return
    }
    #expect(request.focusThreadId == "home")

    let final = YorozuEvent(id: "reply", threadId: "home", ts: 10, agentId: "main",
                            payload: .message(MessageData(role: .agent, text: "complete", done: true)))
    var old = YorozuEvent(id: "reply", threadId: "home", ts: 8, agentId: "main",
                          payload: .message(MessageData(role: .agent, text: "partial")))
    old.syncCursor = "first-page"
    await transport.yield(.event(event("page", .syncDelta(SyncDeltaData(
        events: [old], current: [final], more: true
    )))))
    #expect(await eventually { model.events["home"]?.first == final })
    let next = await sent(by: transport, atLeast: pairingSends + 2)
    guard case .syncRequest(let continuation) = next.last?.payload else {
        Issue.record("Next history page was not requested")
        return
    }
    #expect(continuation.lastSeen == ["home": "first-page"])
    #expect(continuation.includeCurrent == false)
}

@MainActor
@Test func openedThreadBackfillsFromStartAndRemembersCompletion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: SymmetricKey(size: .bits256))
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, cache: cache)
    await transport.yield(.ownerOnline(true))
    await transport.yield(.state(.paired))
    model.start()
    _ = await sent(by: transport, atLeast: pairingSends)
    await transport.yield(.event(event("threads", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 100),
        ThreadSummary(id: "other", title: "Other", archived: false, lastActivity: 100),
    ])))))
    let newer = event("newer", .message(MessageData(role: .agent, text: "After pairing")))
    await transport.yield(.event(event("routine", .syncDelta(SyncDeltaData(events: [newer])))))
    #expect(await eventually { model.events["home"]?.map(\.id) == ["newer"] })

    model.openThread = "home"
    let first = await sent(by: transport, atLeast: pairingSends + 1)
    guard case .syncRequest(let initial) = first.last?.payload else {
        Issue.record("Opening thread did not request history")
        return
    }
    #expect(initial.threadId == "home")
    #expect(initial.lastSeen.isEmpty)

    var older = event("older", .message(MessageData(role: .agent, text: "Before pairing")))
    older.ts = 0
    older.syncCursor = "history-page-1"
    await transport.yield(.event(event("page", .syncDelta(SyncDeltaData(
        events: [older], threadId: "home", more: true
    )))))
    let second = await sent(by: transport, atLeast: pairingSends + 2)
    guard case .syncRequest(let next) = second.last?.payload else {
        Issue.record("Next history page was not requested")
        return
    }
    #expect(next.threadId == "home")
    #expect(next.lastSeen == ["home": "history-page-1"])
    var latest = event("latest-history", .message(MessageData(role: .agent, text: "Latest")))
    latest.ts = 2
    await transport.yield(.event(event("last", .syncDelta(SyncDeltaData(
        events: [latest], threadId: "home"
    )))))
    #expect(await eventually { model.events["home"]?.map(\.id) == ["older", "newer", "latest-history"] })
    await model.flushCache()
    #expect(cache.historyState(threadId: "home").loaded)
    #expect(!cache.historyState(threadId: "other").loaded)

    let resumedTransport = FakeTransport()
    let resumed = ChatModel(transport: resumedTransport, cache: cache)
    await resumedTransport.yield(.ownerOnline(true))
    await resumedTransport.yield(.state(.paired))
    resumed.start()
    _ = await sent(by: resumedTransport, atLeast: pairingSends)
    resumed.openThread = "home"
    resumed.requestDevices() // Ordered send proves any open-triggered request would already be on wire.
    #expect((await sent(by: resumedTransport, atLeast: pairingSends + 1)).filter {
        if case .syncRequest(let data) = $0.payload { return data.threadId != nil }
        return false
    }.isEmpty)
}

@MainActor
@Test func interruptedSyncRestoresItsCursorWithoutSkippingCachedLiveEvents() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: SymmetricKey(size: .bits256))
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, cache: cache)
    model.start()
    await transport.yield(.event(event("threads", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 100),
    ])))))
    let live = YorozuEvent(id: "live", threadId: "home", ts: 100, agentId: "main",
                          payload: .message(MessageData(role: .agent, text: "Newest reply", done: true)))
    await transport.yield(.event(live))
    var older = event("older", .thought(ThoughtData(text: "First page")))
    older.syncCursor = "replay-position-1"
    await transport.yield(.event(event("page", .syncDelta(SyncDeltaData(events: [older], more: true)))))
    #expect(await eventually { model.events["home"]?.count == 2 })
    await model.flushCache()

    let resumedTransport = FakeTransport()
    let resumed = ChatModel(transport: resumedTransport, cache: cache)
    resumed.requestSync()
    let requests = await sent(by: resumedTransport, atLeast: 1)
    let next = try #require(requests.first)
    guard case .syncRequest(let data) = next.payload else {
        Issue.record("The resumed sync was not requested")
        return
    }
    #expect(data.lastSeen == ["home": "replay-position-1"])
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
    let picked = try #require(await sent(by: transport,
        payload: .threadSetModel(ThreadSetModelData(model: "codex/gpt-5.6")), in: "t1"))
    await transport.yield(.event(event("model-receipt", .receipt(ReceiptData(eventId: picked.id)))))
    #expect(await eventually { !model.outbox.contains { $0.id == picked.id } })

    model.setModel(model.threads[0], nil)
    #expect(model.threads[0].model == nil)
    let cleared = await sent(by: transport, payload: .threadSetModel(ThreadSetModelData(model: nil)), in: "t1")
    #expect(cleared?.payload == .threadSetModel(ThreadSetModelData(model: nil)))
}

/// A model picked in a chat nothing has been sent in yet has no thread on the Mac to be set on.
/// It waits on the draft and goes out with the message that creates the thread, ahead of it, so
/// the very first turn already runs on what was picked.
@MainActor
@Test func aModelPickedInADraftGoesOutWithTheMessageThatCreatesTheThread() async throws {
    let transport = FakeTransport(autoReceipt: true)
    let model = await connected(transport)
    let draft = model.newDraft()

    // Pairing's own requests are all that has gone out so far.
    let before = await sent(by: transport, atLeast: pairingSends).count

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
    let transport = FakeTransport(autoReceipt: true)
    let model = await connected(transport)
    let thread = ThreadSummary(id: "t1", title: "Kyoto", archived: false, lastActivity: 1)
    await transport.yield(.event(event("l1", .threadList(ThreadListData(threads: [thread])))))
    #expect(await eventually { model.threads == [thread] })

    model.setEffort(model.threads[0], .high)
    #expect(model.threads[0].effort == .high)
    let picked = try #require(await sent(by: transport,
        payload: .threadSetEffort(ThreadSetEffortData(effort: .high)), in: thread.id))
    // This is now a durable command. Model the runtime's receipt before starting another
    // send, otherwise the retained command correctly retries alongside the new draft.
    await transport.yield(.event(event("effort-receipt", .receipt(ReceiptData(eventId: picked.id)))))
    #expect(await eventually { model.outbox.isEmpty })

    let draft = model.newDraft()
    let before = await sent(by: transport, atLeast: pairingSends + 1).count
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
    let before = await sent(by: transport, atLeast: pairingSends).count

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

@MainActor
@Test func nativeBypassChangesGlobalYoloWithoutSavingADraftOverride() async throws {
    let transport = FakeTransport(autoReceipt: true)
    let model = await connected(transport)
    let before = await sent(by: transport, atLeast: pairingSends).count
    let draft = model.newDraft(agent: .claudeCode, cwd: "/tmp/project")
    model.setBypass(draft, true)
    #expect(model.yoloMode)
    #expect(model.draft?.bypass == nil)
    let settings = await sent(by: transport, atLeast: before + 1)
    #expect(settings.last?.payload == .approvalSettings(ApprovalSettingsData(yolo: true)))
    model.send("hi", in: draft.id)
    let created = await sent(by: transport, atLeast: before + 3)
    #expect(created.dropFirst(before).map(\.payload.kind) == [.approvalSettings, .threadCreate, .message])
    model.setBypass(ThreadSummary(id: "cx", title: "", archived: false, lastActivity: 1, agent: .codex), false)
    #expect(!model.yoloMode)
    let ordinary = model.newDraft()
    model.setBypass(ordinary, true)
    #expect(!model.yoloMode)
}

@MainActor
@Test func modelAndEffortChoicesBelongToTheThreadsAgent() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    let ordinary = ModelOption(id: "provider/model", label: "Model", providerLabel: "Provider", efforts: [.low, .medium, .high])
    let native = ModelOption(id: "opus", label: "Opus", providerLabel: "Claude Code", efforts: [.low, .max])
    await transport.yield(.event(event("models", .modelList(ModelListData(models: [ordinary], agentModels: ["claude-code": [native]])))))
    #expect(await eventually { model.agentModels["claude-code"] == [native] })
    let plain = ThreadSummary(id: "plain", title: "", archived: false, lastActivity: 1)
    let claude = ThreadSummary(id: "cc", title: "", archived: false, lastActivity: 1, agent: .claudeCode)
    let codex = ThreadSummary(id: "cx", title: "", archived: false, lastActivity: 1, agent: .codex)
    #expect(model.models(for: plain) == [ordinary])
    #expect(model.models(for: claude) == [native])
    #expect(model.models(for: codex).isEmpty)
    #expect(model.efforts(for: plain) == [.low, .medium, .high])
    #expect(model.efforts(for: claude) == [.low, .max])
}

@MainActor
@Test func cachedSyncPageDoesNotBlockTheMainActorForAFrameBurst() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: SymmetricKey(size: .bits256))
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, cache: cache)
    model.start()
    let page = (0..<200).map { i in
        YorozuEvent(id: "perf-\(i)", threadId: "perf", ts: i, agentId: "main",
            payload: .toolResult(ToolResultData(callId: "call-\(i)", ok: true, output: String(repeating: "x", count: 4096))))
    }
    var pageStart: ContinuousClock.Instant?
    var elapsed: Duration = .zero
    model.onEvent = { event in
        if event.id == "perf-0" { pageStart = .now }
        if event.id == "perf-199", let pageStart { elapsed = pageStart.duration(to: .now) }
    }
    await transport.yield(.event(event("page", .syncDelta(SyncDeltaData(events: page)))))
    #expect(await eventually { model.events["perf"]?.count == 200 })
    #expect(pageStart != nil)
    print("PERF sync-page-200x4KB main-actor elapsed=\(elapsed)")
    #expect(elapsed < .milliseconds(150))
    await model.flushCache()
    #expect(cache.events(threadId: "perf") == page)
    model.close()
}

@MainActor
@Test func backgroundThreadEventsDoNotInvalidateTheOpenThreadsTimeline() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    await confirmation("unrelated thread invalidation", expectedCount: 0) { changed in
        withObservationTracking {
            _ = model.timeline("selected").events
        } onChange: { changed() }
        await transport.yield(.event(YorozuEvent(id: "background", threadId: "other", ts: 1, agentId: "main", payload: .thought(ThoughtData(text: "working")))))
        #expect(await eventually { model.events["other"]?.count == 1 })
    }
}

@MainActor @Test func remoteAndCachedAnswersRetireNativeCards() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: SymmetricKey(size: .bits256))
    cache.save(threads: [ThreadSummary(id: "t", title: "", archived: false, lastActivity: 1)])
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, cache: cache)
    model.start()
    let approval = YorozuEvent(id: "a", threadId: "t", ts: 1, agentId: "phone2", payload: .approvalAnswer(ApprovalAnswerData(actionId: "action", answer: .no)))
    let question = YorozuEvent(id: "q", threadId: "t", ts: 2, agentId: "phone2", payload: .questionAnswer(QuestionAnswerData(questionId: "question", answer: "custom")))
    await transport.yield(.event(approval))
    await transport.yield(.event(event("sync", .syncDelta(SyncDeltaData(events: [question])))))
    #expect(await eventually { model.answered.contains("action") && model.answeredQuestions.contains("question") })
    await model.flushCache()
    let restored = ChatModel(transport: FakeTransport(), cache: cache)
    #expect(restored.choices["action"] == .no)
    #expect(restored.questionChoices["question"] == "custom")
    model.close()
}

@MainActor @Test func fullToolResultChunksReplacePreviewOnlyWhenCompleteAndCanRestart() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    let preview = YorozuEvent(id: "result", threadId: "t", ts: 1, agentId: "main", payload: .toolResult(ToolResultData(callId: "call", ok: true, output: "preview", truncated: true)))
    await transport.yield(.event(preview))
    #expect(await eventually { model.events["t"] == [preview] })
    let text = String(repeating: "界🙂", count: 300000)
    let first = String(text.prefix(300000)), second = String(text.dropFirst(300000))
    let offset = first.utf16.count
    model.requestToolResult("call", in: "t")
    var part = preview
    part.payload = .toolResult(ToolResultData(callId: "call", ok: true, output: first, chunkOffset: 0, nextOffset: offset))
    await transport.yield(.event(part))
    let requests = await sent(by: transport, atLeast: pairingSends + 2)
    #expect(requests.contains { if case .toolResultRequest(let data) = $0.payload { return data.offset == offset }; return false })
    #expect(model.events["t"] == [preview])
    // Reconnect/retry begins at zero, discarding the abandoned partial fetch.
    model.requestToolResult("call", in: "t")
    await transport.yield(.event(part))
    part.payload = .toolResult(ToolResultData(callId: "call", ok: true, output: second, chunkOffset: offset))
    await transport.yield(.event(part))
    #expect(await eventually { if case .toolResult(let data) = model.events["t"]?.first?.payload { return data.output == text && data.truncated == nil && data.chunkOffset == nil }; return false })
}

@MainActor @Test func completedSmallFullResultIsNotRequestedAgainOnReconnect() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    model.requestToolResult("small", in: "t")
    _ = await sent(by: transport, atLeast: pairingSends + 1)
    let full = YorozuEvent(id: "small", threadId: "t", ts: 1, agentId: "main", payload: .toolResult(ToolResultData(callId: "small", ok: true, output: String(repeating: "x", count: 5000))))
    await transport.yield(.event(full))
    #expect(await eventually { model.events["t"] == [full] })
    await transport.yield(.state(.paired))
    let requests = await sent(by: transport, atLeast: pairingSends * 2 + 1)
    #expect(requests.filter { $0.payload.kind == .toolResultRequest }.count == 1)
}

@MainActor @Test func hostSearchRejectsLateResultsFromPreviousQuery() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["thread-search-v1"])))
    await transport.yield(.event(event("list", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "t", title: "Old thread", archived: true, lastActivity: 1)
    ])))))
    #expect(await eventually { model.supportsHostSearch && model.threads.contains(where: { $0.id == "t" }) })

    model.searchHost("alpha")
    #expect(await eventually {
        await transport.sent.contains { if case .threadSearchRequest(let data) = $0.payload { return data.query == "alpha" }; return false }
    })
    let oldID = await transport.sent.compactMap { event -> String? in
        if case .threadSearchRequest(let data) = event.payload, data.query == "alpha" { return data.requestId }
        return nil
    }.last!
    model.searchHost("beta")
    await transport.yield(.event(event("old", .threadSearchResult(ThreadSearchResultData(
        requestId: oldID, matches: [ThreadSearchMatch(threadId: "t", eventId: "old-hit", excerpt: "alpha")]
    )))))
    #expect(model.remoteSearch.isEmpty)
    #expect(await eventually {
        await transport.sent.contains { if case .threadSearchRequest(let data) = $0.payload { return data.query == "beta" }; return false }
    })
    let newID = await transport.sent.compactMap { event -> String? in
        if case .threadSearchRequest(let data) = event.payload, data.query == "beta" { return data.requestId }
        return nil
    }.last!
    await transport.yield(.event(event("new", .threadSearchResult(ThreadSearchResultData(
        requestId: newID, matches: [ThreadSearchMatch(threadId: "fresh", eventId: "new-hit", excerpt: "beta",
            thread: ThreadSummary(id: "fresh", title: "New host thread", archived: false, lastActivity: 2))]
    )))))
    #expect(await eventually {
        model.remoteSearch["fresh"]?.eventId == "new-hit" && model.searchComplete &&
        model.threads.contains(where: { $0.id == "fresh" })
    })

    model.searchHost(String(repeating: "x", count: 129))
    #expect(model.searchScope.contains("shorten search"))
    model.searchHost("gamma")
    #expect(await eventually {
        await transport.sent.contains { if case .threadSearchRequest(let data) = $0.payload { return data.query == "gamma" }; return false }
    })
    let gammaID = await transport.sent.compactMap { event -> String? in
        if case .threadSearchRequest(let data) = event.payload, data.query == "gamma" { return data.requestId }
        return nil
    }.last!
    await transport.yield(.event(event("bad-cursor", .threadSearchResult(ThreadSearchResultData(
        requestId: gammaID, matches: [], nextOffset: 0
    )))))
    #expect(await eventually { model.searchIncomplete && !model.searchComplete })
}

@MainActor @Test func attachmentUploadResumesFromHostAckBeforeMessageAdmission() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["attachment-chunks-v1"])))
    #expect(await eventually {
        if case .compatible(_, let capabilities) = model.compatibility { return capabilities.contains("attachment-chunks-v1") }
        return false
    })
    let attachment = try #require(MessageAttachment(name: "image.png", mime: "image/png",
        bytes: Data(repeating: 7, count: 400_000)))
    model.send("inspect", in: "t", attachments: [attachment])
    #expect(await eventually { await transport.sent.contains(where: { $0.payload.kind == .attachmentChunk }) })
    let first = try #require(await transport.sent.first(where: { $0.payload.kind == .attachmentChunk }))
    guard case .attachmentChunk(let firstData) = first.payload else { return }
    #expect(firstData.offset == 0)
    #expect(Data(base64Encoded: firstData.data)?.count == 256 * 1024)
    #expect(model.attachmentTransferLabels(of: firstData.messageId)?.first?.contains("0%") == true)

    // The host may have saved the first frame while the response was lost. Its next ack
    // advances the same message rather than creating a second logical submission.
    await transport.yield(.state(.closed))
    #expect(await eventually { !model.canDeliver })
    await transport.yield(.state(.paired))
    await transport.yield(.ownerOnline(true))
    #expect(await eventually { model.canDeliver })
    model.retry(firstData.messageId)
    #expect(await eventually { await transport.sent.filter { $0.payload.kind == .attachmentChunk }.count >= 2 })
    let retry = try #require(await transport.sent.filter { $0.payload.kind == .attachmentChunk }.last)
    guard case .attachmentChunk(let retryData) = retry.payload else { return }
    #expect(retryData.offset == 0)
    await transport.yield(.event(event("progress", .attachmentProgress(AttachmentProgressData(
        requestId: retry.id, messageId: firstData.messageId, index: 0, nextOffset: 256 * 1024)))))
    #expect(await eventually { await transport.sent.filter { $0.payload.kind == .attachmentChunk }.count >= 3 })
    let second = try #require(await transport.sent.filter { $0.payload.kind == .attachmentChunk }.last)
    guard case .attachmentChunk(let secondData) = second.payload else { return }
    #expect(secondData.offset == 256 * 1024)
    #expect(model.attachmentTransferLabels(of: firstData.messageId)?.first?.contains("65%") == true)
    await transport.yield(.event(event("progress-2", .attachmentProgress(AttachmentProgressData(
        requestId: second.id, messageId: firstData.messageId, index: 0, nextOffset: 400_000)))))
    #expect(await eventually { await transport.sent.contains(where: { $0.payload.kind == .attachmentCommit }) })
    let commit = try #require(await transport.sent.first(where: { $0.payload.kind == .attachmentCommit }))
    #expect(commit.id == firstData.messageId)
    #expect(model.attachmentTransferLabels(of: firstData.messageId)?.first?.contains("awaiting host acceptance") == true)
    await transport.yield(.event(event("receipt", .receipt(ReceiptData(eventId: firstData.messageId)))))
    #expect(await eventually { !model.outbox.contains(where: { $0.id == firstData.messageId }) })
}

@MainActor @Test func withdrawalCanPassAnUnacknowledgedAttachmentChunk() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["attachment-chunks-v1"])))
    #expect(await eventually {
        if case .compatible(_, let capabilities) = model.compatibility { return capabilities.contains("attachment-chunks-v1") }
        return false
    })
    let attachment = try #require(MessageAttachment(name: "file.txt", mime: "text/plain",
        bytes: Data(repeating: 1, count: 400_000)))
    model.send("inspect", in: "t", attachments: [attachment])
    #expect(await eventually { await transport.sent.contains(where: { $0.payload.kind == .attachmentChunk }) })
    let messageID = try #require(model.outbox.first(where: { $0.event.payload.kind == .message })?.id)
    model.withdraw(messageID)
    #expect(await eventually { await transport.sent.contains(where: { $0.payload.kind == .interrupt }) })
    #expect(await transport.sent.filter { $0.payload.kind == .attachmentCommit }.isEmpty)
}

@MainActor @Test func withdrawalStartsWhileAttachmentSocketSendIsStalled() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["attachment-chunks-v1"])))
    #expect(await eventually {
        if case .compatible(_, let caps) = model.compatibility { return caps.contains("attachment-chunks-v1") }
        return false
    })
    await transport.holdChunks()
    let attachment = try #require(MessageAttachment(name: "file.txt", mime: "text/plain",
        bytes: Data(repeating: 1, count: 400_000)))
    model.send("inspect", in: "t", attachments: [attachment])
    #expect(await eventually { await transport.sent.contains { $0.payload.kind == .attachmentChunk } })
    let messageID = try #require(model.outbox.first(where: { $0.event.payload.kind == .message })?.id)
    model.withdraw(messageID)
    #expect(await eventually { await transport.sent.contains { $0.payload.kind == .interrupt } })
    await transport.releaseChunks()
}

@MainActor @Test(arguments: [false, true])
func deferredAttachmentDownloadsAfterVisibleHistoryArrives(legacyCache: Bool) async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["attachment-chunks-v1"])))
    let bytes = Data(repeating: 42, count: 300_000)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let preview = event("host-file", .message(MessageData(role: .user, text: "image",
        attachments: [MessageAttachment(name: "photo.png", mime: "image/png",
            data: legacyCache ? "yorozu-deferred-v1:\(bytes.count):\(digest)" : "",
            sizeBytes: legacyCache ? nil : bytes.count,
            sha256: legacyCache ? nil : digest)])), thread: "t")
    await transport.yield(.event(preview))
    #expect(await eventually { model.events["t"]?.contains(where: { $0.id == preview.id }) == true })
    model.requestAttachmentDownloads(preview)
    #expect(await eventually { await transport.sent.contains { $0.payload.kind == .attachmentDownloadRequest } })
    let first = event("part-1", .attachmentDownloadChunk(AttachmentDownloadChunkData(
        messageId: preview.id, index: 0, offset: 0, totalBytes: bytes.count,
        data: bytes.prefix(MessageAttachment.chunkBytes).base64EncodedString(), sha256: digest)), thread: "t")
    await transport.yield(.event(first))
    #expect(await eventually { await transport.sent.contains { item in
        if case .attachmentDownloadRequest(let data) = item.payload { return data.offset == MessageAttachment.chunkBytes }
        return false
    } })
    await transport.yield(.event(event("part-2", .attachmentDownloadChunk(AttachmentDownloadChunkData(
        messageId: preview.id, index: 0, offset: MessageAttachment.chunkBytes, totalBytes: bytes.count,
        data: bytes.dropFirst(MessageAttachment.chunkBytes).base64EncodedString(), sha256: digest)), thread: "t")))
    #expect(await eventually {
        guard let stored = model.events["t"]?.first(where: { $0.id == preview.id }),
              case .message(let data) = stored.payload else { return false }
        return data.attachments.first?.bytes == bytes
    })
}

@MainActor @Test func confirmedAttachmentBytesSurviveClientRelaunch() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SymmetricKey(size: .bits256)
    let cache = ThreadCache(directory: directory, key: key)
    let ts = Int(Date().timeIntervalSince1970 * 1000)
    let file = try #require(MessageAttachment(name: "file.txt", mime: "text/plain",
        bytes: Data(repeating: 1, count: 400_000)))
    let message = YorozuEvent(id: "upload", threadId: "home", ts: ts, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "inspect", attachments: [file],
            admissionDeadline: ts + 30 * 60_000)))
    try cache.savePending([OutboxItem(event: message, attemptedAt: Date(), uploadOffsets: [256 * 1024],
        uploadDescriptors: [AttachmentDescriptor(name: "file.txt", mime: "text/plain", bytes: 400_000,
            sha256: String(repeating: "a", count: 64))])])
    let restored = ChatModel(transport: FakeTransport(), cache: ThreadCache(directory: directory, key: key))
    #expect(restored.outbox.first?.uploadOffsets == [256 * 1024])
    #expect(restored.outbox.first?.uploadDescriptors?.first?.bytes == 400_000)
}

@MainActor @Test func olderHostKeepsLargeAttachmentQueuedWithExplicitUpgradeReason() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    let attachment = try #require(MessageAttachment(name: "file.txt", mime: "text/plain",
        bytes: Data(repeating: 1, count: 400_000)))
    model.send("inspect", in: "t", attachments: [attachment])
    #expect(await eventually { model.failure?.contains("Update the host") == true })
    let item = try #require(model.outbox.first(where: { $0.event.payload.kind == .message }))
    #expect(item.status == .queued)
    #expect(await transport.sent.allSatisfy { $0.payload.kind != .message && $0.payload.kind != .attachmentChunk })
}
