import Foundation
import YorozuWire

actor IdleTransport: ClientTransport {
    func updates() -> AsyncStream<RelayConnection.Update> { AsyncStream { $0.finish() } }
    func start() {}
    func reconnect() {}
    func stop() {}
    func registerPush(deviceToken: String) {}
    func send(_ event: WireEvent) -> Bool { false }
    func send(_ message: Message) -> Bool { false }
    func raceAgain() {}
}

/// Yields what a test scripts; updates yielded before `updates()` is subscribed wait for it.
/// Records every event sent and answers each send with `sendResult`, false until a test sets it.
actor ScriptedTransport: ClientTransport {
    private var continuation: AsyncStream<RelayConnection.Update>.Continuation?
    private var waiting: [RelayConnection.Update] = []
    private(set) var sent: [WireEvent] = []
    private(set) var sendResult = false

    func setSendResult(_ result: Bool) { sendResult = result }

    func emit(_ update: RelayConnection.Update) {
        if let continuation { continuation.yield(update) } else { waiting.append(update) }
    }

    func updates() -> AsyncStream<RelayConnection.Update> {
        let (stream, continuation) = AsyncStream<RelayConnection.Update>.makeStream()
        for update in waiting { continuation.yield(update) }
        waiting = []
        self.continuation = continuation
        return stream
    }

    func start() {}
    func reconnect() {}
    func stop() {}
    func registerPush(deviceToken: String) {}

    func send(_ event: WireEvent) -> Bool {
        sent.append(event)
        return sendResult
    }

    func send(_ message: Message) -> Bool { sendResult }
    func raceAgain() {}
}
