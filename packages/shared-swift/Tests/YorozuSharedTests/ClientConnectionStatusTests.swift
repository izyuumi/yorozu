import CryptoKit
import Foundation
import Testing

import YorozuShared

@Test func clientConnectionFailureNeverLooksLikeConnecting() {
    let status = ClientConnectionStatus(state: .closed, ownerOnline: false, failure: "Relay unavailable")
    #expect(status == .failed)
    #expect(status.label != "Connecting…")
}

@Test func clientConnectionDistinguishesRelayFromReachableHost() {
    #expect(ClientConnectionStatus(state: .joined, ownerOnline: false, failure: nil) == .hostOffline)
    #expect(ClientConnectionStatus(state: .paired, ownerOnline: false, failure: nil) == .hostOffline)
    #expect(ClientConnectionStatus(state: .joined, ownerOnline: true, failure: nil) == .connecting)
    #expect(ClientConnectionStatus(state: .paired, ownerOnline: true, failure: nil) == .connected)
}

@Test func clientConnectionDistinguishesInitialDialFromOfflineAndFailedRetry() {
    #expect(ClientConnectionStatus(state: .connecting, ownerOnline: false, failure: nil) == .connecting)
    #expect(ClientConnectionStatus(state: .closed, ownerOnline: true, failure: nil) == .offline)
    #expect(ClientConnectionStatus(state: .connecting, ownerOnline: false, failure: "Rejected") == .failed)
}

/// Retry operates on the existing model. Exercise its public transport boundary with a
/// real encrypted cache so a reconnect cannot silently become a reset of local work.
private actor RetryTransport: ChatTransport {
    private(set) var retries = 0
    private(set) var closes = 0
    func connect() -> AsyncStream<TransportUpdate> { AsyncStream { _ in } }
    func send(_ event: YorozuEvent) {}
    func close() { closes += 1 }
    func reconnect() { retries += 1 }
}

private actor RecoveryTransport: ChatTransport {
    private let stream: AsyncStream<TransportUpdate>
    private let continuation: AsyncStream<TransportUpdate>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func connect() -> AsyncStream<TransportUpdate> { stream }
    func send(_ event: YorozuEvent) {}
    func close() { continuation.finish() }
    func reconnect() { continuation.yield(.state(.connecting)) }
    func yield(_ update: TransportUpdate) { continuation.yield(update) }
}

@MainActor
private func eventuallyRecovered(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
@Test func clientRetryClearsFailureWhenRecoveredAndReportsLaterFailure() async {
    let transport = RecoveryTransport()
    let model = ChatModel(transport: transport, device: "mac")
    func status() -> ClientConnectionStatus {
        ClientConnectionStatus(state: model.state, ownerOnline: model.ownerOnline, failure: model.failure)
    }
    model.start()
    defer { model.close() }
    await transport.yield(.state(.closed))
    await transport.yield(.failed("Network unavailable"))
    #expect(await eventuallyRecovered { model.state == .closed && model.failure == "Network unavailable" })
    #expect(status() == .failed)

    model.reconnect()
    #expect(await eventuallyRecovered { model.state == .connecting })
    // Background retries retain the diagnostic until the session key is agreed.
    #expect(status() == .failed)
    await transport.yield(.state(.joined))
    #expect(await eventuallyRecovered { model.state == .joined })
    #expect(status() == .failed)

    await transport.yield(.state(.paired))
    #expect(await eventuallyRecovered { model.state == .paired && model.failure == nil })
    #expect(status() == .hostOffline)
    await transport.yield(.ownerOnline(true))
    #expect(await eventuallyRecovered { model.ownerOnline })
    #expect(status() == .connected)

    await transport.yield(.failed("Relay stopped answering"))
    #expect(await eventuallyRecovered { model.failure == "Relay stopped answering" })
    #expect(status() == .failed)
}

@MainActor
@Test func clientRetryPreservesDraftsCachedChatsAndCacheKey() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SymmetricKey(size: .bits256)
    let cache = ThreadCache(directory: directory, key: key)
    let thread = ThreadSummary(id: "home", title: "Saved chat", archived: false, lastActivity: 1)
    let message = YorozuEvent(id: "saved", threadId: "home", ts: 1, agentId: "main",
        payload: .message(MessageData(role: .agent, text: "Available offline")))
    cache.save(threads: [thread])
    cache.save(events: [message], threadId: thread.id, lastSeen: message.id)
    let transport = RetryTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "mac")
    let draft = model.newDraft()
    model.drafts[draft.id] = "Unsent text"

    model.reconnect()
    for _ in 0..<100 {
        if await transport.retries == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(await transport.retries == 1)
    #expect(await transport.closes == 0)
    #expect(model.drafts[draft.id] == "Unsent text")
    #expect(model.threads.contains { $0.id == draft.id })
    #expect(model.events[thread.id] == [message])
    let reopened = ThreadCache(directory: directory, key: key)
    #expect(reopened.threads() == [thread])
    #expect(reopened.events(threadId: thread.id) == [message])
}
