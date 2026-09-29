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
@Test func promptHistoryWalksThreadUserMessagesAndEditsEndBrowsing() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    await transport.yield(.event(event("first", .message(MessageData(role: .user, text: "first prompt")))))
    await transport.yield(.event(event("reply", .message(MessageData(role: .agent, text: "reply", done: true)))))
    await transport.yield(.event(event("other", .message(MessageData(role: .user, text: "other thread")), thread: "other")))
    await transport.yield(.event(event("last", .message(MessageData(role: .user, text: "last prompt")))))
    #expect(await eventually { model.events["home"]?.count == 3 && model.events["other"]?.count == 1 })

    model.drafts["home"] = "unfinished"
    #expect(!model.recallPrompt(in: "home", older: true))
    #expect(!model.recallPrompt(in: "home", older: false))
    #expect(model.drafts["home"] == "unfinished")
    model.drafts["home"] = ""
    #expect(!model.recallPrompt(in: "home", older: false))
    #expect(model.recallPrompt(in: "home", older: true))
    #expect(model.drafts["home"] == "last prompt")
    #expect(model.recallPrompt(in: "home", older: true))
    #expect(model.drafts["home"] == "first prompt")
    #expect(!model.recallPrompt(in: "home", older: true))
    #expect(model.recallPrompt(in: "home", older: false))
    #expect(model.drafts["home"] == "last prompt")
    #expect(model.recallPrompt(in: "home", older: false))
    #expect(model.drafts["home"] == "")
    #expect(!model.recallPrompt(in: "empty", older: true))

    #expect(model.recallPrompt(in: "home", older: true))
    model.drafts["other"] = "independent edit"
    #expect(model.recallPrompt(in: "home", older: true))
    model.drafts["home"] = "edited prompt"
    #expect(!model.recallPrompt(in: "home", older: false))
    #expect(!model.recallPrompt(in: "home", older: true))
    #expect(model.drafts["home"] == "edited prompt")
    model.drafts["home"] = ""
    let file = MessageAttachment(name: "notes.txt", mime: "text/plain", data: "aGk=")
    model.attachments["home"] = [file]
    #expect(!model.recallPrompt(in: "home", older: true))
    model.attachments["home"] = []
    #expect(model.recallPrompt(in: "home", older: true))
    model.attachments["home"] = [file]
    model.attachments["home"] = []
    #expect(!model.recallPrompt(in: "home", older: false))
    #expect(model.drafts["home"] == "last prompt")
}

@MainActor
@Test func stashedDraftsSurviveRelaunchAndRestoreTextAndAttachments() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let key = SymmetricKey(size: .bits256)
    defer { try? FileManager.default.removeItem(at: directory) }
    func launch() -> ChatModel {
        ChatModel(transport: FakeTransport(), cache: ThreadCache(directory: directory, key: key))
    }
    let model = launch()
    let thread = model.newDraft()
    let file = MessageAttachment(name: "notes.txt", mime: "text/plain", data: "aGk=")
    model.drafts[thread.id] = "  unfinished\nthought  "
    model.attachments[thread.id] = [file]
    model.stashDraft(in: thread.id)
    #expect(model.drafts[thread.id] == "")
    #expect((model.attachments[thread.id] ?? []).isEmpty)
    model.attachments[thread.id] = [file]
    model.stashDraft(in: thread.id)
    model.stashDraft(in: thread.id) // An empty composer adds nothing.
    let other = model.newDraft()
    model.drafts[other.id] = "another thread"
    model.stashDraft(in: other.id)
    model.discardDraft(thread.id)

    let restored = launch() // No flush or close: stash is durable immediately.
    #expect(restored.isDraft(thread.id))
    let stashes = try #require(restored.stashes[thread.id])
    #expect(stashes.count == 2)
    #expect(restored.stashes[other.id]?.count == 1)
    restored.drafts[thread.id] = "quick question"
    restored.restoreStash(stashes[0].id, in: thread.id)
    #expect(restored.drafts[thread.id] == "quick question")
    #expect(restored.stashes[thread.id]?.count == 2)
    restored.drafts[thread.id] = ""
    restored.attachments[thread.id] = [file]
    restored.restoreStash(stashes[0].id, in: thread.id)
    #expect(restored.drafts[thread.id] == "")
    restored.attachments[thread.id] = []
    restored.restoreStash(stashes[0].id, in: other.id)
    #expect(restored.stashes[thread.id]?.count == 2)
    restored.restoreStash(stashes[0].id, in: thread.id)
    #expect(restored.drafts[thread.id] == "  unfinished\nthought  ")
    #expect(restored.attachments[thread.id] == [file])
    #expect(restored.stashes[thread.id]?.count == 1)

    let again = launch()
    #expect(again.drafts[thread.id] == "  unfinished\nthought  ")
    #expect(again.attachments[thread.id] == [file])
    let remaining = try #require(again.stashes[thread.id]?.first)
    #expect(remaining.attachments == [file])
    again.drafts[thread.id] = ""
    again.attachments[thread.id] = []
    again.restoreStash(remaining.id, in: thread.id)
    #expect(again.drafts[thread.id] == "")
    #expect(again.attachments[thread.id] == [file])
    #expect(again.stashes[thread.id]?.isEmpty == true)
    again.archive(other)
    #expect(launch().stashes[other.id] == nil)
}

@MainActor
@Test func stagedComposerSurvivesImmediateRelaunchWithoutFlush() {
    let cache = ThreadCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString),
                            key: SymmetricKey(size: .bits256))
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let model = ChatModel(transport: FakeTransport(), cache: cache)
    let thread = model.newDraft(agent: .codex, cwd: "/project")
    model.openThread = thread.id
    let file = MessageAttachment(name: "notes.txt", mime: "text/plain", data: "aGk=")
    model.attachments[thread.id] = [file]
    model.drafts[thread.id] = "unfinished"

    let restored = ChatModel(transport: FakeTransport(), cache: cache)
    #expect(restored.openThread == thread.id)
    #expect(restored.draft == thread)
    #expect(restored.drafts[thread.id] == "unfinished")
    #expect(restored.attachments[thread.id] == [file])
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

    await model.flushCache()

    let resumed = ChatModel(transport: FakeTransport(), cache: cache)
    #expect(resumed.drafts[draft.id] == "unsent")
    #expect(resumed.attachments[draft.id] == model.attachments[draft.id])
    #expect(resumed.openThread == draft.id)
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
    let toast = ConnectionToastPresentation(duration: .milliseconds(100))
    let link = ConnectionPresentation(.connected)
    link.onStateChange = { toast.declared($0) }

    link.update(.reconnecting, active: true, since: .now - .seconds(6))
    let noticeID = toast.notice?.id
    #expect(noticeID != nil)
    link.update(.offline, active: true, since: .now - .seconds(6))
    #expect(toast.visible == .offline)
    #expect(toast.notice?.id == noticeID)
    #expect(toast.lastNotice?.state == .offline)
    let announcementRevision = toast.notice?.announcementRevision
    link.update(.reconnecting, active: true, since: .now - .seconds(6))
    #expect(toast.visible == .reconnecting)
    #expect(toast.notice?.announcementRevision == announcementRevision)
    link.update(.offline, active: true, since: .now - .seconds(6))
    #expect(toast.visible == .offline)
    #expect(toast.notice?.announcementRevision == announcementRevision)
    for _ in 0..<30 where toast.visible != nil {
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
@Test func connectionPresentationDoesNotRestartGraceWhenInterruptionChangesKind() async {
    let grace = Duration.seconds(20)
    let presentation = ConnectionPresentation(.connected)

    // Start partway through the original interruption without relying on a sleep that can
    // overshoot under CI load and let the original deadline pass before this assertion.
    presentation.update(.reconnecting, active: true, since: .now - .seconds(19), grace: grace)
    #expect(presentation.state == .connected)

    let changed = ContinuousClock.now
    presentation.update(.offline, active: true, grace: grace)
    await settled(presentation, at: .offline)
    #expect(presentation.state == .offline)
    // About one second is left; a restarted window would take another 20 seconds.
    #expect(ContinuousClock.now - changed < .seconds(10))
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
    // Archived threads are kept because Settings lists them and thread search finds them.
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
    var delivered = false
    model.onEvent = { delivered = delivered || $0.id == reply.id }
    #expect(model.threadRef(containingEventRef: ref) == nil)
    await transport.yield(.event(event("sync", .syncDelta(SyncDeltaData(events: [reply])))))
    #expect(await eventually { delivered && model.threadRef(containingEventRef: ref) == YorozuCrypto.threadRef(reply.threadId) })
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
@Test func pendingComposerCardsAdvanceThroughApprovalsAndQuestions() async throws {
    let transport = FakeTransport(autoReceipt: true)
    let model = await connected(transport)
    defer { model.close() }
    let thread = ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1)
    let placeholder = "Message Yorozu"
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["turn-state-v1"])))
    await transport.yield(.event(event("working", .threadList(ThreadListData(threads: [
        ThreadSummary(id: thread.id, title: thread.title, archived: false, lastActivity: 1,
            turnState: .running)
    ])))))
    #expect(await eventually { model.generating.contains(thread.id) })
    let first = ApprovalCardData(actionId: "a1", actionClass: "run-command", target: "echo one")
    let second = ApprovalCardData(actionId: "a2", actionClass: "run-command", target: "echo two")
    await transport.yield(.event(event("approval-1", .approvalCard(first))))
    await transport.yield(.event(event("approval-2", .approvalCard(second))))
    #expect(await eventually { model.pendingComposerCards(in: thread.id).count == 2 })
    #expect(model.composerPlaceholder(in: thread.id, default: placeholder) == "Resolve approval to continue")

    model.drafts[thread.id] = "keep this draft"
    model.send(in: thread)
    #expect(model.drafts[thread.id] == "keep this draft")
    model.answer(first.actionId, in: thread.id, .yes)
    #expect(model.pendingComposerCards(in: thread.id).count == 1)
    model.answer(second.actionId, in: thread.id, .no)
    #expect(model.pendingComposerCards(in: thread.id).isEmpty)
    let approvals = await sent(by: transport, atLeast: pairingSends + 2)
    #expect(approvals.filter { $0.payload.kind == .message }.isEmpty)
    #expect(Dictionary(uniqueKeysWithValues: approvals.compactMap { event -> (String, ApprovalAnswerData.Answer)? in
        guard case .approvalAnswer(let answer) = event.payload else { return nil }
        return (answer.actionId, answer.answer)
    }) == ["a1": .yes, "a2": .no])

    let options = (1...9).map { "Choice \($0)" }
    await transport.yield(.event(event("question-1", .questionCard(QuestionCardData(
        questionId: "q1", question: "Which?", options: options)))))
    await transport.yield(.event(event("question-2", .questionCard(QuestionCardData(
        questionId: "q2", question: "Why?", options: ["A", "B"], allowOther: true)))))
    #expect(await eventually { model.pendingComposerCards(in: thread.id).count == 2 })
    #expect(model.composerPlaceholder(in: thread.id, default: placeholder) == "Type a custom answer or pick an option")
    model.answerQuestionOption(0, in: thread.id)
    model.answerQuestionOption(10, in: thread.id)
    #expect(model.pendingComposerCards(in: thread.id).count == 2)
    model.answerQuestionOption(9, in: thread.id)
    #expect(model.pendingComposerCards(in: thread.id).count == 1)
    #expect(model.questionChoices["q1"] == "Choice 9")

    model.drafts[thread.id] = "  something else  "
    model.send(in: thread)
    #expect(model.drafts[thread.id] == "")
    #expect(model.pendingComposerCards(in: thread.id).isEmpty)
    #expect(model.composerPlaceholder(in: thread.id, default: placeholder) == placeholder)
    let sentEvents = await sent(by: transport, atLeast: pairingSends + 4)
    #expect(Dictionary(uniqueKeysWithValues: sentEvents.compactMap { event -> (String, String)? in
        guard case .questionAnswer(let answer) = event.payload else { return nil }
        return (answer.questionId, answer.answer)
    }) == ["q1": "Choice 9", "q2": "something else"])
    #expect(sentEvents.filter { $0.payload.kind == .message }.isEmpty)
}

@MainActor
@Test func staleCardsDoNotBlockTheComposerAfterTheHostTurnEnds() async throws {
    let transport = FakeTransport(autoReceipt: true)
    let model = await connected(transport)
    defer { model.close() }
    let thread = ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1)
    let approval = ApprovalCardData(actionId: "stale", actionClass: "run-command", target: "echo stale")
    let question = QuestionCardData(questionId: "stale-question", question: "Which?", options: ["A"])
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["turn-state-v1"])))
    await transport.yield(.event(event("working", .threadList(ThreadListData(threads: [
        ThreadSummary(id: thread.id, title: thread.title, archived: false, lastActivity: 1,
            turnState: .running)
    ])))))
    await transport.yield(.event(event("old-approval", .approvalCard(approval))))
    await transport.yield(.event(event("old-question", .questionCard(question))))
    #expect(await eventually { model.pendingComposerCards(in: thread.id).count == 2 })

    await transport.yield(.event(event("idle", .threadList(ThreadListData(threads: [
        ThreadSummary(id: thread.id, title: thread.title, archived: false, lastActivity: 2,
            turnState: .idle)
    ])))))
    #expect(await eventually { !model.generating.contains(thread.id) })
    #expect(model.pendingComposerCards(in: thread.id).isEmpty)
    #expect(model.composerPlaceholder(in: thread.id, default: "Message Yorozu") == "Message Yorozu")
    model.answerQuestionOption(1, in: thread.id)
    model.drafts[thread.id] = "new request"
    model.send(in: thread)
    #expect(model.drafts[thread.id] == "")
    let sentEvents = await sent(by: transport, atLeast: pairingSends + 1)
    #expect(sentEvents.contains { event in
        guard event.threadId == thread.id, case .message(let data) = event.payload else { return false }
        return data.role == .user && data.text == "new request"
    })
    #expect(sentEvents.allSatisfy { $0.payload.kind != .questionAnswer })
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
@Test(arguments: [ThreadAgent.claudeCode, .codex])
func draftAgentChangesKeepComposerLocalUntilFirstSend(agent: ThreadAgent) async throws {
    let transport = FakeTransport(autoReceipt: true)
    let model = await connected(transport)
    defer { model.close() }
    await transport.yield(.event(event("folders", .projectList(ProjectListData(projects: [
        ProjectFolder(path: "/Projects/app", name: "app")
    ])))))
    #expect(await eventually { model.projects.count == 1 })
    let draft = model.newDraft()
    let attachment = MessageAttachment(name: "note.txt", mime: "text/plain", data: "aGk=")
    model.drafts[draft.id] = "keep this prompt"
    model.attachments[draft.id] = [attachment]
    #expect(draft.agent == nil)
    #expect(!model.configureDraft(draft.id, agent: agent, cwd: nil))
    #expect(!model.configureDraft(draft.id, agent: agent, cwd: "/Projects/missing"))
    #expect(model.draft?.agent == nil)
    #expect(model.configureDraft(draft.id, agent: agent, cwd: "/Projects/app"))
    #expect(model.configureDraft(draft.id, agent: .yorozu, cwd: nil))
    #expect(model.draft?.cwd == nil)
    #expect(model.configureDraft(draft.id, agent: agent, cwd: "/Projects/app"))
    #expect(model.drafts[draft.id] == "keep this prompt")
    #expect(model.attachments[draft.id] == [attachment])
    #expect(model.outbox.isEmpty)
    #expect(await transport.sent.allSatisfy { $0.threadId != draft.id })

    let selected = try #require(model.draft)
    model.send(in: selected)
    let delivered = await sent(by: transport, atLeast: pairingSends + 2)
        .filter { $0.threadId == draft.id }
    #expect(delivered.map(\.payload.kind) == [.threadCreate, .message])
    guard case .threadCreate(let creation) = delivered.first?.payload,
          case .message(let message) = delivered.last?.payload else {
        Issue.record("Expected creation followed by the first message")
        return
    }
    #expect(creation.agent == agent)
    #expect(creation.cwd == "/Projects/app")
    #expect(message.text == "keep this prompt")
    #expect(message.attachments == [attachment])
    #expect(!model.configureDraft(draft.id, agent: .yorozu, cwd: nil))
    #expect(model.threads.first?.agent == agent)
    #expect(model.threads.first?.cwd == "/Projects/app")
}

@MainActor
@Test func rejectedThreadCreationKeepsItsMessageVisibleAndOffTheWire() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    let draft = model.newDraft(agent: .codex, cwd: "/tmp/missing-project")
    model.send("fix tests", in: draft.id)
    let create = try #require((await sent(by: transport, atLeast: pairingSends + 1))
        .first { $0.threadId == draft.id && $0.payload.kind == .threadCreate })
    await transport.yield(.event(event("create-rejected", .admissionStatus(AdmissionStatusData(
        eventId: create.id, status: .rejected, reason: "project folder unavailable")))))
    #expect(await eventually {
        model.outbox.first(where: { $0.event.threadId == draft.id && $0.event.payload.kind == .message })?.status == .rejected
    })
    let message = try #require(model.outbox.first { $0.event.threadId == draft.id && $0.event.payload.kind == .message })
    #expect(model.outboxRejectionReason(of: message.id) == "thread-create-rejected: project folder unavailable")
    #expect(await transport.sent.allSatisfy { $0.threadId != draft.id || $0.payload.kind != .message })
}

@MainActor
@Test func attachmentsRejectedAfterReceiptStayVisibleAsNotSent() async throws {
    let transport = FakeTransport(autoReceipt: true)
    let model = await connected(transport)
    defer { model.close() }
    let photo = try #require(MessageAttachment(name: "photo.jpg", mime: "image/jpeg", bytes: Data(repeating: 1, count: 64)))
    model.send("", in: "home", attachments: [photo])
    let message = try #require(await sent(by: transport, atLeast: pairingSends + 1).first { $0.payload.kind == .message })
    #expect(await eventually { model.outbox.isEmpty })
    // An old OpenClaw plugin connected after the host queued it: the host says so on every device.
    await transport.yield(.event(event("late-reject", .admissionStatus(AdmissionStatusData(
        eventId: message.id, status: .rejected, reason: "attachments-unsupported")))))
    #expect(await eventually { model.outboxStatus(of: message.id) == .rejected })
    #expect(model.outboxRejectionReason(of: message.id) == "attachments-unsupported")
    guard case .message(let shown)? = model.events["home"]?.first(where: { $0.id == message.id })?.payload else {
        Issue.record("message left the timeline")
        return
    }
    #expect(shown.attachments == [photo])
    // Not resent: nothing but the original message went out.
    #expect(await transport.sent.filter { $0.payload.kind == .message }.count == 1)
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
    #expect(ThreadGroups([summary("filed", minutesAgo: 1, archived: true)]).isEmpty)
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
@Test func replyActionsFollowSettledMessagesAndLatestPrompt() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    let firstPrompt = event("u1", .message(MessageData(role: .user, text: "first")))
    let firstPartial = event("r1", .message(MessageData(role: .agent, text: "working")))
    let firstFinal = event("r1", .message(MessageData(role: .agent, text: "done", done: true)))
    await transport.yield(.event(firstPrompt))
    await transport.yield(.event(firstPartial))
    #expect(await eventually { model.events["home"]?.count == 2 })
    #expect(model.messageActions(for: firstPrompt).copy)
    #expect(!model.messageActions(for: firstPartial).copy)
    #expect(model.messageActions(for: firstPartial).retry == nil)

    await transport.yield(.event(firstFinal))
    #expect(await eventually { model.events["home"]?.last == firstFinal })
    #expect(model.messageActions(for: firstFinal).copy)
    #expect(model.messageActions(for: firstFinal).retry?.text == "first")

    model.send("second", in: "home")
    #expect(model.generating.contains("home"))
    #expect(model.messageActions(for: firstFinal).retry?.text == "first")
    let secondPrompt = try #require(model.events["home"]?.last)
    var secondFinal = event("r2", .message(MessageData(role: .agent, text: "again", done: true)))
    secondFinal.ts = secondPrompt.ts + 1
    await transport.yield(.event(secondFinal))
    #expect(await eventually { model.events["home"]?.last == secondFinal })
    #expect(model.messageActions(for: secondPrompt).copy)
    #expect(model.messageActions(for: firstFinal).copy)
    #expect(model.messageActions(for: firstFinal).retry == nil)
    #expect(model.messageActions(for: secondFinal).retry?.text == "second")
    model.close()
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
@Test func negotiatedHostTurnStateControlsWorkingAndStopAcrossEarlierReply() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["turn-state-v1"])))
    model.send("first", in: "home")
    await transport.yield(.event(event("turn-running", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1,
            activeEventId: "second-turn", turnState: .running, queuedTurnCount: 0)
    ])))))
    #expect(await eventually { model.generating.contains("home") && model.canStop(in: "home") })

    await transport.yield(.event(event("earlier-final", .message(MessageData(
        role: .agent, text: "first reply", done: true
    )))))
    #expect(await eventually { model.generating.contains("home") && model.canStop(in: "home") })

    await transport.yield(.event(event("turn-idle", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 2,
            turnState: .idle, queuedTurnCount: 0)
    ])))))
    #expect(await eventually { !model.generating.contains("home") && !model.canStop(in: "home") })
}

@MainActor
@Test func threadListStatusTracksHostTurnAndAttentionChanges() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["turn-state-v1"])))
    func status() -> ThreadStatus? {
        guard let thread = model.threads.first(where: { $0.id == "home" }) else { return nil }
        return ThreadStatus(thread, working: model.generating.contains(thread.id))
    }
    func send(_ id: String, _ thread: ThreadSummary) async {
        await transport.yield(.event(event(id, .threadList(ThreadListData(threads: [thread])))))
    }

    await send("working", ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1,
                                         turnState: .running))
    #expect(await eventually { status() == .working })
    await send("input", ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 2,
                                       awaitingQuestion: true, turnState: .running))
    #expect(await eventually { status() == .needsInput })
    await send("approval", ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 3,
                                          awaitingApproval: true, awaitingQuestion: true, turnState: .running))
    #expect(await eventually { status() == .needsApproval })
    await send("failed", ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 4,
                                        needsAttention: true, turnState: .idle))
    #expect(await eventually { status() == .failed })
    await send("done", ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 5,
                                      lastReadAt: 10, lastAgentAt: 20, turnState: .idle))
    #expect(await eventually { status() == .doneUnread })
    await send("read", ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 6,
                                      lastReadAt: 20, lastAgentAt: 20, turnState: .idle))
    #expect(await eventually { model.threads.first?.lastActivity == 6 && status() == .idle })
    model.close()
}

@MainActor
@Test func threadNotificationsRequireStatusTransitionsAndIgnoreReplay() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["turn-state-v1"])))
    var notices: [ThreadStatus] = []
    model.onThreadNotification = { threadID, status, presentation in
        #expect(threadID == "home")
        #expect(presentation == .system)
        notices.append(status)
    }
    var lists = 0
    model.onThreads = { lists += 1 }
    func send(_ thread: ThreadSummary) async {
        let next = lists + 1
        await transport.yield(.event(event("list-\(next)", .threadList(ThreadListData(threads: [thread])))))
        #expect(await eventually { lists == next })
    }
    var thread = ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1,
                               awaitingApproval: true, turnState: .running)
    await send(thread)
    #expect(notices.isEmpty)
    thread.awaitingApproval = false
    await send(thread)
    #expect(notices.isEmpty)
    thread.awaitingQuestion = true
    await send(thread)
    #expect(notices == [.needsInput])
    thread.awaitingApproval = true
    await send(thread)
    #expect(notices == [.needsInput, .needsApproval])

    let reply = event("reply", .message(MessageData(role: .agent, text: "still working", done: true)))
    await transport.yield(.event(reply))
    await transport.yield(.event(event("replay", .syncDelta(SyncDeltaData(events: [reply])))))
    thread.lastActivity = 2
    thread.title = "Renamed"
    await send(thread)
    #expect(notices == [.needsInput, .needsApproval])
    thread.awaitingApproval = false
    await send(thread)
    #expect(notices == [.needsInput, .needsApproval, .needsInput])
    thread.awaitingQuestion = false
    thread.needsAttention = true
    thread.turnState = .idle
    await send(thread)
    thread.needsAttention = false
    thread.lastAgentAt = 20
    thread.lastReadAt = 10
    await send(thread)
    #expect(notices == [.needsInput, .needsApproval, .needsInput, .failed, .doneUnread])
    await transport.yield(.ownerOnline(false))
    await transport.yield(.ownerOnline(true))
    await send(thread)
    #expect(notices.count == 5)
    thread.lastReadAt = 20
    await send(thread)
    #expect(notices.count == 5)
}

@MainActor
@Test func threadNotificationsChooseToastOrSystemAndSuppressTheOpenThread() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    var presentations: [ChatModel.ThreadNotificationPresentation] = []
    model.onThreadNotification = { _, _, presentation in presentations.append(presentation) }
    var lists = 0
    model.onThreads = { lists += 1 }
    func send(waiting: Bool) async {
        let next = lists + 1
        await transport.yield(.event(event("list-\(next)", .threadList(ThreadListData(threads: [
            ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1,
                          awaitingApproval: waiting)
        ])))))
        #expect(await eventually { lists == next })
    }
    await send(waiting: false)
    model.foreground = true
    model.openThread = "other"
    await send(waiting: true)
    #expect(presentations == [.toast])
    await send(waiting: false)
    model.openThread = "home"
    await send(waiting: true)
    #expect(presentations == [.toast])
    model.foreground = false
    await send(waiting: true)
    #expect(presentations == [.toast])
    await send(waiting: false)
    await send(waiting: true)
    #expect(presentations == [.toast, .system])
}

@MainActor
@Test func waitingBadgeCountsThreadsOnceAndClearsResolvedOrRemovedThreads() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    let threads = [
        ThreadSummary(id: "both", title: "Both", archived: false, lastActivity: 1,
                      awaitingApproval: true, awaitingQuestion: true),
        ThreadSummary(id: "input", title: "Input", archived: false, lastActivity: 1, awaitingQuestion: true),
        ThreadSummary(id: "failed", title: "Failed", archived: false, lastActivity: 1, needsAttention: true),
        ThreadSummary(id: "unread", title: "Unread", archived: false, lastActivity: 1, lastAgentAt: 20),
        ThreadSummary(id: "working", title: "Working", archived: false, lastActivity: 1, turnState: .running)
    ]
    await transport.yield(.event(event("list", .threadList(ThreadListData(threads: threads)))))
    #expect(await eventually { model.threads.count == 5 })
    #expect(model.waitingCount == 2)
    var resolved = threads[0]
    resolved.awaitingApproval = false
    resolved.awaitingQuestion = false
    await transport.yield(.event(event("resolved", .threadList(ThreadListData(threads: [resolved, threads[1]])))))
    #expect(await eventually { model.threads.count == 2 && model.waitingCount == 1 })
    await transport.yield(.event(event("removed", .threadList(ThreadListData(threads: [resolved])))))
    #expect(await eventually { model.threads.count == 1 && model.waitingCount == 0 })
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
    #expect(!model.canStop(in: "home"))
    #expect(model.generating.contains("home"))
    await transport.yield(.event(event("requested", .stopStatus(StopStatusData(
        targetEventId: target, requestId: stop.id, status: .requested)))))
    #expect(model.stopPending(in: "home"))
    #expect(!model.canStop(in: "home"))
    await transport.yield(.event(event("stopped", .stopStatus(StopStatusData(
        targetEventId: target, requestId: stop.id, status: .stopped)))))
    #expect(await eventually { !model.stopPending(in: "home") && !model.generating.contains("home") })
}

@MainActor
@Test func hostStoppingStateDisablesStopUntilConfirmation() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["turn-state-v1"])))
    await transport.yield(.event(event("stopping", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1,
            activeEventId: "active", turnState: .stopping, queuedTurnCount: 0)
    ])))))
    #expect(await eventually { model.generating.contains("home") && !model.canStop(in: "home") })
    await transport.yield(.event(event("uncertain", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1,
            activeEventId: "active", turnState: .stoppedUnconfirmed, queuedTurnCount: 0)
    ])))))
    #expect(await eventually { !model.canStop(in: "home") })
}

@MainActor
@Test func queuedWithdrawalKeepsRunningTurnsStopAvailable() async throws {
    let transport = FakeTransport(autoReceipt: true)
    let model = await connected(transport)
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["turn-state-v1"])))
    await transport.yield(.event(event("running", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1,
            activeEventId: "active", turnState: .running, queuedTurnCount: 1)
    ])))))
    let attachment = MessageAttachment(name: "context.txt", mime: "text/plain", data: "YQ==")
    await transport.yield(.event(event("queued", .message(MessageData(role: .user, text: "later", attachments: [attachment])))))
    #expect(await eventually { model.canStop(in: "home") && model.events["home"]?.count == 1 })

    model.withdraw("queued")
    let withdrawal = try #require(await sent(by: transport, payload: .interrupt(InterruptData(targetEventId: "queued")), in: "home"))
    #expect(!model.stopPending(in: "home"))
    #expect(model.canStop(in: "home"))
    #expect(model.generating.contains("home"))

    await transport.yield(.event(event("withdrawn", .stopStatus(StopStatusData(
        targetEventId: "queued", requestId: withdrawal.id, status: .withdrawn)))))
    #expect(await eventually { model.events["home"]?.contains(where: { $0.id == "withdrawn" }) == true })
    #expect(!model.stopPending(in: "home"))
    #expect(model.canStop(in: "home"))
    #expect(model.generating.contains("home"))

    #expect(model.drafts["home"] == "later")
    #expect(model.attachments["home"] == [attachment])
    #expect(model.rows(in: "home").isEmpty)
    model.interrupt(in: "home")
    #expect(await sent(by: transport, payload: .interrupt(InterruptData(targetEventId: "active")), in: "home") != nil)
}

@MainActor
@Test(arguments: [false, true])
func stopRestoresQueuedDraftOnEveryDevice(localMessages: Bool) async throws {
    let cache = ThreadCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString), key: SymmetricKey(size: .bits256))
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, cache: cache)
    let existing = MessageAttachment(name: "draft.txt", mime: "text/plain", data: "ZA==")
    let first = MessageAttachment(name: "first.txt", mime: "text/plain", data: "YQ==")
    let second = MessageAttachment(name: "second.txt", mime: "text/plain", data: "Yg==")
    var messages: [YorozuEvent] = []
    for (text, file) in [("first queued", first), ("second queued", second)] {
        if localMessages {
            model.send(text, in: "home", attachment: file)
            messages.append(try #require(model.events["home"]?.last))
        } else {
            messages.append(event(text, .message(MessageData(role: .user, text: text, attachments: [file]))))
        }
    }
    model.drafts["home"] = "existing draft"
    model.attachments["home"] = [existing]
    model.drafts["other"] = "other draft"
    model.attachments["other"] = [existing]
    model.start()
    let withdrawnAt = messages.map(\.ts).max()! + 1
    let withdrawals = messages.enumerated().map { index, message in
        YorozuEvent(id: "withdraw-\(message.id)", threadId: "home", ts: withdrawnAt + index,
            agentId: "main", payload: .stopStatus(StopStatusData(
                targetEventId: message.id, requestId: "stop-on-another-device", status: .withdrawn)))
    }
    for message in messages { await transport.yield(.event(message)) }
    if localMessages {
        await transport.yield(.event(event("withdrawal-page", .syncDelta(SyncDeltaData(events: withdrawals)))))
    } else {
        for withdrawal in withdrawals { await transport.yield(.event(withdrawal)) }
    }
    #expect(await eventually { model.drafts["home"] == "existing draft\n\nfirst queued\n\nsecond queued" })
    #expect(model.attachments["home"] == [existing, first, second])
    #expect(model.drafts["other"] == "other draft")
    #expect(model.attachments["other"] == [existing])
    #expect(messages.allSatisfy { !model.canWithdraw($0) })
    // A replay, including one after relaunch, must not restore the same text twice.
    for withdrawal in withdrawals { await transport.yield(.event(withdrawal)) }
    await transport.yield(.event(event("barrier", .thought(ThoughtData(text: "synced")))))
    #expect(await eventually { model.events["home"]?.contains(where: { $0.id == "barrier" }) == true })
    model.drafts["home"] = "edited restored draft"
    await model.shutdown()
    let replay = FakeTransport()
    let restored = ChatModel(transport: replay, cache: cache)
    restored.start()
    await replay.yield(.event(event("sync", .syncDelta(SyncDeltaData(events: messages + withdrawals)))))
    await replay.yield(.event(event("replayed", .thought(ThoughtData(text: "synced")))))
    #expect(await eventually { restored.events["home"]?.contains(where: { $0.id == "replayed" }) == true })
    #expect(restored.drafts["home"] == "edited restored draft")
    #expect(restored.attachments["home"] == [existing, first, second])
    await restored.shutdown()
}

@MainActor
@Test(arguments: [false, true])
func syncedWithdrawalDoesNotReviveOldDraft(ownOutboxWithLaterMessage: Bool) async throws {
    let transport = FakeTransport()
    let model = ChatModel(transport: transport)
    let original: YorozuEvent
    if ownOutboxWithLaterMessage {
        model.send("queued", in: "home")
        original = try #require(model.events["home"]?.first)
    } else {
        original = event("old-queued", .message(MessageData(role: .user, text: "queued")))
    }
    let withdrawn = YorozuEvent(id: "old-withdrawal", threadId: "home", ts: original.ts + 1,
        agentId: "main", payload: .stopStatus(StopStatusData(
            targetEventId: original.id, requestId: "stop", status: .withdrawn)))
    let later = YorozuEvent(id: "later-user", threadId: "home", ts: withdrawn.ts + 1,
        agentId: "main", payload: .message(MessageData(role: .user, text: "moved on")))
    model.start()
    await transport.yield(.event(event("history", .syncDelta(SyncDeltaData(
        events: ownOutboxWithLaterMessage ? [original, withdrawn, later] : [original, withdrawn])))))
    await transport.yield(.event(event("barrier", .thought(ThoughtData(text: "loaded")))))
    #expect(await eventually { model.events["home"]?.contains(where: { $0.id == "barrier" }) == true })
    #expect(model.drafts["home", default: ""] == "")
    #expect(model.attachments["home", default: []].isEmpty)
    if ownOutboxWithLaterMessage { #expect(model.outboxStatus(of: original.id) == .withdrawn) }
    await model.shutdown()
}

@MainActor
@Test func liveWithdrawalAfterLaterUserLeavesDraftAlone() async throws {
    let transport = FakeTransport()
    let model = ChatModel(transport: transport)
    model.start()
    let original = event("old-queued", .message(MessageData(role: .user, text: "queued")))
    let later = YorozuEvent(id: "later-user", threadId: "home", ts: 3,
        agentId: "main", payload: .message(MessageData(role: .user, text: "moved on")))
    await transport.yield(.event(event("history", .syncDelta(SyncDeltaData(events: [original, later])))))
    let withdrawn = YorozuEvent(id: "withdrawn", threadId: "home", ts: 2,
        agentId: "main", payload: .stopStatus(StopStatusData(
            targetEventId: original.id, requestId: "stop", status: .withdrawn)))
    await transport.yield(.event(withdrawn))
    #expect(await eventually { model.events["home"]?.contains(where: { $0.id == "withdrawn" }) == true })
    #expect(model.drafts["home", default: ""] == "")
    await model.shutdown()
}

@MainActor
@Test func withdrawnAttachmentRestoresWhenHistoryArrivesAndDownloadsIntoComposer() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["attachment-chunks-v1"])))
    let bytes = Data(repeating: 42, count: 1_024)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let attachment = MessageAttachment(name: "file.txt", mime: "text/plain", data: "", sizeBytes: bytes.count, sha256: digest)
    await transport.yield(.event(event("withdraw-file", .stopStatus(StopStatusData(
        targetEventId: "queued-file", requestId: "remote-stop", status: .withdrawn)))))
    let original = event("queued-file", .message(MessageData(role: .user, text: "", attachments: [attachment])))
    await transport.yield(.event(event("history", .syncDelta(SyncDeltaData(events: [original])))))
    #expect(await eventually { model.attachments["home"] == [attachment] })
    #expect(await sent(by: transport, payload: .attachmentDownloadRequest(AttachmentDownloadRequestData(
        messageId: original.id, index: 0, offset: 0)), in: "home") != nil)
    await transport.yield(.event(event("file-bytes", .attachmentDownloadChunk(AttachmentDownloadChunkData(
        messageId: original.id, index: 0, offset: 0, totalBytes: bytes.count,
        data: bytes.base64EncodedString(), sha256: digest)))))
    #expect(await eventually { model.attachments["home"]?.first?.bytes == bytes })
    #expect(model.attachments["home"]?.count == 1)
    #expect(model.attachments["home"]?.first?.isDeferred == false)
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
@Test func changedFilesAttachToTheirTurnReply() async {
    let transport = FakeTransport()
    let model = await connected(transport)
    let files = TurnChangesData(turnEventId: "first", files: [
        .init(path: "file.txt", added: 2, removed: 1)
    ])
    for item in [
        event("first", .message(MessageData(role: .user, text: "edit"))),
        event("reply-first", .message(MessageData(role: .agent, text: "done", done: true))),
        event("second", .message(MessageData(role: .user, text: "next"))),
        event("reply-second", .message(MessageData(role: .agent, text: "done", done: true))),
        event("changes", .turnChanges(files)),
    ] { await transport.yield(.event(item)) }
    #expect(await eventually { model.events["home"]?.count == 5 })
    let rows = model.timeline("home").rows(generating: false)
    #expect(rows.map(\.id) == ["first", "reply-first", "changes", "second", "reply-second"])
    guard case .changes(let change) = rows[2], case .turnChanges(let data) = change.payload else {
        Issue.record("missing changed-files card")
        return
    }
    #expect(data == files)
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
@Test func unreadableEventsLeaveHistoryAndLiveConversationUsable() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SymmetricKey(size: .bits256)
    let cache = ThreadCache(directory: directory, key: key)
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, cache: cache)
    model.start()
    await transport.yield(.state(.paired))
    await transport.yield(.ownerOnline(true))
    #expect(await eventually { model.canDeliver })
    let thread = ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 5)
    await transport.yield(.event(event("threads", .threadList(ThreadListData(threads: [thread])))))

    let fixture = Vectors.path(source: "ts").deletingLastPathComponent().appending(path: "forward-events.json")
    let page = try JSONDecoder().decode(YorozuEvent.self, from: Data(contentsOf: fixture))
    await transport.yield(.event(page))
    #expect(await eventually { model.events["home"]?.count == 5 })
    #expect(model.timeline("home").rows(generating: false).map(\.id) == ["before", "gap", "approval", "after"])
    #expect(searchHits(in: model.events["home"] ?? [], term: "unreadable").isEmpty)
    #expect(model.unreadCount == 0)
    #expect(model.markdown(of: thread).components(separatedBy: "Update Yorozu to see this event").count == 2)

    let before = await transport.sent.count
    model.requestSync()
    #expect(await eventually {
        let sent = await transport.sent
        return sent.dropFirst(before).contains {
            guard case .syncRequest(let request) = $0.payload else { return false }
            return request.lastSeen["home"] == "cursor-5"
        }
    })

    let liveFuture = try JSONDecoder().decode(YorozuEvent.self, from: Data(
        #"{"id":"live-future","threadId":"home","ts":6,"agentId":"main","kind":"future_housekeeping","data":{"value":"private"}}"#.utf8
    ))
    await transport.yield(.event(liveFuture))
    #expect(await eventually { model.events["home"]?.count == 6 })
    #expect(model.timeline("home").rows(generating: false).last?.id == "after")

    let live = try JSONDecoder().decode(YorozuEvent.self, from: Data(
        #"{"id":"live-gap","threadId":"home","ts":7,"agentId":"main","kind":"question_card","data":{"questionId":"q1","question":"Which?"}}"#.utf8
    ))
    await transport.yield(.event(live))
    #expect(await eventually { model.timeline("home").rows(generating: false).last?.id == "live-gap" })
    #expect((await transport.sent).allSatisfy { $0.payload.kind != .approvalAnswer && $0.payload.kind != .questionAnswer })

    await model.flushCache()
    let restored = ChatModel(transport: FakeTransport(), cache: ThreadCache(directory: directory, key: key))
    #expect(restored.events["home"] == model.events["home"])
    #expect(restored.timeline("home").rows(generating: false).last?.id == "live-gap")
    model.close()
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

/// A new thread starts on the model and effort last picked for its agent, not on Auto, and
/// that memory outlives the app. Each agent keeps its own: a Codex pick is not Claude Code's.
@MainActor
@Test func aNewThreadStartsOnTheLastModelPickedForItsAgent() {
    let cache = ThreadCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString),
                            key: SymmetricKey(size: .bits256))
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let model = ChatModel(transport: FakeTransport(), cache: cache)
    let codex = model.newDraft(agent: .codex, cwd: "/project")
    model.setModel(codex, "codex/gpt-5.6")

    let restored = ChatModel(transport: FakeTransport(), cache: cache)
    #expect(restored.newDraft(agent: .codex, cwd: "/project").model == "codex/gpt-5.6")
    #expect(restored.newDraft(agent: .claudeCode, cwd: "/project").model == nil)
    #expect(restored.newDraft().model == nil)
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
    let otherTransport = FakeTransport()
    let otherModel = await connected(otherTransport)
    let before = await sent(by: transport, atLeast: pairingSends).count
    let otherBefore = await sent(by: otherTransport, atLeast: pairingSends).count
    let until = 1_800_000_000_000

    model.requestApprovalSettings()
    var events = await sent(by: transport, atLeast: before + 1)
    #expect(events.last?.payload == .approvalSettings(ApprovalSettingsData()))
    await transport.yield(.event(event("s1", .approvalSettings(ApprovalSettingsData(yolo: true, yoloUntil: until)))))
    #expect(await eventually { model.yoloMode && model.yoloUntil == until })
    #expect(!otherModel.yoloMode)

    model.setYoloMode(false)
    events = await sent(by: transport, atLeast: before + 2)
    #expect(events.last?.payload == .approvalSettings(ApprovalSettingsData(yolo: false)))
    #expect(model.yoloMode == false)
    await transport.yield(.event(event("s2", .approvalSettings(ApprovalSettingsData(yolo: false)))))
    #expect(await eventually { model.yoloUntil == nil })

    // Returning to Settings requests the host's current value, including changes elsewhere.
    model.requestApprovalSettings()
    events = await sent(by: transport, atLeast: before + 3)
    #expect(events.last?.payload == .approvalSettings(ApprovalSettingsData()))
    await transport.yield(.event(event("s3", .approvalSettings(ApprovalSettingsData(yolo: true, yoloUntil: until + 1000)))))
    #expect(await eventually { model.yoloMode && model.yoloUntil == until + 1000 })
    await transport.yield(.event(event("s4", .approvalSettings(ApprovalSettingsData(yolo: false)))))
    #expect(await eventually { !model.yoloMode && model.yoloUntil == nil })
    #expect(!otherModel.yoloMode && otherModel.yoloUntil == nil)
    #expect(await otherTransport.sent.count == otherBefore)
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
@Test func skillsArriveWithTheModelListAndBelongToTheThreadsAgent() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    let wire = #"{"models":[],"skills":{"yorozu":[{"name":"remind","description":"Set a reminder"}],"claude-code":[{"name":"review","description":"Review the diff","argumentHint":"[path]"}]}}"#
    let data = try JSONDecoder().decode(ModelListData.self, from: Data(wire.utf8))
    await transport.yield(.event(event("skills", .modelList(data))))
    let review = SkillOption(name: "review", description: "Review the diff", argumentHint: "[path]")
    #expect(await eventually { model.skills["claude-code"] == [review] })
    let plain = ThreadSummary(id: "plain", title: "", archived: false, lastActivity: 1)
    let claude = ThreadSummary(id: "cc", title: "", archived: false, lastActivity: 1, agent: .claudeCode)
    let codex = ThreadSummary(id: "cx", title: "", archived: false, lastActivity: 1, agent: .codex)
    #expect(model.skills(for: plain).map(\.name) == ["remind"])
    #expect(model.skills(for: claude) == [review])
    #expect(model.skills(for: codex).isEmpty)
}

@MainActor
@Test func advertisedAgentCatalogSurvivesOfflineAndKeepsCompiledBuiltInIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SymmetricKey(size: .bits256)
    let cache = ThreadCache(directory: directory, key: key)
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, cache: cache)
    #expect(model.availableAgents.map(\.id) == ThreadAgent.allCases)
    model.start()
    let custom = try #require(ThreadAgent(rawValue: "test-harness"))
    let advertised = [
        AgentDescriptor(id: .yorozu, label: "Fake Yorozu", needsFolder: true),
        AgentDescriptor(id: custom, label: "Test Harness", description: "Answers prompts", needsFolder: false),
        AgentDescriptor(id: .codex, label: "Fake Codex", needsFolder: false),
    ]
    await transport.yield(.event(event("catalog", .modelList(ModelListData(models: [], agents: advertised)))))
    #expect(await eventually { model.availableAgents.map(\.id) == [.yorozu, custom, .codex] })
    #expect(model.agentLabel(custom) == "Test Harness")
    #expect(!model.needsFolder(custom))
    #expect(model.agentLabel(.codex) == "Codex")
    #expect(model.needsFolder(.codex))
    let restored = ChatModel(transport: FakeTransport(), cache: cache)
    #expect(restored.availableAgents.map(\.id) == [.yorozu, custom, .codex])
    #expect(restored.agentLabel(custom) == "Test Harness")
    await transport.yield(.event(event("old-host", .modelList(ModelListData(models: [])))))
    #expect(await eventually { model.availableAgents.map(\.id) == ThreadAgent.allCases })
    let afterDowngrade = ChatModel(transport: FakeTransport(), cache: cache)
    #expect(afterDowngrade.availableAgents.map(\.id) == ThreadAgent.allCases)
    model.close()
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
    await transport.yield(.event(event("after-old", .thought(ThoughtData(text: "processed")), thread: "t")))
    #expect(await eventually { model.events["t"]?.contains(where: { $0.id == "after-old" }) == true })
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
    await transport.yield(.state(.connecting))
    #expect(await eventually { !model.canDeliver })
    #expect(model.remoteSearch["fresh"]?.eventId == "new-hit")
    #expect(model.searchScope == "Downloaded conversations and cached host results")
    await transport.yield(.state(.paired))
    await transport.yield(.ownerOnline(true))
    #expect(await eventually { model.canDeliver })

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

@MainActor
@Test func editFromHereWaitsForHostAndRestoresAcrossDevicesAndReplay() async throws {
    let cache = ThreadCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString),
                            key: SymmetricKey(size: .bits256))
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, cache: cache)
    model.start()
    let otherTransport = FakeTransport()
    let other = await connected(otherTransport)
    let file = MessageAttachment(name: "notes.txt", mime: "text/plain", data: "aGk=")
    let retained = event("retained", .message(MessageData(role: .user, text: "keep")))
    let prompt = event("edit", .message(MessageData(role: .user, text: "original", attachments: [file])))
    let reply = event("reply", .message(MessageData(role: .agent, text: "hidden", done: true)))
    let thread = ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1,
                               turnState: .idle, canRewind: true)
    for link in [transport, otherTransport] {
        await link.yield(.state(.paired))
        await link.yield(.ownerOnline(true))
        await link.yield(.compatibility(.compatible(version: 1, capabilities: ["thread-rewind-v1", "turn-state-v1"])))
        await link.yield(.event(event("threads", .threadList(ThreadListData(threads: [thread])))))
        await link.yield(.event(event("history", .syncDelta(SyncDeltaData(events: [retained, prompt, reply])))))
    }
    #expect(await eventually { model.canEditFromHere(prompt) && other.canEditFromHere(prompt) })
    model.editFromHere(prompt)
    let request = try #require(await sent(by: transport, payload: .threadRewind(ThreadRewindData(eventId: "edit")), in: "home"))
    #expect(model.events["home"]?.map(\.id) == ["retained", "edit", "reply"])
    #expect(model.drafts["home"] == nil)
    #expect(!model.canEditFromHere(prompt))
    let marker = event("rewind", .threadRewound(ThreadRewoundData(requestId: request.id,
        eventId: "edit", hiddenEventIds: ["edit", "reply"])))
    for link in [transport, otherTransport] { await link.yield(.event(marker)) }
    #expect(await eventually { model.drafts["home"] == "original" && other.drafts["home"] == "original" })
    for client in [model, other] {
        #expect(client.events["home"]?.map(\.id) == ["retained"])
        #expect(client.attachments["home"] == [file])
    }
    await transport.yield(.event(event("late-changes", .turnChanges(TurnChangesData(
        turnEventId: "edit", files: [.init(path: "old.txt", added: 1, removed: 0)])))))
    model.drafts["home"] = "edited draft"
    await transport.yield(.event(event("replay", .syncDelta(SyncDeltaData(events: [retained, prompt, reply, marker])))))
    #expect(await eventually { model.syncRevision >= 2 })
    #expect(model.events["home"]?.map(\.id) == ["retained"])
    #expect(model.drafts["home"] == "edited draft")
    await model.flushCache()
    model.close()
    other.close()
    let restored = ChatModel(transport: FakeTransport(), cache: cache)
    #expect(restored.events["home"]?.map(\.id) == ["retained"])
    #expect(restored.drafts["home"] == "edited draft")
    #expect(restored.attachments["home"] == [file])
    restored.close()
}

@MainActor
@Test func editFromHereRequiresCapabilityAndIdleHostAndHandlesRejection() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    let prompt = event("edit", .message(MessageData(role: .user, text: "original")))
    await transport.yield(.event(prompt))
    #expect(await eventually { model.events["home"]?.contains(prompt) == true })
    #expect(!model.canEditFromHere(prompt))
    model.editFromHere(prompt)
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["thread-rewind-v1", "turn-state-v1"])))
    var thread = ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1,
                               activeEventId: "running", turnState: .running, canRewind: true)
    await transport.yield(.event(event("running", .threadList(ThreadListData(threads: [thread])))))
    #expect(await eventually { model.generating.contains("home") })
    #expect(!model.canEditFromHere(prompt))
    model.editFromHere(prompt)
    #expect(await transport.sent.allSatisfy { $0.payload.kind != .threadRewind })
    thread.turnState = .idle
    thread.activeEventId = nil
    await transport.yield(.event(event("idle", .threadList(ThreadListData(threads: [thread])))))
    #expect(await eventually { model.canEditFromHere(prompt) })
    model.editFromHere(prompt)
    let request = try #require(await sent(by: transport, payload: .threadRewind(ThreadRewindData(eventId: "edit")), in: "home"))
    await transport.yield(.event(event("rejected", .threadRewound(ThreadRewoundData(
        requestId: request.id, eventId: "edit", reason: "Wait for this thread to finish working.")))))
    #expect(await eventually { model.failure == "Wait for this thread to finish working." })
    #expect(model.events["home"] == [prompt])
    #expect(model.drafts["home"] == nil)
    #expect(model.canEditFromHere(prompt))
}

@MainActor
@Test func rewindBeforeHistoryDownloadsOriginalAttachmentsIntoComposer() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["thread-rewind-v1", "attachment-chunks-v1"])))
    let bytes = Data("hello".utf8)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let file = MessageAttachment(name: "notes.txt", mime: "text/plain", data: "", sizeBytes: bytes.count, sha256: hash)
    let prompt = event("edit", .message(MessageData(role: .user, text: "original", attachments: [file])))
    let marker = event("rewind", .threadRewound(ThreadRewoundData(requestId: "remote", eventId: "edit", hiddenEventIds: ["edit"])))
    await transport.yield(.event(marker))
    await transport.yield(.event(event("history", .syncDelta(SyncDeltaData(events: [prompt, marker])))))
    #expect(await sent(by: transport, payload: .attachmentDownloadRequest(AttachmentDownloadRequestData(
        messageId: "edit", index: 0, offset: 0)), in: "home") != nil)
    await transport.yield(.event(event("bytes", .attachmentDownloadChunk(AttachmentDownloadChunkData(
        messageId: "edit", index: 0, offset: 0, totalBytes: bytes.count, data: bytes.base64EncodedString(), sha256: hash)))))
    #expect(await eventually { model.drafts["home"] == "original" })
    #expect(model.events["home"] == [])
    #expect(model.attachments["home"]?.first?.bytes == bytes)
}

@MainActor
@Test func syncedRewindThatTheConversationMovedPastLeavesTheComposerAlone() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["thread-rewind-v1"])))
    let prompt = event("edit", .message(MessageData(role: .user, text: "original")))
    let marker = event("rewind", .threadRewound(ThreadRewoundData(requestId: "remote", eventId: "edit", hiddenEventIds: ["edit"])))
    var resent = event("resent", .message(MessageData(role: .user, text: "edited")))
    resent.ts = marker.ts + 1
    await transport.yield(.event(event("history", .syncDelta(SyncDeltaData(events: [prompt, marker, resent])))))
    #expect(await eventually { model.events["home"]?.map(\.id) == ["resent"] })
    #expect((model.drafts["home"] ?? "").isEmpty)
}

@MainActor
@Test func queuedRowsStayAtEndAcrossRelaunchAndMoveOnceOnDelivery() async throws {
    let cache = ThreadCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString), key: SymmetricKey(size: .bits256))
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let transport = FakeTransport()
    let model = ChatModel(transport: transport, cache: cache)
    model.start()
    let summary = ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 10,
        activeEventId: "active", turnState: .running, queuedTurnCount: 2, queuedEventIds: ["next", "later"])
    let next = YorozuEvent(id: "next", threadId: "home", ts: 2, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "next")))
    let later = YorozuEvent(id: "later", threadId: "home", ts: 3, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "later")))
    let reply = YorozuEvent(id: "reply", threadId: "home", ts: 4, agentId: "main",
        payload: .message(MessageData(role: .agent, text: "finished", done: true)))
    await transport.yield(.event(event("list", .threadList(ThreadListData(threads: [summary])))))
    await transport.yield(.event(event("sync", .syncDelta(SyncDeltaData(events: [next, later, reply])))))
    #expect(await eventually { model.rows(in: "home").map(\.id) == ["reply", "next", "later"] })
    let statuses = model.queuedMessageStatuses(in: "home", queued: model.queuedMessages(in: "home"))
    #expect(statuses["next"] == "Next")
    #expect(statuses["later"] == "Sends when the turn ends")
    await model.flushCache()
    await model.shutdown()

    let replay = FakeTransport()
    let restored = ChatModel(transport: replay, cache: cache)
    #expect(restored.rows(in: "home").map(\.id) == ["reply", "next", "later"])
    #expect(restored.queuedMessages(in: "home").map(\.id) == ["next", "later"])
    restored.start()
    var starting = summary
    starting.activeEventId = "next"
    starting.turnState = .starting
    starting.queuedEventIds = ["later"]
    starting.queuedTurnCount = 1
    await replay.yield(.event(event("starting", .threadList(ThreadListData(threads: [starting])))))
    #expect(await eventually {
        restored.queuedMessageStatuses(in: "home", queued: restored.queuedMessages(in: "home"))["next"] == "Sending…"
    })
    var ordered = next
    ordered.clientTs = next.ts
    ordered.ts = 5
    let output = YorozuEvent(id: "output", threadId: "home", ts: 6, agentId: "main",
        payload: .message(MessageData(role: .agent, text: "next reply", done: true)))
    await replay.yield(.event(ordered))
    await replay.yield(.event(output))
    #expect(await eventually { restored.rows(in: "home").map(\.id) == ["reply", "next", "output", "later"] })
    // Old sync pages and a duplicated queue summary cannot move a delivered message again.
    await replay.yield(.event(event("old-list", .threadList(ThreadListData(threads: [summary])))))
    await replay.yield(.event(event("old-page", .syncDelta(SyncDeltaData(events: [next, ordered, next])))))
    await replay.yield(.event(event("barrier", .receipt(ReceiptData(eventId: "unused")))))
    #expect(await eventually { restored.threads.first?.activeEventId == "active" })
    #expect(restored.rows(in: "home").map(\.id) == ["reply", "next", "output", "later"])
    #expect(restored.queuedMessages(in: "home").map(\.id) == ["later"])
    await restored.shutdown()
}

@MainActor
@Test func removeUnsentQueueRestoresTextAndAttachmentsAcrossRelaunch() async throws {
    let cache = ThreadCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString), key: SymmetricKey(size: .bits256))
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let model = ChatModel(transport: FakeTransport(), cache: cache)
    let thread = model.newDraft()
    let file = MessageAttachment(name: "notes.txt", mime: "text/plain", data: "YQ==")
    model.drafts[thread.id] = "queued prompt"
    model.attachments[thread.id] = [file]
    model.send(in: thread)
    let queued = try #require(model.queuedMessages(in: thread.id).first)
    model.drafts[thread.id] = "new draft"
    model.withdraw(queued.id)
    #expect(model.drafts[thread.id] == "new draft\n\nqueued prompt")
    #expect(model.attachments[thread.id] == [file])
    #expect(model.rows(in: thread.id).isEmpty)
    #expect(model.events[thread.id]?.contains { if case .message(let data) = $0.payload { data.role == .agent } else { false } } == false)
    await model.flushCache()
    await model.shutdown()
    let restored = ChatModel(transport: FakeTransport(), cache: cache)
    restored.withdraw(queued.id)
    #expect(restored.drafts[thread.id] == "new draft\n\nqueued prompt")
    #expect(restored.attachments[thread.id] == [file])
    #expect(restored.rows(in: thread.id).isEmpty)
    await restored.shutdown()
}

@MainActor
@Test func openCardsHoldQueuedMessagesUntilAnswersArriveThenSendInOrder() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["turn-state-v1"])))
    await transport.yield(.event(event("list", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1,
            activeEventId: "active", turnState: .running)
    ])))))
    await transport.yield(.event(event("approval", .approvalCard(ApprovalCardData(
        actionId: "approve", actionClass: "run-command", target: "echo hello")))))
    await transport.yield(.event(event("question", .questionCard(QuestionCardData(
        questionId: "question", question: "Which?", options: ["A"])))))
    #expect(await eventually { model.pendingComposerCards(in: "home").count == 2 })
    let file = MessageAttachment(name: "notes.txt", mime: "text/plain", data: "YQ==")
    model.send("first", in: "home", attachment: file)
    model.send("second", in: "home")
    let ids = model.queuedMessages(in: "home").map(\.id)
    model.send("other thread", in: "other")
    #expect(await eventually { await transport.sent.contains { $0.threadId == "other" && $0.payload.kind == .message } })
    #expect(await transport.sent.filter { $0.threadId == "home" && $0.payload.kind == .message }.isEmpty)
    #expect(await transport.sent.contains { $0.threadId == "other" && $0.payload.kind == .message })

    model.answer("approve", in: "home", .yes)
    let approval = try #require(await sent(by: transport, payload: .approvalAnswer(ApprovalAnswerData(actionId: "approve", answer: .yes)), in: "home"))
    await transport.yield(.event(event("applied", .approvalStatus(ApprovalStatusData(
        requestId: approval.id, actionId: "approve", status: .applied)))))
    #expect(await eventually { !model.approvalPending("approve") })
    #expect(await transport.sent.filter { $0.threadId == "home" && $0.payload.kind == .message }.isEmpty)
    model.answerQuestion("question", in: "home", "A")
    let answer = try #require(await sent(by: transport, payload: .questionAnswer(QuestionAnswerData(questionId: "question", answer: "A")), in: "home"))
    #expect(await transport.sent.filter { $0.threadId == "home" && $0.payload.kind == .message }.isEmpty)
    await transport.yield(.event(event("answer-receipt", .receipt(ReceiptData(eventId: answer.id)))))
    #expect(await eventually { await transport.sent.contains { $0.id == ids[0] } })
    #expect(model.queuedMessageStatuses(in: "home", queued: model.queuedMessages(in: "home"))[ids[0]] == "Sending…")
    #expect(await transport.sent.filter { $0.threadId == "home" && $0.payload.kind == .message }.map(\.id) == [ids[0]])
    await transport.yield(.event(event("first-receipt", .receipt(ReceiptData(eventId: ids[0])))))
    #expect(await eventually { await transport.sent.contains { $0.id == ids[1] } })
    let delivered = await transport.sent.filter { $0.threadId == "home" && $0.payload.kind == .message }
    #expect(delivered.map(\.id) == ids)
    if case .message(let data) = delivered[0].payload { #expect(data.attachments == [file]) }
    else { Issue.record("Expected attached message") }
}

@MainActor
@Test func failedOutboxMessageKeepsFailureCaptionAndTimelinePosition() throws {
    let cache = ThreadCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString),
        key: SymmetricKey(size: .bits256))
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let thread = ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1,
        activeEventId: "active", turnState: .running, queuedTurnCount: 1, queuedEventIds: ["failed"])
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let message = YorozuEvent(id: "failed", threadId: thread.id, ts: now, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "try again",
            admissionDeadline: now + 30 * 60_000)))
    let reply = YorozuEvent(id: "reply", threadId: thread.id, ts: now + 1, agentId: "main",
        payload: .message(MessageData(role: .agent, text: "done", done: true)))
    cache.save(threads: [thread])
    cache.save(events: [message, reply], threadId: thread.id)
    try cache.savePending([OutboxItem(event: message, tries: Outbox.maxTries)])
    let model = ChatModel(transport: FakeTransport(), cache: cache)

    #expect(model.outboxStatus(of: message.id) == .failed)
    #expect(model.queuedMessages(in: thread.id).isEmpty)
    #expect(model.rows(in: thread.id).map(\.id) == [message.id, reply.id])
}

@MainActor
@Test func openClawPickerRequiresCapabilityAndCommitsOnlyHostConfirmedChoices() async throws {
    let transport = FakeTransport(autoReceipt: true)
    let otherTransport = FakeTransport()
    let model = await connected(transport)
    let other = await connected(otherTransport)
    defer { model.close(); other.close() }
    let thread = ThreadSummary(id: "home", title: "OpenClaw", archived: false, lastActivity: 1)
    #expect(!model.offersChannelModels(for: thread))
    await transport.yield(.event(event("capability", .modelList(ModelListData(models: [], channelCapabilities: ["model-select-v1"])))))
    await transport.yield(.event(event("threads", .threadList(ThreadListData(threads: [thread])))))
    #expect(await eventually { model.offersChannelModels(for: thread) && model.threads == [thread] })
    let native = ThreadSummary(id: "code", title: "Code", archived: false, lastActivity: 1, agent: .codex)
    #expect(!model.offersChannelModels(for: native))
    model.refreshChannelModels(in: thread)
    let refresh = try #require(await sent(by: transport, payload: .threadModelsRequest(ThreadModelsRequestData()), in: thread.id))
    let catalog = [ChannelModelOption(id: "p/allowed", label: "Allowed", available: true),
                   ChannelModelOption(id: "p/offline", label: "Offline", available: false, unavailableReason: "No provider")]
    await transport.yield(.event(event("catalog", .threadModels(ThreadModelsData(requestId: refresh.id, models: catalog)))))
    #expect(await eventually { model.channelModels[thread.id] == catalog })
    model.setModel(thread, "p/offline")
    #expect(!model.channelModelPending.contains(thread.id))
    model.setModel(thread, "forbidden")
    #expect(!model.channelModelPending.contains(thread.id))
    model.setModel(thread, "p/allowed")
    #expect(model.threads.first?.model == nil)
    let pick = try #require(await sent(by: transport, payload: .threadSetModel(ThreadSetModelData(model: "p/allowed")), in: thread.id))
    await transport.yield(.event(event("rejected", .threadModels(ThreadModelsData(requestId: pick.id, error: "Gateway refused")))))
    #expect(await eventually { model.channelModelErrors[thread.id] == "Gateway refused" && !model.channelModelPending.contains(thread.id) })
    #expect(model.threads.first?.model == nil)
    var confirmed = thread
    confirmed.model = "p/allowed"
    let synced = event("confirmed", .threadList(ThreadListData(threads: [confirmed])))
    await transport.yield(.event(synced))
    await otherTransport.yield(.event(synced))
    #expect(await eventually { model.threads.first?.model == "p/allowed" && other.threads.first?.model == "p/allowed" })
    model.setModel(confirmed, nil)
    #expect(model.threads.first?.model == "p/allowed")
    let clear = try #require(await sent(by: transport, payload: .threadSetModel(ThreadSetModelData(model: nil)), in: thread.id))
    await transport.yield(.event(event("cleared", .threadModels(ThreadModelsData(requestId: clear.id)))))
    let defaults = event("default", .threadList(ThreadListData(threads: [thread])))
    await transport.yield(.event(defaults))
    await otherTransport.yield(.event(defaults))
    #expect(await eventually { model.threads.first?.model == nil && other.threads.first?.model == nil })
    model.refreshChannelModels(in: thread)
    #expect(await eventually { await transport.sent.filter { $0.payload.kind == .threadModelsRequest }.count == 2 })
    await transport.yield(.event(event("old-plugin", .modelList(ModelListData(models: [])))))
    #expect(await eventually { !model.offersChannelModels(for: thread) })
}

@MainActor
@Test func openClawDraftChoiceTravelsWithFirstMessageAndSurvivesDisconnect() async throws {
    let cache = ThreadCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString),
                            key: SymmetricKey(size: .bits256))
    var transport = FakeTransport(autoReceipt: true)
    var model = ChatModel(transport: transport, cache: cache)
    await transport.yield(.state(.paired))
    await transport.yield(.ownerOnline(true))
    model.start()
    #expect(await eventually { model.canDeliver })
    defer { model.close() }
    await transport.yield(.event(event("capability", .modelList(ModelListData(models: [], channelCapabilities: ["model-select-v1"])))))
    #expect(await eventually { model.channelModelSelection })
    let draft = model.newDraft()
    #expect(model.offersChannelModels(for: draft))
    #expect(draft.model == nil)
    model.refreshChannelModels(in: draft)
    let refresh = try #require(await sent(by: transport, payload: .threadModelsRequest(ThreadModelsRequestData()), in: draft.id))
    await transport.yield(.event(event("catalog", .threadModels(ThreadModelsData(requestId: refresh.id,
        models: [ChannelModelOption(id: "p/model", label: "Model", available: true)])), thread: draft.id)))
    #expect(await eventually { model.channelModels[draft.id]?.count == 1 })
    model.setModel(draft, "p/model")
    #expect(model.draft?.model == "p/model")
    #expect(await transport.sent.filter { $0.payload.kind == .threadSetModel }.isEmpty)
    await model.flushCache()
    await model.shutdown()
    transport = FakeTransport(autoReceipt: true)
    model = ChatModel(transport: transport, cache: cache)
    #expect(model.draft?.model == "p/model")
    await transport.yield(.state(.paired))
    await transport.yield(.ownerOnline(true))
    model.start()
    #expect(await eventually { model.canDeliver })
    await transport.yield(.event(event("disconnected", .modelList(ModelListData(models: [], channelCapabilities: [])))))
    #expect(await eventually { !model.channelModelSelection })
    model.send("first", in: draft.id, attachment: MessageAttachment(name: "note.txt", mime: "text/plain", data: Data("note".utf8).base64EncodedString()))
    #expect(await eventually { await transport.sent.contains { $0.threadId == draft.id && $0.payload.kind == .message } })
    let first = try #require(await transport.sent.first { $0.threadId == draft.id && $0.payload.kind == .message })
    guard case .message(let message) = first.payload else { Issue.record("Missing message"); return }
    #expect(message.channelModel == ChannelModelChoice(model: "p/model"))
    #expect(message.attachments.first?.name == "note.txt")
    #expect(await transport.sent.filter { $0.payload.kind == .threadSetModel }.isEmpty)
    await transport.yield(.event(event("reconnected", .modelList(ModelListData(models: [], channelCapabilities: ["model-select-v1"])))))
    #expect(await eventually { model.channelModelSelection })
    let next = model.newDraft()
    #expect(next.model == nil)
    model.send("default", in: next.id)
    #expect(await eventually { await transport.sent.contains { $0.threadId == next.id && $0.payload.kind == .message } })
    let defaultMessage = try #require(await transport.sent.first { $0.threadId == next.id && $0.payload.kind == .message })
    guard case .message(let data) = defaultMessage.payload else { Issue.record("Missing message"); return }
    #expect(data.channelModel == ChannelModelChoice(model: nil))
    let wire = try JSONEncoder().encode(defaultMessage)
    #expect(try JSONDecoder().decode(YorozuEvent.self, from: wire) == defaultMessage)
}

@MainActor
@Test func followUpSettingAndAlternateSendChooseDelivery() throws {
    let key = ChatModel.followUpBehaviorKey
    let saved = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(saved, forKey: key) }
    UserDefaults.standard.removeObject(forKey: key)
    let model = ChatModel(transport: FakeTransport())
    let thread = model.newDraft()
    #expect(model.followUpBehavior == .queue)
    for (setting, alternate, expected) in [(MessageDelivery.queue, false, MessageDelivery.queue),
        (.queue, true, .steer), (.steer, false, .steer), (.steer, true, .queue)] {
        model.followUpBehavior = setting
        model.drafts[thread.id] = "follow \(setting) \(alternate)"
        model.send(in: thread, alternateDelivery: alternate)
        let sent = try #require(model.outbox.last)
        guard case .message(let message) = sent.event.payload else { Issue.record("Missing message"); return }
        #expect(message.delivery == expected)
        let wire = try JSONDecoder().decode(YorozuEvent.self, from: JSONEncoder().encode(sent.event))
        #expect(wire == sent.event)
    }
    #expect(ChatModel(transport: FakeTransport()).followUpBehavior == .steer)
}

@MainActor
@Test func sendNowAndShortcutAwaitHostDeliveryAndKeepFallbackQueued() async throws {
    let transport = FakeTransport(autoReceipt: true)
    let model = await connected(transport)
    defer { model.close() }
    let next = event("next", .message(MessageData(role: .user, text: "next", delivery: .queue)))
    let later = event("later", .message(MessageData(role: .user, text: "later", delivery: .queue)))
    var summary = ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 10,
        activeEventId: "active", turnState: .running, queuedTurnCount: 2, queuedEventIds: ["next", "later"])
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["turn-state-v1"])))
    await transport.yield(.event(event("list", .threadList(ThreadListData(threads: [summary])))))
    await transport.yield(.event(event("sync", .syncDelta(SyncDeltaData(events: [next, later])))))
    #expect(await eventually { model.queuedMessages(in: "home").count == 2 })
    #expect(!model.canSendNow(next))
    #expect(!model.sendNextQueued(in: "home"))
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["turn-state-v1", "steer-v1"])))
    #expect(await eventually { model.canSendNow(next) })
    model.sendNow(next)
    #expect(await eventually { await transport.sent.contains { $0.payload == .steer(SteerData(targetEventId: "next")) } })
    // A fallback echo leaves the row queued, with the active turn's Stop untouched.
    await transport.yield(.event(next))
    #expect(await eventually { model.canSendNow(next) })
    #expect(model.queuedMessages(in: "home").map(\.id) == ["next", "later"])
    #expect(model.activeEventId(in: "home") == "active")
    #expect(!model.stopPending(in: "home"))
    #expect(model.sendNextQueued(in: "home"))
    #expect(await eventually { await transport.sent.filter { $0.payload == .steer(SteerData(targetEventId: "next")) }.count == 2 })
    var progress = event("progress", .message(MessageData(role: .agent, text: "working")))
    progress.ts = 10
    await transport.yield(.event(progress))
    var delivered = next
    delivered.ts = 20
    delivered.clientTs = next.ts
    delivered.payload = .message(MessageData(role: .user, text: "next", completionId: "active-reply", delivery: .steer))
    await transport.yield(.event(delivered))
    summary.queuedEventIds = ["later"]
    summary.queuedTurnCount = 1
    await transport.yield(.event(event("delivered", .threadList(ThreadListData(threads: [summary])))))
    #expect(await eventually { model.queuedMessages(in: "home").map(\.id) == ["later"] })
    #expect(model.activeEventId(in: "home") == "active")
    #expect(!model.canSendNow(delivered))
    #expect(!model.canWithdraw(delivered))
    var output = event("output", .message(MessageData(role: .agent, text: "adjusted")))
    output.ts = 30
    await transport.yield(.event(output))
    await transport.yield(.event(next)) // A stale queue echo cannot undo delivery placement.
    #expect(await eventually {
        model.events["home"]?.filter { ["progress", "next", "output"].contains($0.id) }.map(\.id)
            == ["progress", "next", "output"]
    })
    #expect(model.sendNextQueued(in: "home"))
    #expect(await eventually { await transport.sent.contains { $0.payload == .steer(SteerData(targetEventId: "later")) } })
    await transport.yield(.event(event("question", .questionCard(QuestionCardData(questionId: "q", question: "Which?", options: ["A"])))))
    #expect(await eventually { !model.canSendNow(later) })
    #expect(!model.sendNextQueued(in: "home"))
}

@MainActor
@Test func startingIsWaitingForOpenClawOnlyInYorozuThreads() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    var openClaw = ThreadSummary(id: "home", title: "OpenClaw", archived: false, lastActivity: 1,
        activeEventId: "m1", turnState: .starting)
    var native = ThreadSummary(id: "code", title: "Code", archived: false, lastActivity: 1, agent: .codex,
        activeEventId: "m2", turnState: .starting)
    await transport.yield(.event(event("threads", .threadList(ThreadListData(threads: [openClaw, native])))))
    #expect(await eventually { model.isWaitingForOpenClaw(in: "home") })
    #expect(!model.isWaitingForOpenClaw(in: "code"))
    openClaw.turnState = .running
    native.turnState = .starting
    await transport.yield(.event(event("running", .threadList(ThreadListData(threads: [openClaw, native])))))
    #expect(await eventually { !model.isWaitingForOpenClaw(in: "home") })
}

@MainActor
@Test func outdatedPluginNoticeAppearsOncePerHostSession() async throws {
    let transport = FakeTransport()
    let model = await connected(transport)
    defer { model.close() }
    // No plugin, or a current one: nothing to say.
    await transport.yield(.event(event("none", .modelList(ModelListData(models: [], channelCapabilities: [])))))
    await transport.yield(.event(event("current", .modelList(ModelListData(models: [], channelCapabilities: [
        "run-boundary-v1", "progress-v1", "model-select-v1", "media-v1"])))))
    await transport.yield(.event(event("sync", .modelList(ModelListData(models: [], channelCapabilities: ["run-boundary-v1", "missing:progress-v1", "missing:media-v1"])))))
    #expect(await eventually { model.pluginNotice != nil })
    let notice = try #require(model.pluginNotice)
    #expect(notice.contains("progress") && notice.contains("attachments"))
    #expect(!notice.contains("Stop") && !notice.contains("model picker"))
    model.dismissPluginNotice()
    // The picker flag marks this list as applied; the notice stays spent.
    await transport.yield(.event(event("again", .modelList(ModelListData(models: [], channelCapabilities: ["model-select-v1", "missing:run-boundary-v1"])))))
    #expect(await eventually { model.channelModelSelection })
    #expect(model.pluginNotice == nil)
}
