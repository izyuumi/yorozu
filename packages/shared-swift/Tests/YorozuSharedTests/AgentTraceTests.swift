import Foundation
import Testing

@testable import YorozuShared

/// One event in the thread, terse enough that a whole delegation reads as a few lines.
/// `ts` is left at zero throughout: the grouping goes by arrival order, which is the order of
/// the array, and pinning every timestamp to 0 keeps a test from implying otherwise.
private func event(
    _ payload: YorozuEvent.Payload,
    id: String,
    agent: String = "main",
    parent: String? = nil
) -> YorozuEvent {
    YorozuEvent(
        id: id,
        threadId: "home",
        ts: 0,
        agentId: agent,
        parentAgentId: parent,
        payload: payload
    )
}

private func reply(_ text: String, done: Bool? = nil) -> YorozuEvent.Payload {
    .message(MessageData(role: .agent, text: text, done: done))
}

private func ask(_ text: String) -> YorozuEvent.Payload {
    .message(MessageData(role: .user, text: text))
}

private let call = YorozuEvent.Payload.toolCall(
    ToolCallData(callId: "c1", name: "shell", args: ["cmd": .string("ls")])
)
private let result = YorozuEvent.Payload.toolResult(
    ToolResultData(callId: "c1", ok: true, output: "README.md")
)

@Test func aDelegationBecomesOneCardThatClosesOnItsLastMessage() {
    let events = [
        event(ask("when am I free?"), id: "ask", agent: "phone"),
        event(.thought(ThoughtData(text: "asking the calendar")), id: "d1", agent: "calendar", parent: "main"),
        event(call, id: "d2", agent: "calendar", parent: "main"),
        event(result, id: "d3", agent: "calendar", parent: "main"),
        event(reply("Tuesday.", done: true), id: "d4", agent: "calendar", parent: "main"),
        event(reply("You are free Tuesday."), id: "answer"),
    ]

    let cards = delegationCards(from: events)
    #expect(cards.count == 1)
    #expect(cards[0].agentId == "calendar")
    #expect(cards[0].id == "d1")
    #expect(cards[0].done)
    #expect(cards[0].events.map(\.id) == ["d1", "d2", "d3", "d4"])
}

@Test func aRunningDelegationStaysRunning() {
    let cards = delegationCards(from: [
        event(call, id: "d1", agent: "calendar", parent: "main"),
        event(reply("half way"), id: "m1"),  // the main agent's, not the specialist's
    ])
    #expect(cards.count == 1)
    #expect(cards[0].done == false)
    #expect(cards[0].events.map(\.id) == ["d1"])
}

@Test func theSameSpecialistTwiceIsTwoCards() {
    let cards = delegationCards(from: [
        event(call, id: "first", agent: "calendar", parent: "main"),
        event(reply("one", done: true), id: "d2", agent: "calendar", parent: "main"),
        event(call, id: "second", agent: "calendar", parent: "main"),
        event(reply("two", done: true), id: "d4", agent: "calendar", parent: "main"),
    ])
    #expect(cards.map(\.id) == ["first", "second"])
    #expect(cards.map(\.done) == [true, true])
}

@Test func twoSpecialistsRunningAtOnceKeepTheirOwnCards() {
    let cards = delegationCards(from: [
        event(call, id: "cal", agent: "calendar", parent: "main"),
        event(call, id: "mail", agent: "email", parent: "main"),
        event(result, id: "cal2", agent: "calendar", parent: "main"),
        event(reply("sent", done: true), id: "mail2", agent: "email", parent: "main"),
    ])
    #expect(cards.map(\.id) == ["cal", "mail"])
    #expect(cards.map(\.done) == [false, true])
}

@Test func onlyDelegatedEventsMakeCards() {
    // The phone's own events carry no parent, and neither do the main agent's.
    #expect(
        delegationCards(from: [
            event(ask("hi"), id: "ask", agent: "phone"),
            event(call, id: "m1"),
            event(result, id: "m2"),
            event(reply("done"), id: "m3"),
        ]).isEmpty
    )
}

@Test func theMainAgentsOwnToolUseIsItsTrace() {
    let events = [
        event(ask("hi"), id: "ask", agent: "phone"),
        event(call, id: "m1"),
        event(result, id: "m2"),
        event(reply("done"), id: "m3"),
        event(call, id: "d1", agent: "calendar", parent: "main"),
    ]
    // Its messages are bubbles in the thread, and a specialist's calls belong to its card.
    #expect(mainTrace(from: events).map(\.id) == ["m1", "m2"])
}

@Test func rowsPutTheCardWhereTheDelegationStarted() {
    let events = [
        event(ask("when am I free?"), id: "ask", agent: "phone"),
        event(call, id: "card", agent: "calendar", parent: "main"),
        event(result, id: "d2", agent: "calendar", parent: "main"),
        event(reply("Tuesday.", done: true), id: "d3", agent: "calendar", parent: "main"),
        event(reply("You are free Tuesday."), id: "answer"),
    ]
    #expect(chatRows(from: events).map(\.id) == ["ask", "card", "answer"])
}

@Test func aTraceTargetReadsItsOwnRowsBack() {
    let events = [
        event(call, id: "m1"),
        event(call, id: "card", agent: "calendar", parent: "main"),
        event(reply("Tuesday.", done: true), id: "d2", agent: "calendar", parent: "main"),
    ]
    #expect(TraceTarget.main.rows(in: events).map(\.id) == ["m1"])
    let card = TraceTarget.delegation(agentId: "calendar", startEventId: "card")
    #expect(card.rows(in: events).map(\.id) == ["card", "d2"])
    #expect(card.title == "calendar")
    // A card that has scrolled out of the thread's history leaves an empty page, not a crash.
    #expect(TraceTarget.delegation(agentId: "calendar", startEventId: "gone").rows(in: events).isEmpty)
}

@Test func toolArgumentsSummariseToOneLine() {
    let data = ToolCallData(
        callId: "c1",
        name: "shell",
        args: ["cmd": .string("ls"), "timeout": .number(30), "quiet": .bool(true)]
    )
    #expect(data.argsSummary == "cmd=ls, quiet=true, timeout=30")

    // Wire data, so nothing here may trap or run off the row.
    let awkward = ToolCallData(
        callId: "c2",
        name: "x",
        args: ["big": .number(.nan), "text": .string(String(repeating: "a", count: 200))]
    )
    #expect(awkward.argsSummary.count == 81)
}
