import CryptoKit
import Foundation
import Testing

@testable import YorozuShared

private actor ListTransport: ChatTransport {
    private var continuation: AsyncStream<TransportUpdate>.Continuation?
    func connect() -> AsyncStream<TransportUpdate> {
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        self.continuation = continuation
        continuation.yield(.state(.paired))
        continuation.yield(.ownerOnline(true))
        return stream
    }
    private(set) var sent: [YorozuEvent] = []
    func send(_ event: YorozuEvent) async throws { sent.append(event) }
    func close() { continuation?.finish() }
}

@MainActor
@Test func combinedListKeepsCollidingThreadsSearchExportsAndActionsOnTheirHost() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    func host(_ id: String, title: String, body: String, activity: Double, transport: ListTransport) -> HostSession {
        let cache = ThreadCache(directory: directory.appending(path: id), key: SymmetricKey(size: .bits256))
        cache.save(threads: [ThreadSummary(id: "same", title: title, archived: false, lastActivity: activity)])
        cache.save(events: [YorozuEvent(id: "message", threadId: "same", ts: 1, agentId: "host",
            payload: .message(MessageData(role: .agent, text: body)))], threadId: "same")
        return HostSession(id: id, model: ChatModel(transport: transport, cache: cache), relayURL: "wss://relay.test", nickname: id)
    }
    let firstTransport = ListTransport()
    let secondTransport = ListTransport()
    let first = host("first", title: "Older", body: "private first coffee", activity: 1, transport: firstTransport)
    let second = host("second", title: "Newer", body: "private second tea", activity: 2, transport: secondTransport)
    let model = MultiHostModel(sessions: [first, second])
    let list = HostThreadListAdapter(session: model)
    let secondRow = try #require(list.threads.first)
    let firstRow = try #require(list.threads.last)
    #expect(secondRow.title == "Newer")
    #expect(firstRow.id != secondRow.id)
    #expect(list.resolve(firstRow.id)?.id == HostThreadID(hostID: "first", threadID: "same"))
    #expect(list.resolve(secondRow.id)?.hostLabel == "second")
    let results = ThreadSearchResults(threads: list.threads, query: "coffee", messageText: list.messageText)
    #expect(results.messages.map(\.id) == [firstRow.id])
    let hostResults = ThreadSearchResults(threads: list.threads, query: "second",
        metadataText: { list.hostLabel($0) ?? "" }, messageText: list.messageText)
    #expect(hostResults.threads.map(\.id) == [secondRow.id])
    #expect(list.markdown(firstRow).contains("private first coffee"))
    #expect(!list.markdown(firstRow).contains("private second tea"))

    model.start()
    for _ in 0..<100 {
        if first.model.canDeliver && second.model.canDeliver { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(first.model.canDeliver && second.model.canDeliver)

    // The callback gets the owning model and raw thread ID, never the presentation ID.
    list.perform(secondRow) { owner, thread in
        #expect(owner === second.model)
        #expect(thread.id == "same")
        owner.rename(thread, to: "Changed")
        owner.setPinned(thread, true)
        owner.setArchived(thread, true)
    }
    for _ in 0..<100 {
        if await secondTransport.sent.contains(where: { $0.payload.kind == .threadArchive }) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let mutations: Set<YorozuEvent.Kind> = [.threadRename, .threadPin, .threadArchive]
    let routed = await secondTransport.sent.filter { mutations.contains($0.payload.kind) }
    #expect(Set(routed.map { $0.payload.kind }) == mutations)
    #expect(routed.allSatisfy { $0.threadId == "same" })
    let rename = try #require(routed.first { $0.payload.kind == .threadRename })
    if case .threadRename(let data) = rename.payload { #expect(data.title == "Changed") }
    #expect(first.model.outbox.isEmpty)
    #expect(await firstTransport.sent.allSatisfy { !mutations.contains($0.payload.kind) })
    #expect(second.model.threads.first?.pinned == true)
    #expect(second.model.threads.first?.archived == true)
    #expect(first.model.threads.first?.title == "Older")
    #expect(first.model.threads.first?.pinned == false)
    #expect(first.model.threads.first?.archived == false)
    let groups = ThreadGroups(HostThreadListAdapter(session: model).threads)
    #expect(groups.recent.map(\.id) == [firstRow.id])
    #expect(groups.archived.map(\.id) == [secondRow.id])

    let intent = ThreadSearchRequest(threadId: firstRow.id, query: " coffee ")
    let mapped = try #require(list.searchRequest(intent))
    #expect(mapped.0.hostID == "first")
    #expect(mapped.1.threadId == "same")
    #expect(mapped.1.query == "coffee")
    #expect(mapped.1.id == intent.id)
    #expect(list.searchRequest(ThreadSearchRequest(threadId: "same", query: "coffee")) == nil)
    await model.remove("second")
    #expect(list.resolve(secondRow.id) == nil)
    #expect(list.resolve(firstRow.id)?.id.hostID == "first")
    await first.model.shutdown()
}

@Test func listPresentationIdentityCannotAliasAnotherHostOrDelimiterContainingThread() {
    let ids = [
        HostThreadID(hostID: "a", threadID: "bc"),
        HostThreadID(hostID: "ab", threadID: "c"),
        HostThreadID(hostID: "a", threadID: "same"),
        HostThreadID(hostID: "b", threadID: "same"),
        HostThreadID(hostID: "a:1", threadID: "b"),
        HostThreadID(hostID: "a", threadID: ":1b"),
        HostThreadID(hostID: "日本", threadID: "語"),
    ]
    #expect(Set(ids.map(\.listID)).count == ids.count)
}
