import YorozuWire

struct RequestQueue: Equatable {
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

    mutating func take() -> WireEvent? {
        guard inFlight == nil, !pending.isEmpty else { return nil }
        inFlight = pending.removeFirst()
        return inFlight
    }

    @discardableResult
    mutating func finish(answering answer: WireEvent) -> Bool {
        switch (inFlight, answer) {
        case (.convList, .convList):
            break
        case (.historyRequest(let request), .history(let page)) where request.convId == page.convId:
            break
        default:
            return false
        }
        inFlight = nil
        return true
    }

    @discardableResult
    mutating func fail(_ request: WireEvent? = nil) -> Bool {
        guard let failed = inFlight, request == nil || request == failed else { return false }
        inFlight = nil
        if case .historyRequest(let history) = failed { loadingOlder.remove(history.convId) }
        return true
    }


    @discardableResult
    mutating func fail(messageId: String) -> Bool {
        guard case .message(let message) = inFlight, message.messageId == messageId else { return false }
        return fail()
    }

    mutating func loadedOlder(_ convId: String) {
        loadingOlder.remove(convId)
    }

    mutating func restart() {
        self = RequestQueue(pending: [.convList(ConvList())])
    }
}
