import YorozuWire

/// The host requests that go out one at a time, and the conversations waiting for an older history page.
struct RequestQueue {
    private(set) var pending: [WireEvent] = []
    private(set) var inFlight: WireEvent?
    private(set) var loadingOlder: Set<String> = []

    mutating func enqueue(_ request: WireEvent, first: Bool = false) {
        guard request != inFlight else { return }
        pending.removeAll { $0 == request }
        if first { pending.insert(request, at: 0) } else { pending.append(request) }
    }

    mutating func loadOlder(_ convId: String, before: Int) {
        loadingOlder.insert(convId)
        enqueue(.historyRequest(HistoryRequest(convId: convId, before: before)), first: true)
    }

    /// The next request to send, now in flight; nil while one is in flight or nothing waits.
    mutating func take() -> WireEvent? {
        guard inFlight == nil, !pending.isEmpty else { return nil }
        inFlight = pending.removeFirst()
        return inFlight
    }

    /// The in-flight request was answered.
    mutating func finish() {
        inFlight = nil
    }

    /// The in-flight request got no answer (host error, timeout or failed send), so its conversation stops loading.
    /// Pass the request to fail it only while it is still the one in flight. False when nothing was failed.
    @discardableResult
    mutating func fail(_ request: WireEvent? = nil) -> Bool {
        guard let failed = inFlight, request == nil || request == failed else { return false }
        inFlight = nil
        if case .historyRequest(let history) = failed { loadingOlder.remove(history.convId) }
        return true
    }

    /// A host error about one message fails the in-flight request only when that request is the message itself.
    /// History and conversation-list requests carry no message id, so such an error leaves them in flight.
    @discardableResult
    mutating func fail(messageId: String) -> Bool {
        guard case .message(let message) = inFlight, message.messageId == messageId else { return false }
        return fail()
    }

    mutating func loadedOlder(_ convId: String) {
        loadingOlder.remove(convId)
    }

    /// A new session starts from the conversation list alone.
    mutating func restart() {
        self = RequestQueue(pending: [.convList(ConvList())])
    }
}
