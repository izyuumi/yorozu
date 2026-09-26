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
private func settle(attempts: Int = 300, _ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<attempts {
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
@Test func persistedStopGoesAheadOfQueuedMessagesAndWaitsForOutcome() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let ts = Int(Date().timeIntervalSince1970 * 1000)
    let later = YorozuEvent(id: "later", threadId: "home", ts: ts, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "later", admissionDeadline: ts + 30 * 60_000)))
    let stop = YorozuEvent(id: "stop-old", threadId: "home", ts: ts, agentId: "phone",
        payload: .interrupt(InterruptData(targetEventId: "running-old")))
    try cache.savePending([OutboxItem(event: later), OutboxItem(event: stop)])
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "phone")
    model.start()
    await reconnect(transport)
    for _ in 0..<300 {
        if await transport.sent.contains(where: { $0.id == stop.id }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.sent.filter { $0.threadId == "home" }.first?.id == stop.id)
    #expect(model.stopPending(in: "home"))
    #expect(await transport.messages.isEmpty)
    await transport.yield(.event(YorozuEvent(id: "stop-done", threadId: "", ts: ts, agentId: "main",
        payload: .stopStatus(StopStatusData(targetEventId: "running-old", requestId: stop.id, status: .stopped)))))
    #expect(await settle { !model.stopPending(in: "home") && model.outbox.isEmpty })
    #expect(await transport.sent.filter { $0.threadId == "home" }.map(\.id) == [stop.id, later.id])
}

@MainActor
@Test func uncertainStopWarningSurvivesClientRelaunch() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "phone")
    model.start()
    await transport.yield(.event(YorozuEvent(id: "threads", threadId: "", ts: 1, agentId: "main",
        payload: .threadList(ThreadListData(threads: [
            ThreadSummary(id: "home", title: "Home", archived: false, lastActivity: 1, activeEventId: "running")
        ])))))
    #expect(await settle { model.activeEventId(in: "home") == "running" })
    model.interrupt(in: "home")
    let stop = try #require(model.outbox.first { $0.event.payload == .interrupt(InterruptData(targetEventId: "running")) })
    await transport.yield(.event(YorozuEvent(id: "uncertain", threadId: "home", ts: 2, agentId: "main",
        payload: .stopStatus(StopStatusData(targetEventId: "running", requestId: stop.id, status: .unconfirmed)))))
    #expect(await settle { model.hasUnconfirmedStop(in: "home") && !model.stopPending(in: "home") })
    await model.flushCache()
    let restored = ChatModel(transport: QueueTransport(), cache: cache, device: "phone")
    #expect(restored.hasUnconfirmedStop(in: "home"))
}

@MainActor
@Test func offlineApprovalSurvivesRelaunchAndReceiptDoesNotClaimItApplied() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let offline = ChatModel(transport: QueueTransport(), cache: cache, device: "phone")
    offline.start()
    offline.answer("card-1", in: "home", .yes)
    let id = try #require(cache.outbox().first?.id)
    let transport = QueueTransport()
    let restored = ChatModel(transport: transport, cache: cache, device: "phone")
    restored.start()
    #expect(restored.approvalPending("card-1"))
    await reconnect(transport)
    var delivered = false
    for _ in 0..<300 where !delivered {
        delivered = await transport.sent.contains(where: { $0.id == id })
        if !delivered { try? await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(delivered)
    #expect(restored.approvalPending("card-1"))
    #expect(!restored.answered.contains("card-1"))
    await transport.yield(.event(YorozuEvent(id: "applied-card-1", threadId: "home", ts: 1, agentId: "main",
        payload: .approvalStatus(ApprovalStatusData(requestId: id, actionId: "card-1", status: .applied)))))
    #expect(await settle { restored.answered.contains("card-1") && !restored.approvalPending("card-1") })
    #expect(cache.outbox().isEmpty)
}

@MainActor
@Test func missedApprovalStatusReconcilesFromSyncHistory() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let offline = ChatModel(transport: QueueTransport(), cache: cache, device: "phone")
    offline.start()
    offline.answer("card-2", in: "home", .no)
    let id = try #require(cache.outbox().first?.id)
    let transport = QueueTransport()
    let restored = ChatModel(transport: transport, cache: cache, device: "phone")
    restored.start()
    await reconnect(transport)
    let status = YorozuEvent(id: "applied-card-2", threadId: "home", ts: 1, agentId: "main",
        payload: .approvalStatus(ApprovalStatusData(requestId: id, actionId: "card-2", status: .applied)))
    await transport.yield(.event(YorozuEvent(id: "sync-card-2", threadId: "", ts: 1, agentId: "main",
        payload: .syncDelta(SyncDeltaData(events: [status])))))
    #expect(await settle { !restored.approvalPending("card-2") && restored.answered.contains("card-2") })
    #expect(cache.outbox().isEmpty)
}

@MainActor
@Test func hostWithdrawalKeepsCancelledMessageAndNeverTransmitsIt() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let ts = Int(Date().timeIntervalSince1970 * 1000)
    let message = YorozuEvent(id: "withdraw-me", threadId: "home", ts: ts, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "cancel", admissionDeadline: ts + 30 * 60_000)))
    try cache.savePending([OutboxItem(event: message, attemptedAt: Date())])
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "phone")
    model.start()
    model.withdraw(message.id)
    let stop = try #require(model.outbox.last?.event)
    #expect(model.outboxStatus(of: message.id) == .withdrawalPending)
    await reconnect(transport)
    for _ in 0..<300 {
        if await transport.sent.contains(where: { $0.id == stop.id }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.messages.isEmpty)
    await transport.yield(.event(YorozuEvent(id: "withdrawn", threadId: "", ts: ts, agentId: "main",
        payload: .stopStatus(StopStatusData(targetEventId: message.id, requestId: stop.id, status: .withdrawn)))))
    #expect(await settle { model.outboxStatus(of: message.id) == .withdrawn && !model.stopPending(in: "home") })
    #expect(await transport.messages.isEmpty)
    #expect(cache.outbox().first?.admissionStatus == .withdrawn)
}

@MainActor
@Test func acceptedQueuedMessageCanStillBeWithdrawnByExactId() async throws {
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, device: "phone")
    model.start()
    model.send("queued behind another run", in: "home")
    let message = try #require(model.events["home"]?.first)
    await reconnect(transport)
    #expect(await settle { model.outboxStatus(of: message.id) == nil })
    #expect(model.canWithdraw(message))
    model.withdraw(message.id)
    let stop = try #require(model.outbox.last?.event)
    #expect(stop.payload == .interrupt(InterruptData(targetEventId: message.id)))
    #expect(await settle { model.stopPending(in: "home") })
}

@MainActor
@Test func neverAttemptedDraftCancelsLocallyWithItsThreadSetup() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "phone")
    model.start()
    let draft = model.newDraft()
    model.send("cancel offline", in: draft.id)
    let messageId = try #require(model.outbox.last?.id)
    model.withdraw(messageId)
    #expect(model.outboxStatus(of: messageId) == .withdrawn)
    #expect(cache.outbox().allSatisfy { $0.admissionStatus == .withdrawn })
    await reconnect(transport)
    try await Task.sleep(for: .milliseconds(50))
    #expect(await transport.sent.allSatisfy { $0.threadId != draft.id })
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
    for item in model.outbox {
        guard case .message(let data) = item.event.payload else { Issue.record("missing message"); return }
        #expect(data.admissionDeadline == item.event.ts + 30 * 60_000)
    }
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
@Test func unattemptedExpiredMessageNeedsFreshIdBeforeSending() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let ts = Int(Date().addingTimeInterval(-31 * 60).timeIntervalSince1970 * 1000)
    let original = YorozuEvent(id: "stale", threadId: "home", ts: ts, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "keep content",
            admissionDeadline: ts + 30 * 60_000)))
    try cache.savePending([OutboxItem(event: original)])
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "phone")
    model.start()
    #expect(model.outboxStatus(of: original.id) == .expired)
    await reconnect(transport)
    #expect(await transport.messages.isEmpty)
    model.stillSend(original.id)
    let renewed = try #require(model.outbox.last?.event)
    #expect(renewed.id != original.id)
    #expect(model.outboxStatus(of: original.id) == .resent)
    guard case .message(let data) = renewed.payload else { Issue.record("missing renewed message"); return }
    #expect(data.text == "keep content")
    #expect(data.admissionDeadline == renewed.ts + 30 * 60_000)
    #expect(await settle { model.outbox.count == 1 })
    #expect(await transport.messages.map(\.id) == [renewed.id])
}

@MainActor
@Test func offlineMessageBecomesExpiredAtDeadlineWithoutAConnectionEvent() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let ts = Int(Date().addingTimeInterval(-30 * 60 + 1).timeIntervalSince1970 * 1000)
    let message = YorozuEvent(id: "approaching-deadline", threadId: "home", ts: ts, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "offline",
            admissionDeadline: ts + 30 * 60_000)))
    try cache.savePending([OutboxItem(event: message)])
    let model = ChatModel(transport: QueueTransport(), cache: cache, device: "phone")
    model.start()
    #expect(model.outboxStatus(of: message.id) == .queued)
    #expect(await settle { model.outboxStatus(of: message.id) == .expired })
}

@MainActor
@Test func uncertainExpiredMessageQueriesHostBeforeStillSend() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let ts = Int(Date().addingTimeInterval(-31 * 60).timeIntervalSince1970 * 1000)
    let original = YorozuEvent(id: "uncertain", threadId: "home", ts: ts, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "one task",
            admissionDeadline: ts + 30 * 60_000)))
    try cache.savePending([OutboxItem(event: original, attemptedAt: Date().addingTimeInterval(-60))])
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "phone")
    model.start()
    #expect(model.outboxStatus(of: original.id) == .checking)
    model.stillSend(original.id)
    #expect(model.outbox.map(\.id) == [original.id])
    await reconnect(transport)
    var queried = false
    for _ in 0..<300 where !queried {
        queried = await transport.sent.contains(where: { $0.payload.kind == .admissionQuery })
        if !queried { try? await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(queried)
    #expect(await transport.messages.isEmpty)
    let query = try #require(await transport.sent.first { $0.payload.kind == .admissionQuery })
    await transport.yield(.event(YorozuEvent(id: "expired-status", threadId: "", ts: 1, agentId: "main",
        payload: .admissionStatus(AdmissionStatusData(eventId: original.id, status: .expired,
            reason: "admission-deadline", requestId: query.id)))))
    #expect(await settle { model.outboxStatus(of: original.id) == .expired })
    model.stillSend(original.id)
    let renewed = try #require(model.outbox.last?.event)
    #expect(renewed.id != original.id)
    var delivered = false
    for _ in 0..<300 where !delivered {
        delivered = await transport.messages.map(\.id) == [renewed.id]
        if !delivered { try? await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(delivered)
    #expect(cache.outbox().first?.replacementId == renewed.id)
}

@Test func unknownRequiresFreshQueryAfterClockLeadWindow() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let ts = Int(now.addingTimeInterval(-31 * 60).timeIntervalSince1970 * 1000)
    let message = YorozuEvent(id: "clock-skew", threadId: "home", ts: ts, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "one task",
            admissionDeadline: ts + 30 * 60_000)))
    var item = OutboxItem(event: message, attemptedAt: now.addingTimeInterval(-60),
        admissionStatus: .unknown, lastStatusQueryAt: now)
    #expect(item.status(at: now) == .checking)
    let afterAllowance = now.addingTimeInterval(6 * 60)
    #expect(item.status(at: afterAllowance) == .checking)
    item.lastStatusQueryAt = afterAllowance
    #expect(item.status(at: afterAllowance) == .expired)
}

@MainActor
@Test func lateAcceptanceStatusClearsExpiredUncertaintyWithoutResending() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let ts = Int(Date().addingTimeInterval(-31 * 60).timeIntervalSince1970 * 1000)
    let original = YorozuEvent(id: "late-receipt", threadId: "home", ts: ts, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "accepted before expiry",
            admissionDeadline: ts + 30 * 60_000)))
    try cache.savePending([OutboxItem(event: original, attemptedAt: Date().addingTimeInterval(-31 * 60))])
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "phone")
    model.start()
    await reconnect(transport)
    await transport.yield(.event(YorozuEvent(id: "accepted-status", threadId: "", ts: 1, agentId: "main",
        payload: .admissionStatus(AdmissionStatusData(eventId: original.id, status: .queued,
            runId: "known-run")))))
    #expect(await settle { model.outbox.isEmpty })
    #expect(await transport.messages.isEmpty)
    #expect(cache.outbox().isEmpty)
}

@MainActor
@Test func oldCachedMessageWaitsForRelayDrainAndFreshHostStatus() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let ts = Int(Date().addingTimeInterval(-26 * 60 * 60).timeIntervalSince1970 * 1000)
    let old = YorozuEvent(id: "old-format", threadId: "home", ts: ts, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "maybe delivered")))
    try cache.savePending([OutboxItem(event: old, attemptedAt: Date().addingTimeInterval(-26 * 60 * 60),
        legacyHoldUntil: Date().addingTimeInterval(-60))])
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "phone")
    model.start()
    #expect(model.outboxStatus(of: old.id) == .checking)
    await reconnect(transport)
    var queried = false
    for _ in 0..<300 where !queried {
        queried = await transport.sent.contains(where: { $0.payload.kind == .admissionQuery })
        if !queried { try? await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(queried)
    #expect(await transport.messages.isEmpty)
    let query = try #require(await transport.sent.first { $0.payload.kind == .admissionQuery })
    await transport.yield(.event(YorozuEvent(id: "stale-unknown", threadId: "", ts: 1, agentId: "main",
        payload: .admissionStatus(AdmissionStatusData(eventId: old.id, status: .unknown,
            requestId: "pre-hold-query")))))
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.outboxStatus(of: old.id) == .checking)
    await transport.yield(.event(YorozuEvent(id: "unknown-status", threadId: "", ts: 1, agentId: "main",
        payload: .admissionStatus(AdmissionStatusData(eventId: old.id, status: .unknown,
            requestId: query.id)))))
    #expect(await settle { model.outboxStatus(of: old.id) == .expired })
    model.stillSend(old.id)
    #expect(await settle { model.outboxStatus(of: old.id) == .resent })
    #expect(await transport.messages.allSatisfy { $0.id != old.id })
}

@MainActor
@Test func renewedFirstMessageReactivatesExpiredThreadSetup() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let ts = Int(Date().addingTimeInterval(-49 * 60 * 60).timeIntervalSince1970 * 1000)
    let threadId = "old-draft"
    let create = YorozuEvent(id: "old-create", threadId: threadId, ts: ts, agentId: "phone",
        payload: .threadCreate(ThreadCreateData()))
    let setModel = YorozuEvent(id: "old-model", threadId: threadId, ts: ts, agentId: "phone",
        payload: .threadSetModel(ThreadSetModelData(model: "test-model")))
    let message = YorozuEvent(id: "old-message", threadId: threadId, ts: ts, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "draft",
            admissionDeadline: ts + 30 * 60_000)))
    try cache.savePending([OutboxItem(event: create), OutboxItem(event: setModel), OutboxItem(event: message)])
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "phone")
    model.start()
    model.stillSend(message.id)
    let renewedId = try #require(model.outbox.last?.id)
    await reconnect(transport)
    #expect(await settle { model.outbox.count == 1 })
    let sent = await transport.sent.filter { $0.threadId == threadId }
    #expect(sent.map(\.id) == [create.id, setModel.id, renewedId])
}

@MainActor
@Test func oldNeverAttemptedMessageMigratesToStillSendWithoutTransmittingOldId() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let old = YorozuEvent(id: "never-attempted", threadId: "home",
        ts: Int(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000), agentId: "phone",
        payload: .message(MessageData(role: .user, text: "preserve me")))
    try cache.savePending([OutboxItem(event: old)])
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "phone")
    model.start()
    #expect(model.outboxStatus(of: old.id) == .expired)
    await reconnect(transport)
    #expect(await transport.messages.isEmpty)
    model.stillSend(old.id)
    let newId = try #require(model.outbox.first?.replacementId)
    #expect(newId != old.id)
    #expect(await settle { model.outbox.count == 1 && model.outboxStatus(of: old.id) == .resent })
    #expect(await transport.messages.map(\.id) == [newId])
}

@MainActor
@Test func failedOutboxPersistenceKeepsComposerAndDoesNotQueueAPhantomMessage() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory.appending(path: "outbox.bin"), withIntermediateDirectories: true)
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "phone")
    model.start()
    await reconnect(transport)
    #expect(await settle { model.canDeliver })
    let thread = model.newDraft()
    let attachment = MessageAttachment(name: "proof.txt", mime: "text/plain", data: "aGk=")
    model.drafts[thread.id] = "hello"
    model.attachments[thread.id] = [attachment]

    model.send(in: thread)
    #expect(model.drafts[thread.id] == "hello")
    #expect(model.attachments[thread.id] == [attachment])
    #expect(model.isDraft(thread.id))
    #expect(model.outbox.isEmpty)
    #expect(model.events[thread.id]?.isEmpty ?? true)
    #expect(model.failure?.contains("Could not save pending messages") == true)
    #expect(cache.composer()?.drafts[thread.id] == "hello")
    #expect(cache.composer()?.attachments[thread.id] == [attachment])
    #expect(await transport.messages.isEmpty)

    await transport.yield(.ownerOnline(false))
    #expect(await settle { !model.canDeliver })
    try FileManager.default.removeItem(at: directory.appending(path: "outbox.bin"))
    model.send(in: thread)
    #expect(model.drafts[thread.id] == "")
    #expect(model.attachments[thread.id] == nil)
    #expect(!model.isDraft(thread.id))
    #expect(model.outbox.map(\.event.payload.kind) == [.threadCreate, .message])
    #expect(model.failure == nil)
}

@MainActor
@Test func preparedSendRestoresDraftOnlyWhenOutboxDidNotCommit() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let thread = ThreadSummary(id: "new-thread", title: "New chat", archived: false, lastActivity: 1)
    let message = YorozuEvent(id: "prepared-message", threadId: thread.id, ts: 1, agentId: "phone",
                              payload: .message(MessageData(role: .user, text: "hello")))
    let create = YorozuEvent(id: "prepared-create", threadId: thread.id, ts: 1, agentId: "phone",
                             payload: .threadCreate(ThreadCreateData()))
    let prepared = ThreadCache.ComposerState(drafts: [thread.id: "hello"], attachments: [:],
                                             threads: [thread], knownThreads: nil, openThread: thread.id,
                                             preparedSend: [thread.id: message.id])

    // Crash before outbox write: original draft remains usable.
    try cache.save(composer: prepared)
    let notCommitted = ChatModel(transport: QueueTransport(), cache: cache)
    #expect(notCommitted.drafts[thread.id] == "hello")
    #expect(notCommitted.isDraft(thread.id))

    // Crash after outbox write but before composer clear: one queued operation owns input.
    try cache.save(composer: prepared)
    try cache.savePending([OutboxItem(event: create), OutboxItem(event: message)])
    let committed = ChatModel(transport: QueueTransport(), cache: cache)
    #expect(committed.drafts[thread.id] == "")
    #expect(!committed.isDraft(thread.id))
    #expect(committed.outbox.map(\.id) == [create.id, message.id])
    #expect(cache.composer()?.drafts[thread.id] == "")
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
@Test func threadCreationReceiptPrecedesItsFirstMessage() async throws {
    let transport = QueueTransport()
    await transport.swallow(true)
    let model = ChatModel(transport: transport, device: "phone")
    model.start()
    let draft = model.newDraft()
    model.send("first", in: draft.id)
    let ids = model.outbox.map(\.id)
    await reconnect(transport)
    #expect(await settle { model.outbox.first?.deliveryAttempts == 1 })
    #expect(await transport.sent.filter { $0.threadId == draft.id }.map(\.id) == [ids[0]])

    await transport.yield(.event(YorozuEvent(id: "receipt-create", threadId: "", ts: 1, agentId: "main",
                                            payload: .receipt(ReceiptData(eventId: ids[0])))))
    var sent: [String] = []
    for _ in 0..<300 where sent.count < 2 {
        sent = await transport.sent.filter { $0.threadId == draft.id }.map(\.id)
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(sent == ids)
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
@Test func lostReceiptAndThreeTransportErrorsKeepRetrying() async throws {
    let transport = QueueTransport()
    await transport.swallow(true)
    let model = ChatModel(transport: transport, device: "phone")
    model.start()
    await reconnect(transport)
    #expect(await settle { model.canDeliver })

    model.send("hi", in: "home")
    let id = try #require(model.outbox.first?.id)
    #expect(await settle { model.outboxStatus(of: id) == .confirming })
    var sent = 0
    for _ in 0..<300 where sent == 0 {
        sent = await transport.messages.count
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(sent == 1)
    await transport.refuse(true)

    // The first send may have reached the host. Later transport errors cannot prove otherwise.
    #expect(await settle(attempts: 1_200) { (model.outbox.first?.tries ?? 0) >= 3 })
    #expect(model.outboxStatus(of: id) == .unconfirmed)
    #expect((model.outbox.first?.tries ?? 0) >= Outbox.maxTries)
    #expect(await transport.messages.map(\.id) == [id])

    // Retry continues automatically past the presentation threshold, using the same ID.
    await transport.refuse(false)
    await transport.swallow(false)
    #expect(await settle(attempts: 1_800) { model.outbox.isEmpty })
    // Reconnect may resend before its receipt arrives; runtime dedupes the stable event ID.
    #expect(await Set(transport.messages.map(\.id)) == [id])
}

@MainActor
@Test func missingReceiptRetriesSameMessageWhileSocketStaysHealthy() async throws {
    let transport = QueueTransport()
    await transport.swallow(true)
    let model = ChatModel(transport: transport, device: "phone")
    model.start()
    await reconnect(transport)
    #expect(await settle { model.canDeliver })

    model.send("keep trying", in: "home")
    let id = try #require(model.outbox.first?.id)
    var count = 0
    for _ in 0..<400 where count < 2 {
        count = await transport.messages.count
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(count >= 2)
    #expect(await Set(transport.messages.map(\.id)) == [id])
    #expect(model.outboxStatus(of: id) == .confirming)
    #expect(model.outbox.first?.deliveryAttempts == 2)
    #expect(model.outbox.first?.nextAttemptAt != nil)
}

@MainActor
@Test func expiredMessageDoesNotBlockFreshWorkInSameThread() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let oldTimestamp = Int(Date().addingTimeInterval(-31 * 60).timeIntervalSince1970 * 1_000)
    let freshTimestamp = Int(Date().timeIntervalSince1970 * 1_000)
    let old = YorozuEvent(id: "old", threadId: "home",
                          ts: oldTimestamp,
                          agentId: "phone", payload: .message(MessageData(role: .user, text: "old",
                              admissionDeadline: oldTimestamp + 30 * 60_000)))
    let fresh = YorozuEvent(id: "fresh", threadId: "home",
                            ts: freshTimestamp,
                            agentId: "phone", payload: .message(MessageData(role: .user, text: "fresh",
                                admissionDeadline: freshTimestamp + 30 * 60_000)))
    try cache.savePending([OutboxItem(event: old), OutboxItem(event: fresh)])
    let transport = QueueTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "phone")
    model.start()
    await reconnect(transport)
    #expect(await settle { model.outbox.map(\.id) == ["old"] })
    #expect(await transport.messages.map(\.id) == ["fresh"])
    #expect(model.outbox.first?.status == .expired)
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
    // Reconnect may resend before its receipt arrives; runtime dedupes the stable event ID.
    #expect(await Set(transport.messages.map(\.id)) == [id])
    // And the flushed queue is written back, so a third launch does not send it again.
    #expect(cache.outbox().isEmpty)
}

@MainActor
@Test func aMessageSentOnAHalfOpenSocketRemainsUnconfirmedAfterRelaunch() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: .init(size: .bits256))
    let transport = QueueTransport()
    await transport.swallow(true)
    let model = ChatModel(transport: transport, cache: cache, device: "phone")
    model.start()
    await reconnect(transport)
    #expect(await settle { model.canDeliver })

    // The link looks fine, but socket delivery is not host acceptance.
    model.send("hi", in: "home")
    let id = try #require(model.outbox.first?.id)
    var count = 0
    for _ in 0..<300 where count == 0 {
        count = await transport.messages.count
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(count == 1)
    #expect(model.outboxStatus(of: id) == .confirming)
    // But the runtime never said it had it, so it is still ours to deliver.
    #expect(model.outbox.map(\.id) == [id])

    await transport.yield(.ownerOnline(false))
    #expect(await settle { !model.canDeliver })
    await reconnect(transport)
    for _ in 0..<300 where count < 2 {
        count = await transport.messages.count
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.messages.map(\.id) == [id, id])

    // App relaunch keeps uncertainty and retries the same operation ID.
    await model.shutdown()
    let restoredTransport = QueueTransport()
    let restored = ChatModel(transport: restoredTransport, cache: cache, device: "phone")
    restored.start()
    #expect(restored.outboxStatus(of: id) == .confirming)
    await reconnect(restoredTransport)
    #expect(await settle { restored.outbox.isEmpty })
    #expect(await restoredTransport.messages.map(\.id) == [id])
}

@Test func theQueueStopsTryingAfterTwoDaysWithoutDroppingUnsentMessages() {
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

    let many = (0..<60).map { item("m\($0)", hoursAgo: Double(60 - $0)) }
    let capped = Outbox.pruned(many, now: now)
    #expect(capped.count == 60)
    #expect(capped.first?.id == "m0")
    #expect(capped.last?.id == "m59")
}
