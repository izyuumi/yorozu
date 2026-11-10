import Testing
import YorozuWire

@Suite struct RequestQueueTests {
    private let older = WireEvent.historyRequest(HistoryRequest(convId: "conv-a", before: 40))
    private let next = WireEvent.historyRequest(HistoryRequest(convId: "conv-b", after: 7))

    private func loadingOlderInFlight() -> RequestQueue {
        var queue = RequestQueue()
        queue.enqueue(next)
        queue.loadOlder("conv-a", before: 40)
        #expect(queue.take() == older)
        #expect(queue.loadingOlder == ["conv-a"])
        return queue
    }

    @Test func aHostErrorWithoutAMessageIdStopsLoadingOlderAndTakesTheNextRequest() {
        var queue = loadingOlderInFlight()

        let failed = queue.fail()
        #expect(failed)
        #expect(queue.loadingOlder.isEmpty)
        #expect(queue.take() == next)
    }

    @Test func aHostErrorAboutAMessageLeavesTheHistoryRequestInFlightUntilItTimesOut() {
        var queue = loadingOlderInFlight()

        let failed = queue.fail(messageId: "message-1")
        #expect(!failed)
        #expect(queue.inFlight == older)
        #expect(queue.loadingOlder == ["conv-a"])
        #expect(queue.take() == nil)

        let timedOut = queue.fail(older)
        #expect(timedOut)
        #expect(queue.loadingOlder.isEmpty)
        #expect(queue.take() == next)
    }

    @Test func aHostErrorAboutTheInFlightMessageFailsIt() {
        let message = WireEvent.message(Message(convId: "conv-a", messageId: "message-1", text: "hello"))
        var queue = RequestQueue()
        queue.enqueue(message)
        #expect(queue.take() == message)

        let other = queue.fail(messageId: "message-2")
        #expect(!other)
        #expect(queue.inFlight == message)

        let failed = queue.fail(messageId: "message-1")
        #expect(failed)
        #expect(queue.inFlight == nil)
    }

    @Test func anErrorWithNothingInFlightFailsNothing() {
        var queue = RequestQueue()
        queue.loadOlder("conv-a", before: 40)

        let failedNothing = queue.fail()
        #expect(!failedNothing)
        #expect(queue.loadingOlder == ["conv-a"])
        #expect(queue.take() == older)
    }

    @Test func aHistoryPageStopsLoadingOlder() {
        var queue = loadingOlderInFlight()

        queue.loadedOlder("conv-a")
        queue.finish()
        #expect(queue.loadingOlder.isEmpty)
        #expect(queue.take() == next)
    }

    @Test func aTimeoutOrFailedSendStopsLoadingOlder() {
        var queue = loadingOlderInFlight()

        let timedOut = queue.fail(older)
        #expect(timedOut)
        #expect(queue.loadingOlder.isEmpty)
        #expect(queue.inFlight == nil)
    }

    @Test func aStaleTimeoutLeavesTheNewerRequestInFlight() {
        var queue = loadingOlderInFlight()
        queue.loadedOlder("conv-a")
        queue.finish()
        #expect(queue.take() == next)
        queue.loadOlder("conv-b", before: 3)

        let stale = queue.fail(older)
        #expect(!stale)
        #expect(queue.inFlight == next)
        #expect(queue.loadingOlder == ["conv-b"])
    }

    @Test func onlyOneRequestIsInFlightAndRepeatsAreNotQueuedTwice() {
        var queue = loadingOlderInFlight()

        queue.enqueue(older)
        queue.enqueue(next)
        #expect(queue.take() == nil)
        #expect(queue.pending == [next])
    }

    @Test func aRestartKeepsOnlyTheConversationList() {
        var queue = loadingOlderInFlight()

        queue.restart()
        #expect(queue.loadingOlder.isEmpty)
        #expect(queue.inFlight == nil)
        #expect(queue.pending == [.convList(ConvList())])
    }
}
