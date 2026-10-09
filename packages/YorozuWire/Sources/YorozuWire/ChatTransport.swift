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

struct TransportSendTimeout: LocalizedError {
    var errorDescription: String? { String(localized: "Timed out sending to host") }
}

private actor SendResolution {
    private var resolved = false
    func claim() -> Bool {
        guard !resolved else { return false }
        resolved = true
        return true
    }
}

/// Return on the first send result or deadline. Cancel the underlying socket on timeout so a
/// late completion cannot keep using an obsolete connection while the outbox retries its ID.
func sendWithDeadline(
    _ deadline: Duration = .seconds(10),
    onTimeout: @escaping @Sendable () -> Void,
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    let (stream, continuation) = AsyncStream<Result<Void, any Error>>.makeStream(
        bufferingPolicy: .bufferingOldest(1))
    let resolution = SendResolution()
    let sending = Task {
        do {
            try await operation()
            if await resolution.claim() {
                continuation.yield(.success(()))
                continuation.finish()
            }
        } catch {
            if await resolution.claim() {
                if error is CancellationError { onTimeout() }
                continuation.yield(.failure(error))
                continuation.finish()
            }
        }
    }
    let timer = Task {
        do { try await Task.sleep(for: deadline) }
        catch { return }
        if await resolution.claim() {
            onTimeout()
            continuation.yield(.failure(TransportSendTimeout()))
            continuation.finish()
        }
    }
    defer {
        sending.cancel()
        timer.cancel()
        continuation.finish()
    }
    try await withTaskCancellationHandler {
        var iterator = stream.makeAsyncIterator()
        guard let result = await iterator.next() else {
            if await resolution.claim() { onTimeout() }
            throw CancellationError()
        }
        try result.get()
    } onCancel: {
        Task {
            if await resolution.claim() {
                onTimeout()
                continuation.yield(.failure(CancellationError()))
                continuation.finish()
            }
        }
    }
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
    /// The relay forwarded (`buffered` false) or durably buffered (`buffered` true) this event's frame.
    case accepted(eventId: String, buffered: Bool)
}
