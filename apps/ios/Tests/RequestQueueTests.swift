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
        let finished = queue.finish(answering: .history(History(convId: "conv-a", items: [], more: false, rev: 1)))
        #expect(finished)
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
        let finished = queue.finish(answering: .history(History(convId: "conv-a", items: [], more: false, rev: 1)))
        #expect(finished)
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

    @Test func aLateHistoryAnswerDoesNotFinishTheNextRequest() {
        var queue = loadingOlderInFlight()
        let third = WireEvent.historyRequest(HistoryRequest(convId: "conv-c"))
        queue.enqueue(third)

        let failed = queue.fail(older)
        #expect(failed)
        #expect(queue.take() == next)

        let late = WireEvent.history(History(convId: "conv-a", items: [], more: false, rev: 1))
        let finishedByLate = queue.finish(answering: late)
        #expect(!finishedByLate)
        #expect(queue.inFlight == next)
        #expect(queue.take() == nil)

        // The request has an `after` cursor, but older hosts need not echo it.
        let answer = WireEvent.history(History(convId: "conv-b", items: [], more: false, rev: 1))
        let finishedByAnswer = queue.finish(answering: answer)
        #expect(finishedByAnswer)
        #expect(queue.inFlight == nil)
        #expect(queue.take() == third)
    }

    @Test func aConversationListOnlyFinishesAConversationListRequest() {
        var queue = RequestQueue()
        let list = WireEvent.convList(ConvList(conversations: []))
        let finishedIdle = queue.finish(answering: list)
        #expect(!finishedIdle)
        queue.restart()
        #expect(queue.take() == .convList(ConvList()))
        queue.enqueue(next)

        let finishedByHistory = queue.finish(answering: .history(History(convId: "conv-b", items: [], more: false, rev: 1)))
        #expect(!finishedByHistory)
        #expect(queue.inFlight == .convList(ConvList()))
        let finishedByList = queue.finish(answering: list)
        #expect(finishedByList)
        #expect(queue.take() == next)

        let finishedAgain = queue.finish(answering: list)
        #expect(!finishedAgain)
        let finishedByRequest = queue.finish(answering: .historyRequest(HistoryRequest(convId: "conv-b")))
        #expect(!finishedByRequest)
        #expect(queue.inFlight == next)
        #expect(queue.take() == nil)
    }

    @Test func aRestartKeepsOnlyTheConversationList() {
        var queue = loadingOlderInFlight()

        queue.restart()
        #expect(queue.loadingOlder.isEmpty)
        #expect(queue.inFlight == nil)
        #expect(queue.pending == [.convList(ConvList())])
    }
}
