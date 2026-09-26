import CryptoKit
import Foundation
import Testing

@testable import YorozuShared

private actor MultiHostTransport: ChatTransport {
    private var updates: AsyncStream<TransportUpdate>.Continuation?
    private var held: [TransportUpdate] = []
    private(set) var sent: [YorozuEvent] = []
    private(set) var closes = 0

    func connect() -> AsyncStream<TransportUpdate> {
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        updates = continuation
        for update in held { continuation.yield(update) }
        held = []
        return stream
    }

    func send(_ event: YorozuEvent) async throws {
        sent.append(event)
        yield(.event(multiHostEvent("receipt-\(event.id)", .receipt(ReceiptData(eventId: event.id)))))
    }

    func close() {
        closes += 1
        updates?.finish()
        updates = nil
    }

    func yield(_ update: TransportUpdate) {
        if let updates { updates.yield(update) } else { held.append(update) }
    }

    func online() {
        yield(.state(.paired))
        yield(.ownerOnline(true))
    }
}

private func multiHostEvent(_ id: String, _ payload: YorozuEvent.Payload, thread: String = "same") -> YorozuEvent {
    YorozuEvent(id: id, threadId: thread, ts: 1, agentId: "main", payload: payload)
}

private func multiHostID(_ byte: UInt8) -> HostID {
    Data(repeating: byte, count: 32).base64URLEncodedString()
}

@MainActor
private func multiHostEventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// What one host sends on joining: the thread list, a sync, the devices, the rules and the update
/// status. Waiting for fewer leaves a frame still in flight to land after a
/// test has taken its "before" snapshot. Mirrors `pairingKinds` in ChatModelTests.
private let multiHostPairingSends = 5

private func multiHostSent(_ transport: MultiHostTransport, atLeast count: Int) async -> [YorozuEvent] {
    for _ in 0..<300 {
        let events = await transport.sent
        if events.count >= count { return events }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await transport.sent
}

@MainActor
private func multiHostSession(_ id: HostID, transport: MultiHostTransport, cache: ThreadCache? = nil,
    nickname: String? = nil) -> HostSession {
    let model = ChatModel(transport: transport, cache: cache)
    model.start()
    return HostSession(id: id, model: model, relayURL: "wss://relay.example", nickname: nickname)
}

@MainActor
@Test func restoredNavigationSelectsOnlyLastUsedHostsExistingThread() {
    let first = HostSession(id: multiHostID(0), model: ChatModel(transport: MultiHostTransport()), relayURL: "wss://relay.example")
    let second = HostSession(id: multiHostID(1), model: ChatModel(transport: MultiHostTransport()), relayURL: "wss://relay.example")
    let firstDraft = first.model.newDraft()
    let secondDraft = second.model.newDraft()
    first.model.openThread = firstDraft.id
    second.model.openThread = secondDraft.id
    let hosts = MultiHostModel(sessions: [first, second], lastUsedHostID: second.id)

    #expect(hosts.restoredOpenThread == HostThreadID(hostID: second.id, threadID: secondDraft.id))
    second.model.openThread = "removed"
    #expect(hosts.restoredOpenThread == nil)
    hosts.lastUsedHostID = "missing"
    #expect(hosts.restoredOpenThread == HostThreadID(hostID: first.id, threadID: firstDraft.id))
}

@MainActor
@Test func multiHostThreadsKeepCollidingIDsSeparateAndSearchTheCorrectMessages() async throws {
    let firstTransport = MultiHostTransport(), secondTransport = MultiHostTransport()
    let first = multiHostSession(multiHostID(0), transport: firstTransport, nickname: "Desk")
    let second = multiHostSession(multiHostID(1), transport: secondTransport, nickname: "Laptop")
    let hosts = MultiHostModel(sessions: [second, first])
    defer { first.model.close(); second.model.close() }
    await firstTransport.yield(.event(multiHostEvent("list", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "same", title: "Café planning", archived: false, lastActivity: 10),
        ThreadSummary(id: "z", title: "Tied", archived: false, lastActivity: 10),
    ])))))
    await secondTransport.yield(.event(multiHostEvent("list", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "same", title: "Archive", archived: true, lastActivity: 20),
        ThreadSummary(id: "tie", title: "Tied", archived: false, lastActivity: 10),
    ])))))
    // Event IDs and thread IDs can collide across Macs; neither is a global identity.
    await firstTransport.yield(.event(multiHostEvent("message", .message(MessageData(role: .agent, text: "Desk notes", done: true)))))
    await secondTransport.yield(.event(multiHostEvent("message", .message(MessageData(role: .agent, text: "Visit the café on the laptop", done: true)))))
    #expect(await multiHostEventually {
        hosts.threads.count == 4 && first.model.events["same"]?.count == 1 && second.model.events["same"]?.count == 1
    })

    let firstRef = HostThreadID(hostID: first.id, threadID: "same")
    let secondRef = HostThreadID(hostID: second.id, threadID: "same")
    #expect(hosts.threads.map(\.id) == [secondRef, firstRef,
        HostThreadID(hostID: first.id, threadID: "z"), HostThreadID(hostID: second.id, threadID: "tie")])
    #expect(Set(hosts.threads.map(\.id)).count == 4)
    #expect(hosts.thread(for: firstRef)?.hostLabel == "Desk")
    #expect(hosts.thread(for: secondRef)?.thread.archived == true)
    #expect(hosts.messageText(for: firstRef).contains("Desk notes"))
    #expect(!hosts.messageText(for: firstRef).contains("laptop"))
    #expect(hosts.messageText(for: secondRef).contains("laptop"))

    let results = hosts.search(" CAFE ")
    #expect(results.threads.map(\.id) == [firstRef])
    #expect(results.messages.map(\.id) == [secondRef])
    #expect(!results.isEmpty)
    #expect(hosts.search(" \n\t").isEmpty)
    #expect(hosts.search("absent").isEmpty)
    #expect(try JSONDecoder().decode(HostThreadID.self, from: JSONEncoder().encode(secondRef)) == secondRef)
}

@MainActor
@Test func multiHostActionsReachOnlyTheirOwningTransportAndReadState() async throws {
    let firstTransport = MultiHostTransport(), secondTransport = MultiHostTransport()
    let first = multiHostSession(multiHostID(0), transport: firstTransport)
    let second = multiHostSession(multiHostID(1), transport: secondTransport)
    let hosts = MultiHostModel(sessions: [first, second])
    defer { first.model.close(); second.model.close() }
    let thread = ThreadSummary(id: "same", title: "Work", archived: false, lastActivity: 1, lastReadAt: 1, lastAgentAt: 2)
    for transport in [firstTransport, secondTransport] {
        await transport.online()
        await transport.yield(.event(multiHostEvent("list", .threadList(ThreadListData(threads: [thread])))))
        _ = await multiHostSent(transport, atLeast: multiHostPairingSends)
    }
    #expect(await multiHostEventually { hosts.unreadCount == 2 && first.model.canDeliver && second.model.canDeliver })
    let secondBefore = await secondTransport.sent
    let ref = HostThreadID(hostID: first.id, threadID: thread.id)
    let owner = try #require(hosts.model(for: ref))
    #expect(owner === first.model)
    owner.send("only desk", in: ref.threadID)
    owner.answer("shared-action", in: ref.threadID, .yes)
    owner.rename(thread, to: "Desk title")
    owner.archive(thread)
    owner.markRead(ref.threadID)

    let emitted = await multiHostSent(firstTransport, atLeast: multiHostPairingSends + 5)
    let actions = emitted.filter { $0.threadId == thread.id }
    #expect(Set(actions.map(\.payload.kind)) == [.message, .approvalAnswer, .threadRename, .threadArchive, .threadRead])
    #expect(actions.contains { $0.payload == .threadRename(ThreadRenameData(title: "Desk title")) })
    #expect(await secondTransport.sent == secondBefore)
    #expect(second.model.events[thread.id] == nil)
    #expect(!second.model.answered.contains("shared-action"))
    #expect(second.model.threads.first?.archived == false)
    #expect(second.model.threads.first?.isUnread == true)
    #expect(hosts.unreadCount == 1)

    hosts.markAllRead()
    #expect(hosts.unreadCount == 0)
    let secondAfter = await multiHostSent(secondTransport, atLeast: secondBefore.count + 1)
    #expect(secondAfter.last?.payload.kind == .threadRead)
    #expect(secondAfter.last?.threadId == thread.id)
    #expect(hosts.model(for: HostThreadID(hostID: "missing", threadID: "same")) == nil)
}

@MainActor
@Test func multiHostIdentitySurvivesRelayChangesAndRejectsDuplicatePairings() throws {
    let key = multiHostID(0)
    let original = QrPayload(relayUrl: "wss://one.example", macPubkey: key, token: "first", roomId: "old-room")
    let rescanned = QrPayload(relayUrl: "wss://two.example", macPubkey: key, token: "next", roomId: "new-room")
    #expect(original.hostID == key)
    #expect(rescanned.hostID == original.hostID)
    #expect(QrPayload(relayUrl: original.relayUrl, macPubkey: "not base64!", token: "t").hostID == nil)
    #expect(QrPayload(relayUrl: original.relayUrl, macPubkey: Data(repeating: 1, count: 31).base64URLEncodedString(), token: "t").hostID == nil)
    #expect(QrPayload(relayUrl: original.relayUrl, macPubkey: Data(repeating: 1, count: 33).base64URLEncodedString(), token: "t").hostID == nil)

    let model = ChatModel(transport: MultiHostTransport())
    let first = HostSession(id: try #require(original.hostID), model: model, relayURL: original.relayUrl)
    let duplicate = HostSession(id: try #require(rescanned.hostID), model: ChatModel(transport: MultiHostTransport()), relayURL: rescanned.relayUrl)
    let hosts = MultiHostModel()
    #expect(hosts.add(first))
    #expect(!hosts.add(duplicate))
    #expect(hosts.sessions.count == 1)
    #expect(hosts.session(for: key) === first)
}

@MainActor
@Test func multiHostLabelsPreferNicknamesThenAuthenticatedNamesThenStableFingerprint() async {
    let transport = MultiHostTransport()
    let host = multiHostSession(multiHostID(0), transport: transport)
    defer { host.model.close() }
    let fallback = "Mac · \(QrPayload.fingerprint(ofBase64URLKey: host.id)!)"
    #expect(host.label == fallback)
    await transport.yield(.peerInfo(PeerInfoData(appVersion: "1", computerName: "Studio Mac")))
    #expect(await multiHostEventually { host.label == "Studio Mac" })
    host.nickname = "Travel"
    #expect(host.label == "Travel")
    await transport.yield(.peerInfo(PeerInfoData(appVersion: "1", computerName: "Renamed Mac")))
    #expect(await multiHostEventually { host.model.peerInfo?.computerName == "Renamed Mac" })
    #expect(host.label == "Travel")
    host.nickname = nil
    #expect(host.label == "Renamed Mac")
    await transport.yield(.peerInfo(PeerInfoData(appVersion: "1")))
    #expect(await multiHostEventually { host.label == fallback })
}

@MainActor
@Test func multiHostDraftsUseTheSelectedMacAndOfflineQueuesDrainIndependently() async throws {
    let firstTransport = MultiHostTransport(), secondTransport = MultiHostTransport()
    let first = multiHostSession(multiHostID(0), transport: firstTransport)
    let second = multiHostSession(multiHostID(1), transport: secondTransport)
    let hosts = MultiHostModel(sessions: [first, second], lastUsedHostID: second.id)
    defer { first.model.close(); second.model.close() }
    let remembered = try #require(hosts.newDraft(agent: .codex, cwd: "/second/project"))
    #expect(remembered.hostID == second.id)
    #expect(second.model.draft?.cwd == "/second/project")
    #expect(second.model.draft?.agent == .codex)
    let selected = try #require(hosts.newDraft(on: first.id))
    #expect(selected.hostID == first.id)
    #expect(hosts.lastUsedHostID == first.id)
    hosts.model(for: selected)?.send("first queued", in: selected.threadID)
    hosts.model(for: remembered)?.send("second queued", in: remembered.threadID)
    let firstIDs = first.model.outbox.map(\.id), secondIDs = second.model.outbox.map(\.id)
    #expect(firstIDs.count == 2 && secondIDs.count == 2)
    #expect(await firstTransport.sent.isEmpty)
    #expect(await secondTransport.sent.isEmpty)

    await firstTransport.online()
    #expect(await multiHostEventually { first.model.outbox.isEmpty })
    #expect(second.model.outbox.map(\.id) == secondIDs)
    #expect(await secondTransport.sent.isEmpty)
    let firstSent = await firstTransport.sent
    #expect(firstSent.filter { firstIDs.contains($0.id) }.map(\.id) == firstIDs)
    #expect(!firstSent.contains { secondIDs.contains($0.id) })
    #expect(hosts.newDraft(on: "missing") == nil)
    #expect(MultiHostModel().newDraft() == nil)
}

@MainActor
@Test func multiHostRemovalStopsWritesBeforeCacheErasureAndPreservesOtherMacsQueue() async throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstCache = ThreadCache(directory: root.appending(path: "first"), key: SymmetricKey(size: .bits256))
    let secondCache = ThreadCache(directory: root.appending(path: "second"), key: SymmetricKey(size: .bits256))
    let firstTransport = MultiHostTransport(), secondTransport = MultiHostTransport()
    let first = multiHostSession(multiHostID(0), transport: firstTransport, cache: firstCache)
    let second = multiHostSession(multiHostID(1), transport: secondTransport, cache: secondCache)
    let hosts = MultiHostModel(sessions: [first, second], lastUsedHostID: first.id)
    defer { second.model.close() }
    first.model.send("removed queue", in: "same")
    second.model.send("surviving queue", in: "same")
    let remainingQueue = second.model.outbox.map(\.id)
    // Both paths have pending writes: detached timeline persistence and the composer debounce.
    first.model.drafts["same"] = "unfinished"
    await firstTransport.yield(.event(multiHostEvent("list", .threadList(ThreadListData(threads: [
        ThreadSummary(id: "same", title: "Retiring", archived: false, lastActivity: 1),
    ])))))
    #expect(await multiHostEventually { first.model.threads.count == 1 })
    let removed = await hosts.remove(first.id)
    #expect(removed === first)
    #expect(hosts.sessions.map(\.id) == [second.id])
    #expect(hosts.session(for: first.id) == nil)
    #expect(hosts.preferredHostID == second.id)
    #expect(await firstTransport.closes == 1)
    #expect(await secondTransport.closes == 0)
    try FileManager.default.removeItem(at: firstCache.directory)
    try await Task.sleep(for: .milliseconds(400))
    #expect(!FileManager.default.fileExists(atPath: firstCache.directory.path))
    #expect(second.model.outbox.map(\.id) == remainingQueue)
    #expect(secondCache.outbox().map(\.id) == remainingQueue)
    #expect(await secondTransport.sent.isEmpty)
    #expect(await hosts.remove(first.id) == nil)

    await secondTransport.online()
    #expect(await multiHostEventually { second.model.outbox.isEmpty })
    #expect(await secondTransport.sent.contains { remainingQueue.contains($0.id) })
}

@MainActor
@Test func multiHostAmbiguousApprovalReferencesCannotAnswerAnArbitraryThread() async {
    let transport = MultiHostTransport()
    let host = multiHostSession(multiHostID(0), transport: transport)
    defer { host.model.close() }
    await transport.online()
    for thread in ["one", "two"] {
        let card = ApprovalCardData(actionId: "action-\(thread)", actionClass: "exec", target: thread)
        await transport.yield(.event(multiHostEvent("same-card", .approvalCard(card), thread: thread)))
    }
    #expect(await multiHostEventually {
        host.model.canDeliver && host.model.events["one"]?.count == 1 && host.model.events["two"]?.count == 1
    })
    let answered = await host.model.answerFromNotification(eventRef: YorozuCrypto.threadRef("same-card"), .yes,
        timeout: .milliseconds(100))
    #expect(!answered)
    #expect(host.model.answered.isEmpty)
    #expect(await !transport.sent.contains { $0.payload.kind == .approvalAnswer })
}

@Test func multiHostLegacyCacheMigrationPreservesCiphertextAndRefusesConflictingData() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = SymmetricKey(size: .bits256)
    let legacy = ThreadCache(directory: root.appending(path: "legacy"), key: key)
    let destination = root.appending(path: "hosts/original-host")
    let thread = ThreadSummary(id: "same", title: "Original Mac", archived: false, lastActivity: 1)
    let message = multiHostEvent("pending", .message(MessageData(role: .user, text: "unsent")))
    legacy.save(threads: [thread])
    legacy.save(events: [message], threadId: thread.id, lastSeen: message.id)
    legacy.save(outbox: [OutboxItem(event: message)])
    let originalFiles = try FileManager.default.contentsOfDirectory(at: legacy.directory, includingPropertiesForKeys: nil)
    let originalBytes = try Dictionary(uniqueKeysWithValues: originalFiles.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })

    try ThreadCache.migrateLegacyDirectory(from: legacy.directory, to: destination)
    // Retry after interruption is harmless, without rewriting authenticated bytes.
    try ThreadCache.migrateLegacyDirectory(from: legacy.directory, to: destination)
    for (name, bytes) in originalBytes {
        #expect(try Data(contentsOf: destination.appending(path: name)) == bytes)
        #expect(try Data(contentsOf: legacy.directory.appending(path: name)) == bytes)
    }
    let migrated = ThreadCache(directory: destination, key: key)
    #expect(migrated.threads() == [thread])
    #expect(migrated.events(threadId: thread.id) == [message])
    #expect(migrated.lastSeen() == [thread.id: message.id])
    #expect(migrated.outbox().map(\.id) == [message.id])

    let other = ThreadSummary(id: "same", title: "Different host", archived: false, lastActivity: 2)
    migrated.save(threads: [other])
    #expect(throws: (any Error).self) {
        try ThreadCache.migrateLegacyDirectory(from: legacy.directory, to: destination)
    }
    #expect(migrated.threads() == [other])
    #expect(legacy.threads() == [thread])
}

@MainActor
@Test func multiHostAuthenticatedNamesRemainAvailableAfterAnOfflineRelaunch() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: SymmetricKey(size: .bits256))
    let transport = MultiHostTransport()
    let first = multiHostSession(multiHostID(0), transport: transport, cache: cache)
    await transport.yield(.peerInfo(PeerInfoData(appVersion: "1", computerName: "Office Mac")))
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["host-name"])))
    #expect(await multiHostEventually { first.label == "Office Mac" && first.model.compatibility != .legacy })
    await first.model.shutdown()

    let restored = HostSession(id: first.id, model: ChatModel(transport: MultiHostTransport(), cache: cache),
        relayURL: first.relayURL)
    #expect(!restored.model.canDeliver)
    #expect(restored.label == "Office Mac")
    #expect(restored.model.compatibility == .legacy)
}

@MainActor
@Test func multiHostOfflineApprovalIntentSurvivesRelaunchOnlyForItsOwner() {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: SymmetricKey(size: .bits256))
    let first = ChatModel(transport: MultiHostTransport(), cache: cache)
    let other = ChatModel(transport: MultiHostTransport())
    first.answer("same-action", in: "same", .yes)
    first.answerQuestion("same-question", in: "same", "Option A")

    let restored = ChatModel(transport: MultiHostTransport(), cache: cache)
    #expect(restored.approvalPending("same-action"))
    #expect(!restored.answered.contains("same-action"))
    #expect(restored.questionChoices["same-question"] == "Option A")
    #expect(restored.outbox.map(\.event.payload.kind) == [.approvalAnswer, .questionAnswer])
    #expect(other.answered.isEmpty && other.answeredQuestions.isEmpty && other.outbox.isEmpty)
}
