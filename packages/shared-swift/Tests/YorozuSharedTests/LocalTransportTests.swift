import Foundation
import Network
import Testing
@testable import YorozuShared

@MainActor
private final class RestartSocketServer {
    var ready = false
    private var listener: NWListener?
    private var connections: [NWConnection] = []

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
    #expect(await waitFor { model.state == .paired })
    server.stop()
    #expect(await waitFor { !model.ownerOnline })
    try? FileManager.default.removeItem(atPath: path)
    try server.start(path: path)
    #expect(await waitFor { server.ready })
    #expect(await waitFor { model.state == .paired && model.ownerOnline })
    model.close()
}
