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
    #expect(chatRows(from: events).map(\.id) == ["ask", "delegation-card", "answer"])
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

/// Tool calls and the results that answered them, in one row each. `ts` carries the duration
/// here, which is the one place in these tests it means anything.
private func toolCall(_ id: String, _ name: String, args: [String: JSONValue] = [:], at ts: Int = 0) -> YorozuEvent {
    YorozuEvent(
        id: "call-\(id)",
        threadId: "home",
        ts: ts,
        agentId: "main",
        payload: .toolCall(ToolCallData(callId: id, name: name, args: args))
    )
}

private func toolResult(_ id: String, ok: Bool = true, output: String = "", at ts: Int = 0) -> YorozuEvent {
    YorozuEvent(
        id: "result-\(id)",
        threadId: "home",
        ts: ts,
        agentId: "main",
        payload: .toolResult(ToolResultData(callId: id, ok: ok, output: output))
    )
}

@Test func aToolCallAndItsResultAreOneActivity() {
    let activities = toolActivities(from: [
        toolCall("c1", "shell", args: ["cmd": .string("ls")], at: 1_000),
        toolResult("c1", output: "README.md", at: 1_250),
        // Still in flight: no result has come back for it yet.
        toolCall("c2", "fs_read", args: ["path": .string("/tmp/x")], at: 1_300),
        // A result for a call that is not in this trace belongs to another one.
        toolResult("stray", output: "nobody asked"),
    ])

    #expect(activities.map(\.name) == ["shell", "fs_read"])
    #expect(activities[0].output == "README.md")
    #expect(activities[0].duration == .milliseconds(250))
    #expect(!activities[0].running)
    #expect(activities[1].running)
    #expect(activities[1].duration == nil)
    #expect(activities[0].argsSummary == "cmd=ls")
    #expect(activities[1].argsDetail == "path: /tmp/x")
}

/// The two stamps come off the same machine, but a clock that stepped back between them is
/// not a reason to draw a negative duration.
@Test func aResultThatArrivedBeforeItsCallTakesNoTime() {
    let activities = toolActivities(from: [toolCall("c1", "shell", at: 500), toolResult("c1", at: 100)])
    #expect(activities.first?.duration == .zero)
}

@Test func aToolPicksUpTheSymbolOfItsFamily() {
    let symbols = [
        "shell": "terminal",
        "fs_write": "doc",
        "browser.open": "globe",
        "web_search": "globe",
        "calendar_create": "calendar",
        "reminders_list": "calendar",
        "mail_send": "envelope",
        "request_permission": "hand.raised",
        "ask_user": "questionmark.bubble",
        "report_progress": "list.bullet",
        "echo": "wrench.and.screwdriver",
    ]
    for (name, symbol) in symbols {
        #expect(toolActivities(from: [toolCall("c", name)]).first?.symbol == symbol)
    }
}

@Test func consecutiveToolUseIsOneGroupAndAnythingElseBreaksTheRun() {
    let entries = traceEntries(from: [
        event(.thought(ThoughtData(text: "having a look")), id: "t1"),
        toolCall("c1", "shell"),
        toolResult("c1"),
        toolCall("c2", "fs_read"),
        toolResult("c2"),
        event(.thought(ThoughtData(text: "now then")), id: "t2"),
        toolCall("c3", "fs_write"),
    ])

    // Two runs of tool use, with the thought between them keeping them apart: the results
    // never break a run of their own, because each is folded into the call it answered.
    #expect(entries.count == 4)
    guard case .tools(let first) = entries[1], case .tools(let second) = entries[3] else {
        return #expect(Bool(false), "expected two groups of tool activity")
    }
    #expect(first.map(\.name) == ["shell", "fs_read"])
    #expect(second.map(\.name) == ["fs_write"])
    #expect(second[0].running)
    if case .other(let event) = entries[0], case .thought(let data) = event.payload {
        #expect(data.text == "having a look")
    } else {
        #expect(Bool(false), "expected the thought to lead")
    }
}

@Test func aTraceWithNoToolUseIsJustItsEvents() {
    let entries = traceEntries(from: [event(reply("done"), id: "m1")])
    #expect(entries.count == 1)
    #expect(traceEntries(from: []).isEmpty)
}

@Test func aQuestionAndAProgressCardAreRowsOfTheirOwnWhereverTheyWereRaised() {
    let rows = chatRows(from: [
        event(ask("book me a table"), id: "u1"),
        event(
            .progressCard(
                ProgressCardData(
                    cardId: "job-1",
                    title: "Booking the table",
                    steps: [ProgressStep(label: "call them", state: .running)]
                )
            ),
            id: "job-1"
        ),
        // Raised inside a delegation: the specialist is parked on it, so burying it behind
        // the delegation's card would stall the turn with nothing on screen to answer.
        event(
            .questionCard(QuestionCardData(questionId: "q1", question: "Which one?", options: ["a", "b"])),
            id: "q1",
            agent: "reservation",
            parent: "main"
        ),
        event(reply("booked", done: true), id: "m1", agent: "reservation", parent: "main"),
    ])

    #expect(rows.map(\.id) == ["u1", "job-1", "delegation-q1", "q1"])
    // The delegation card starts at the question, which is the specialist's first event.
    guard case .delegation = rows[2] else { return #expect(Bool(false), "expected a delegation card") }
    guard case .question = rows[3] else { return #expect(Bool(false), "expected a question card") }
}

@Test func aUnifiedDiffIsReadAsOneAndAnythingElseIsLeftAlone() throws {
    let diff = try #require(
        unifiedDiff(
            in: """
            --- a/agents/calendar.md
            +++ b/agents/calendar.md
            @@ -1,3 +1,3 @@
             ---
            -model: old-model
            +model: new-model
             ---
            """
        )
    )
    #expect(diff.added == 1)
    #expect(diff.removed == 1)
    #expect(diff.counts == "+1 −1")
    // The file headers are marked with three of the character, so they are not counted as a
    // line added and a line removed.
    #expect(diff.lines.map(\.kind) == [.meta, .meta, .meta, .context, .removed, .added, .context])

    // Hunks on their own are a diff too: plenty of tools print them without the headers.
    #expect(unifiedDiff(in: "@@ -1 +1 @@\n-a\n+b")?.counts == "+1 −1")

    // A `+` at the start of a line is ordinary enough in ordinary output; the hunk header is
    // what decides it, so this is a shell result and not a diff.
    #expect(unifiedDiff(in: "+ install done\n- nothing to remove") == nil)
    #expect(unifiedDiff(in: "wrote 41 characters to /tmp/x") == nil)
    #expect(unifiedDiff(in: "") == nil)
}

@Test func theMainAgentsToolUseIsGroupedIntoTheThreadWhereItHappened() {
    let rows = chatRows(from: [
        event(ask("tidy up"), id: "u1", agent: "phone"),
        toolCall("c1", "shell", args: ["cmd": .string("ls")]),
        toolResult("c1", output: "README.md"),
        // A thought the thread does not draw must not split one run of tool use into two.
        event(.thought(ThoughtData(text: "and now the other one")), id: "t1"),
        toolCall("c2", "fs_read", args: ["path": .string("/tmp/x")]),
        toolResult("c2", output: "hi"),
        event(reply("Tidied.", done: true), id: "m1"),
    ])

    #expect(rows.map(\.id) == ["u1", "tools-c1", "m1"])
    guard case .tools(let activities) = rows[1] else {
        return #expect(Bool(false), "expected one group of tool activity")
    }
    #expect(activities.map(\.name) == ["shell", "fs_read"])
}

/// A specialist's tool use belongs to its card, not to the thread: the thread would otherwise
/// show the same work twice, once inline and once behind the delegation.
@Test func aSpecialistsToolUseStaysBehindItsCard() {
    let rows = chatRows(from: [
        event(call, id: "d1", agent: "calendar", parent: "main"),
        event(result, id: "d2", agent: "calendar", parent: "main"),
        event(reply("Tuesday.", done: true), id: "d3", agent: "calendar", parent: "main"),
        event(reply("You are free Tuesday.", done: true), id: "m1"),
    ])
    #expect(rows.map(\.id) == ["delegation-d1", "m1"])
}
