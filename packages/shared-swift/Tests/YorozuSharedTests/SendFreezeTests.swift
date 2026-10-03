import CryptoKit
import Foundation
import Testing

@testable import YorozuShared

/// A host that takes every chunk at once, so the only thing pacing an upload is this device.
private actor SinkTransport: ChatTransport {
    private var updates: AsyncStream<TransportUpdate>.Continuation?
    private(set) var committed = false

    func connect() -> AsyncStream<TransportUpdate> {
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        updates = continuation
        continuation.yield(.state(.paired))
        continuation.yield(.ownerOnline(true))
        continuation.yield(.compatibility(.compatible(version: 1, capabilities: ["attachment-chunks-v1"])))
        return stream
    }

    func send(_ event: YorozuEvent) async throws {
        if event.payload.kind == .attachmentCommit { committed = true }
        guard case .attachmentChunk(let chunk) = event.payload else { return }
        updates?.yield(.event(YorozuEvent(id: UUID().uuidString, threadId: event.threadId, ts: 1, agentId: "main",
            payload: .attachmentProgress(AttachmentProgressData(requestId: event.id, messageId: chunk.messageId,
                index: chunk.index, nextOffset: chunk.offset + (Data(base64Encoded: chunk.data)?.count ?? 0))))))
    }

    func close() { updates?.finish() }
}

/// Sending four 5 MB files held the main actor for the whole upload: every chunk the host
/// acknowledged re-encoded, sealed and rewrote all 27 MB of them, three times over.
@MainActor
@Test func sendingFilesNeverFreezesTheWindow() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThreadCache(directory: directory, key: SymmetricKey(size: .bits256))
    let thread = ThreadSummary(id: "t", title: "", archived: false, lastActivity: 1)
    cache.save(threads: [thread])
    let transport = SinkTransport()
    let model = ChatModel(transport: transport, cache: cache, device: "mac")
    defer { model.close() }
    model.start()
    for _ in 0..<300 {
        if model.canDeliver, case .compatible = model.compatibility { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    model.attachments["t"] = (0..<4).map {
        MessageAttachment(name: "\($0).png", mime: "image/png", bytes: Data(repeating: UInt8($0), count: 5 * 1024 * 1024))!
    }

    // Timed on this thread and against wide margins: other tests share the main actor.
    let begin = ContinuousClock.now
    model.send(in: thread)
    let blocked = begin.duration(to: .now)
    for _ in 0..<3000 where !(await transport.committed) { try await Task.sleep(for: .milliseconds(10)) }
    let uploaded = begin.duration(to: .now)

    #expect(await transport.committed)
    print("PERF send-4x5MB send() blocked=\(blocked) uploaded=\(uploaded)")
    #expect(blocked < .milliseconds(100))
    // The bug this guards rewrote all 27 MB for every acknowledged chunk, which takes far longer
    // than this. A clean upload takes 1–3 s, but shared CI runners have taken up to 12 s, so a
    // tighter bound measures the runner rather than the code.
    #expect(uploaded < .seconds(20))
}

@Test func filesAreSealedOnceAndSweptWhenNothingNamesThem() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SymmetricKey(size: .bits256)
    let cache = ThreadCache(directory: directory, key: key)
    let file = MessageAttachment(name: "a.png", mime: "image/png", bytes: Data(repeating: 7, count: 1024 * 1024))!
    let item = OutboxItem(event: YorozuEvent(id: "m", threadId: "t", ts: 1, agentId: "mac",
        payload: .message(MessageData(role: .user, text: "look", attachments: [file]))))
    func size(_ name: String) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as! Int
    }
    func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("file-") }
    }

    try cache.save(composer: .init(drafts: [:], attachments: ["t": [file]], threads: []))
    try cache.savePending([item])
    #expect(try files().count == 1)
    #expect(try size("composer.bin") < 4096)
    #expect(try size("outbox.bin") < 4096)

    // A relaunch reads the bytes back whole.
    let reopened = ThreadCache(directory: directory, key: key)
    #expect(reopened.composer()?.attachments == ["t": [file]])
    #expect(reopened.outbox() == [item])

    // The composer let go at send; the outbox still names the file until the host has it.
    try reopened.save(composer: .init(drafts: [:], attachments: [:], threads: []))
    #expect(try files().count == 1)
    try reopened.savePending([])
    #expect(try files().isEmpty)
}

@MainActor
@Test func removeAvailabilityTracksTerminalRepliesStopsAndTimelineChanges() {
    let model = ChatModel(transport: SinkTransport())
    func message(_ id: String, _ role: MessageData.Role, completion: String? = nil, done: Bool? = nil) -> YorozuEvent {
        YorozuEvent(id: id, threadId: "t", ts: 1, agentId: "main",
            payload: .message(MessageData(role: role, text: "Synthetic", done: done, completionId: completion)))
    }
    let prompt = message("group:prompt", .user, completion: "reply")
    #expect(!model.canWithdraw(prompt))
    model.applyEvent(prompt)
    #expect(model.canWithdraw(prompt))
    // Another message's legacy final must not retire this prompt.
    model.applyEvent(message("agent:prompt:final", .agent, done: true))
    #expect(model.canWithdraw(prompt))
    model.applyEvent(message("agent:group:prompt:final", .agent, done: true))
    #expect(!model.canWithdraw(prompt))
    model.delete("agent:group:prompt:final", in: "t")
    #expect(model.canWithdraw(prompt))
    model.applyEvent(message("reply", .agent, done: true))
    #expect(!model.canWithdraw(prompt))
    model.delete("reply", in: "t")
    #expect(model.canWithdraw(prompt))
    for status in [StopStatusData.Status.requested, .unknown, .stopped] {
        model.applyEvent(YorozuEvent(id: "stop", threadId: "t", ts: 2, agentId: "main",
            payload: .stopStatus(StopStatusData(targetEventId: prompt.id, requestId: "request", status: status))))
        #expect(model.canWithdraw(prompt) == (status != .stopped))
    }
}
