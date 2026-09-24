import Foundation
import Network

/// How ``ChatModel`` reaches the runtime, so the same model and the same views serve both apps:
/// the phone goes through the blind relay, the Mac app talks to the sidecar on its own machine.
///
/// Implementations are ``RelayClient`` and ``LocalSocketTransport``.
public protocol ChatTransport: Sendable {
    /// Opens the connection and yields every update until it ends. One-shot per transport.
    func connect() async -> AsyncStream<TransportUpdate>
    func send(_ event: YorozuEvent) async throws
    func close() async
    /// Asks for a dial now rather than whenever the transport would have got round to it — the
    /// app came back to the foreground. Must be safe to call on a healthy connection.
    func reconnect() async
}

extension ChatTransport {
    public func reconnect() async {}
}

public enum TransportState: String, Sendable {
    case connecting
    /// Accepted by the relay; the Mac may still be offline. Local transports skip it.
    case joined
    /// Events can flow: the session key is agreed, or the local socket is open.
    case paired
    case closed
}

public enum TransportUpdate: Sendable {
    case state(TransportState)
    /// Whether the runtime is reachable. Always true once a local socket is open — the sidecar
    /// is the thing on the other end of it.
    case ownerOnline(Bool)
    case event(YorozuEvent)
    /// Supplied only after validating the authenticated, encrypted peer exchange.
    case peerInfo(PeerInfoData)
    case compatibility(PeerCompatibility)
    case failed(String)
}

/// Mac side of the local channel: a Unix domain socket carrying the same ``YorozuEvent`` JSON
/// the relay carries, one event per line, in the clear. Mirrors
/// `packages/runtime/src/local.ts`, which owns the socket and its mode.
///
/// No pairing, no keys and no relay: the sidecar runs on this machine as this user, so being
/// connected is being paired.
public actor LocalSocketTransport: ChatTransport {
    private var connection: NWConnection
    private let path: String
    private var generation = 0
    private var closed = true
    private var retry: Task<Void, Never>?
    private var updates: AsyncStream<TransportUpdate>.Continuation?
    /// Bytes received that are not yet a whole line.
    private var buffer = Data()

    public init(path: String) {
        self.path = path
        // `.tcp` is how Network framework asks for a stream; the endpoint is what makes it a
        // Unix socket. The connection waits rather than failing when the socket is not there
        // yet, so starting the app before the sidecar is not an error.
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    /// Where the sidecar puts its socket: `<state dir>/local.sock`, the state dir being the one
    /// `YOROZU_STATE_DIR` names or the same Application Support directory the runtime defaults to.
    public static func defaultPath() -> String {
        let dir = ProcessInfo.processInfo.environment["YOROZU_STATE_DIR"]
            ?? URL.applicationSupportDirectory.appending(path: "Yorozu").path
        return URL(fileURLWithPath: dir).appending(path: "local.sock").path
    }

    public func connect() -> AsyncStream<TransportUpdate> {
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        updates = continuation
        closed = false
        dial()
        return stream
    }

    private func dial() {
        guard !closed else { return }
        generation += 1
        let current = generation
        connection.cancel()
        connection = NWConnection(to: .unix(path: path), using: .tcp)
        buffer = Data()
        updates?.yield(.state(.connecting))
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.changed(state, generation: current) }
        }
        connection.start(queue: .global())
        receive(generation: current)
    }

    public func send(_ event: YorozuEvent) async throws {
        var line = try JSONEncoder().encode(event)
        line.append(0x0a)
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            connection.send(
                content: line,
                completion: .contentProcessed { error in
                    if let error { resume.resume(throwing: error) } else { resume.resume() }
                }
            )
        }
    }

    public func close() {
        closed = true
        generation += 1
        retry?.cancel()
        retry = nil
        connection.cancel()
        finish()
    }

    public func reconnect() {
        guard !closed else { return }
        if case .ready = connection.state { return }
        retry?.cancel()
        retry = nil
        dial()
    }

    private func changed(_ state: NWConnection.State, generation: Int) {
        guard generation == self.generation, !closed else { return }
        switch state {
        case .ready:
            updates?.yield(.ownerOnline(true))
            updates?.yield(.state(.paired))
        case .waiting(let error):
            // Usually the sidecar still starting up. Network framework keeps retrying, so this
            // is something to say in the UI rather than a reason to give up.
            updates?.yield(.ownerOnline(false))
            updates?.yield(.failed("runtime not reachable: \(error.localizedDescription)"))
        case .failed(let error):
            updates?.yield(.failed(error.localizedDescription))
            redial()
        case .cancelled:
            redial()
        default:
            break
        }
    }

    /// One receive in flight at a time, re-armed only after the bytes it delivered have been
    /// handled, so lines reach the stream in the order they arrived.
    private func receive(generation: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.received(data, isComplete: isComplete, error: error, generation: generation) }
        }
    }

    private func received(_ data: Data?, isComplete: Bool, error: NWError?, generation: Int) {
        guard generation == self.generation, !closed else { return }
        if let data, !data.isEmpty { absorb(data) }
        guard !isComplete, error == nil else {
            if let error { updates?.yield(.failed(error.localizedDescription)) }
            return redial()
        }
        receive(generation: generation)
    }

    private func redial() {
        guard !closed, retry == nil else { return }
        generation += 1
        connection.cancel()
        updates?.yield(.ownerOnline(false))
        updates?.yield(.state(.closed))
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.retryConnection()
        }
    }

    private func retryConnection() {
        retry = nil
        dial()
    }

    private func absorb(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard !line.isEmpty else { continue }
            do {
                updates?.yield(.event(try JSONDecoder().decode(YorozuEvent.self, from: line)))
            } catch {
                // One bad line is one bad line: the connection is still good.
                updates?.yield(.failed("undecodable event: \(error.localizedDescription)"))
            }
        }
    }

    private func finish() {
        updates?.yield(.ownerOnline(false))
        updates?.yield(.state(.closed))
        updates?.finish()
        updates = nil
    }
}
