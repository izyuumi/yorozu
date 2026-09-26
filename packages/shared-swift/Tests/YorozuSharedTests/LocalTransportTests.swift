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
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    var hasConnection: Bool { !connections.isEmpty }

    func start(path: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.ready = true }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.connections.append(connection)
                connection.start(queue: .global())
            }
        }
        listener.start(queue: .global())
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
