import Foundation
import Network
import Testing
@testable import YorozuShared

@Test func sendDeadlineReturnsWhenUnderlyingSendStalls() async throws {
    let (timeouts, signal) = AsyncStream<Void>.makeStream()
    await #expect(throws: TransportSendTimeout.self) {
        try await sendWithDeadline(.milliseconds(30), onTimeout: { signal.yield(()) }) {
            try await Task.sleep(for: .seconds(5))
        }
    }
    var iterator = timeouts.makeAsyncIterator()
    #expect(await iterator.next() != nil)
}

@Test func successfulSendDoesNotCancelItsSocketAtDeadline() async throws {
    let (timeouts, signal) = AsyncStream<Void>.makeStream()
    try await sendWithDeadline(.milliseconds(300), onTimeout: { signal.yield(()) }) {}
    try await Task.sleep(for: .milliseconds(350))
    signal.finish()
    var iterator = timeouts.makeAsyncIterator()
    #expect(await iterator.next() == nil)
}

@Test func cancelledSendClosesItsSocket() async throws {
    let (cancellations, signal) = AsyncStream<Void>.makeStream()
    let (starts, started) = AsyncStream<Void>.makeStream()
    let task = Task {
        try await sendWithDeadline(.seconds(5), onTimeout: { signal.yield(()) }) {
            started.yield(())
            try await Task.sleep(for: .seconds(5))
        }
    }
    var start = starts.makeAsyncIterator()
    #expect(await start.next() != nil)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    signal.finish()
    var iterator = cancellations.makeAsyncIterator()
    #expect(await iterator.next() != nil)
}

@MainActor
private final class RestartSocketServer {
    var ready = false
    var failure: String?
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    var hasConnection: Bool { !connections.isEmpty }
    private(set) var received: [YorozuEvent] = []

    func start(path: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.ready = true }
                if case .failed(let error) = state { self?.failure = error.localizedDescription }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.connections.append(connection)
                connection.start(queue: .global())
                self?.receive(connection)
            }
        }
        listener.start(queue: .global())
    }

    func send(_ data: Data) {
        for connection in connections {
            connection.send(content: data + Data([0x0a]), completion: .contentProcessed { _ in })
        }
    }

    func send(_ event: YorozuEvent) throws { send(try JSONEncoder().encode(event)) }

    private func receive(_ connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffered
                if let data { buffer.append(data) }
                while let newline = buffer.firstIndex(of: 0x0a) {
                    let line = Data(buffer[..<newline])
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    if let event = try? JSONDecoder().decode(YorozuEvent.self, from: line) { self.received.append(event) }
                }
                if !complete, error == nil { self.receive(connection, buffered: buffer) }
            }
        }
    }

    func stop() {
        listener?.cancel()
        for connection in connections { connection.cancel() }
        connections = []
        ready = false
    }
}

@MainActor
@Test func localRuntimeReconnectsWithoutRestartingTheMacApp() async throws {
    let path = "/tmp/yorozu-\(UUID().uuidString).sock"
    let server = RestartSocketServer()
    defer { server.stop(); try? FileManager.default.removeItem(atPath: path) }
    func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
    try server.start(path: path)
    #expect(await waitFor { server.ready })
    let model = ChatModel(transport: LocalSocketTransport(path: path))
    model.start()
    #expect(await waitFor { server.hasConnection && model.state == .paired })
    server.stop()
    #expect(await waitFor { !model.ownerOnline })
    try? FileManager.default.removeItem(atPath: path)
    try server.start(path: path)
    #expect(await waitFor { server.ready })
    #expect(await waitFor { model.state == .paired && model.ownerOnline })
    model.close()
}

@MainActor
@Test func localHarnessTaskControlsFollowHostSummaryAcrossHistoryAndReopen() async throws {
    let path = "/tmp/yorozu-\(UUID().uuidString).sock"
    let server = RestartSocketServer()
    let model = ChatModel(transport: LocalSocketTransport(path: path))
    defer { model.close(); server.stop(); try? FileManager.default.removeItem(atPath: path) }
    func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
    func event(_ id: String, _ payload: YorozuEvent.Payload, thread: String = "") -> YorozuEvent {
        YorozuEvent(id: id, threadId: thread, ts: 1, agentId: "main", payload: payload)
    }
    try server.start(path: path)
    try #require(await waitFor { server.ready }, "Local listener: \(server.failure ?? "never became ready")")
    model.start()
    #expect(await waitFor { server.hasConnection && model.state == .paired })
    // An older local runtime sends plain JSON with no capability announcement.
    server.send(Data(#"{"id":"task-list","threadId":"","ts":1,"agentId":"main","kind":"thread_list","data":{"threads":[{"id":"task","title":"Harmless task","archived":false,"lastActivity":1,"agent":"harness","activeEventId":"exact-task-target","turnState":"running","harness":{"pluginId":"hermes","backgroundTasks":true,"targetedSteer":true,"taskStop":true},"harnessTask":{"taskId":"child-42","parentThreadId":"yorozu-secretary-v1","state":"running","canSteer":true,"canStop":true}},{"id":"native","title":"Native","archived":false,"lastActivity":1,"agent":"codex","activeEventId":"native-target","turnState":"running"}]}}"#.utf8))
    #expect(await waitFor { model.threads.contains { $0.id == "task" } })
    let task = try #require(model.threads.first { $0.id == "task" })
    #expect(model.compatibility == .legacy)
    #expect(task.harness?.pluginId == "hermes")
    #expect(task.harnessTask?.canStop == true)
    #expect(!model.canStop(in: task.id))
    // Current runtimes declare their inventory on the owner-only socket's initial list.
    try server.send(event("declared-host", .threadList(ThreadListData(
        threads: model.threads, peerInfoSupported: true, peerInfo: .local))))
    #expect(await waitFor { model.canStop(in: task.id) })
    if case .compatible(_, let capabilities) = model.compatibility { #expect(capabilities.contains("turn-state-v1")) }
    else { Issue.record("Declared local host did not negotiate capabilities") }
    #expect(model.canStop(in: task.id))
    #expect(model.generating.contains("native"))

    model.openThread = task.id
    let history = event("history", .message(MessageData(role: .user, text: "Original task")), thread: task.id)
    try server.send(event("history-delta", .syncDelta(SyncDeltaData(events: [history], threadId: task.id, workingThreadIds: ["native"]))))
    #expect(await waitFor { model.events[task.id]?.contains { $0.id == history.id } == true })
    #expect(model.canStop(in: task.id))
    model.openThread = "native"
    model.openThread = task.id
    let reopened = event("reopened", .message(MessageData(role: .agent, text: "Working…")), thread: task.id)
    try server.send(event("reopened-delta", .syncDelta(SyncDeltaData(events: [reopened], threadId: task.id, workingThreadIds: []))))
    #expect(await waitFor { model.events[task.id]?.contains { $0.id == reopened.id } == true })
    #expect(model.canStop(in: task.id))
    #expect(model.generating == Set([task.id]))

    model.drafts[task.id] = "Change this task only"
    model.send(in: task)
    #expect(await waitFor { server.received.contains { outgoing in
        guard outgoing.threadId == task.id, case .message(let data) = outgoing.payload else { return false }
        return data.text == "Change this task only" && data.delivery == .steer
    } })
    model.interrupt(in: task.id)
    #expect(await waitFor { server.received.contains { $0.threadId == task.id && $0.payload == .interrupt(InterruptData(targetEventId: "exact-task-target")) } })

    var terminal = task
    terminal.activeEventId = nil
    terminal.turnState = .idle
    terminal.harnessTask?.state = .stopped
    terminal.harnessTask?.canSteer = false
    terminal.harnessTask?.canStop = false
    try server.send(event("terminal", .threadList(ThreadListData(threads: [terminal]))))
    #expect(await waitFor { model.threads.first?.harnessTask?.state == .stopped })
    #expect(!model.canStop(in: task.id))
    #expect(!model.generating.contains(task.id))
    let stale = event("stale-history", .message(MessageData(role: .agent, text: "Earlier progress")), thread: task.id)
    try server.send(event("stale-delta", .syncDelta(SyncDeltaData(events: [stale], threadId: task.id, workingThreadIds: [task.id]))))
    #expect(await waitFor { model.events[task.id]?.contains { $0.id == stale.id } == true })
    #expect(!model.generating.contains(task.id))
    let controls = model.outbox.count
    model.interrupt(in: task.id)
    model.drafts[task.id] = "Change the ended task"
    model.send(in: task)
    #expect(model.outbox.count == controls)
    #expect(model.drafts[task.id] == "Change the ended task")
    server.stop()
    #expect(await waitFor { !model.ownerOnline && model.compatibility == .legacy })
}
