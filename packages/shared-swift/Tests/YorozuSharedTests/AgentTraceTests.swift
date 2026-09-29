import Foundation
import Testing

@testable import YorozuShared

/// One event in the thread, terse enough that a whole delegation reads as a few lines.
/// Grouping goes by arrival order; timestamps only determine the elapsed-time labels.
private func event(
    _ payload: YorozuEvent.Payload,
    id: String,
    agent: String = "main",
    parent: String? = nil,
    at: Int = 0
) -> YorozuEvent {
    YorozuEvent(
        id: id,
        threadId: "home",
        ts: at,
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

/// A result the Mac cut carries the flag through to the row, and the whole one, arriving later
/// under the same id, replaces it. Claude Code's tool names get glyphs of their own.
@Test func aTruncatedResultIsFlaggedUntilTheWholeOneReplacesIt() throws {
    let cut = event(.toolResult(ToolResultData(callId: "c1", ok: true, output: "head", truncated: true)), id: "r1")
    let whole = event(.toolResult(ToolResultData(callId: "c1", ok: true, output: "head and tail")), id: "r1")
    let bash = event(.toolCall(ToolCallData(callId: "c1", name: "Bash", args: ["command": .string("cat log")])), id: "k1")

    let short = toolActivities(from: [bash, cut])
    #expect(short.map(\.truncated) == [true])
    #expect(short[0].output == "head")
    #expect(short[0].symbol == "terminal")

    let full = toolActivities(from: [bash, whole])
    #expect(full.map(\.truncated) == [false])
    #expect(full[0].output == "head and tail")

    #expect(ToolActivity(callId: "x", name: "Edit", args: [:], startedAt: 0).symbol == "doc")
    #expect(ToolActivity(callId: "x", name: "Grep", args: [:], startedAt: 0).symbol == "magnifyingglass")
    // An older runtime's result, with no flag at all, is whole.
    let legacy = try JSONDecoder().decode(ToolResultData.self, from: Data(#"{"callId":"c","ok":true,"output":"o"}"#.utf8))
    #expect(legacy.truncated == nil)
    #expect(legacy.denied == nil)
}

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

@Test func unreadableDelegatedEventsDoNotStartWorkCards() {
    let future = event(.unknown(kind: "future_kind", data: .object([:])), id: "future", agent: "calendar", parent: "main")
    let unreadableMessage = event(.unknown(kind: "message", data: .object([:])), id: "gap", agent: "calendar", parent: "main")

    #expect(delegationCards(from: [future, unreadableMessage]).isEmpty)
    #expect(chatRows(from: [future]).isEmpty)
    #expect(chatRows(from: [unreadableMessage]).map(\.id) == ["gap"])
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
    // The delegation is the work of that turn, one row between the ask and the answer.
    #expect(chatRows(from: events).map(\.id) == ["ask", "work-card", "answer"])
    guard case .work(let work) = chatRows(from: events)[1] else { return #expect(Bool(false), "expected work") }
    #expect(work.entries.map(\.id) == ["delegation-card"])
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

@Test func toolStatusesFollowResultsAndCards() {
    let call = toolCall("c1", "Bash", args: ["command": .string("git status")])
    let card = event(.approvalCard(ApprovalCardData(actionId: "a1", actionClass: "Bash", target: "git status")), id: "a1")
    let answered = event(.approvalAnswer(ApprovalAnswerData(actionId: "a1", answer: .no)), id: "answer")
    let failed = toolResult("c1", ok: false, output: "denied")

    #expect(toolActivities(from: [call])[0].status() == .running)
    #expect(toolActivities(from: [call])[0].status(active: false) == .pending)
    #expect(toolActivities(from: [call, card])[0].status() == .awaitingApproval)
    let discussed = event(.approvalAnswer(ApprovalAnswerData(actionId: "a1", answer: .discuss)), id: "discuss")
    let newCard = event(.approvalCard(ApprovalCardData(actionId: "a2", actionClass: "Bash", target: "git status")), id: "a2")
    #expect(toolActivities(from: [call, card, discussed, newCard])[0].status() == .awaitingApproval)
    #expect(toolActivities(from: [call, card, answered, failed])[0].status() == .denied)
    #expect(toolActivities(from: [call, failed])[0].status() == .failed)
    let declined = event(.toolResult(ToolResultData(callId: "c1", ok: false, output: "declined", denied: true)), id: "declined")
    #expect(toolActivities(from: [call, declined])[0].status() == .denied)
    #expect(toolActivities(from: [call, toolResult("c1")])[0].status() == .completed)
    #expect(toolActivities(from: [call])[0].currentAction == "Running git status")

    let question = event(.questionCard(QuestionCardData(questionId: "q1", question: "Which?", options: [])), id: "q1")
    let ask = toolCall("ask", "ask_user")
    #expect(toolActivities(from: [ask, question])[0].status() == .awaitingApproval)
    let reply = event(.questionAnswer(QuestionAnswerData(questionId: "q1", answer: "A")), id: "reply")
    #expect(toolActivities(from: [ask, question, reply])[0].status() == .running)
}

@Test func consecutiveCallsSummariseByActionKind() {
    let events = [
        toolCall("r1", "Read"), toolResult("r1"),
        toolCall("r2", "fs_read"), toolResult("r2"),
        toolCall("r3", "read_file"), toolResult("r3"),
        toolCall("c1", "Bash"),
        // A card answered mid-run is part of the call's status, not a break in the run.
        event(.approvalCard(ApprovalCardData(actionId: "a1", actionClass: "Bash", target: "ls")), id: "a1"),
        event(.approvalAnswer(ApprovalAnswerData(actionId: "a1", answer: .yes)), id: "answer"),
        toolResult("c1"),
        toolCall("c2", "shell"), toolResult("c2"),
        toolCall("e1", "Edit"), toolResult("e1"),
    ]
    guard case .tools(let activities) = traceEntries(from: events).first else {
        return #expect(Bool(false), "expected grouped calls")
    }
    #expect(toolSummary(activities) == "Read 3 files, ran 2 commands, changed 1 file")
    #expect(activities.count == 6)
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

    // The progress card and the delegation fold into the work; the question, which needs a
    // person, closes the work and stands on its own below it.
    #expect(rows.map(\.id) == ["u1", "work-job-1", "q1"])
    guard case .work(let work) = rows[1] else { return #expect(Bool(false), "expected work") }
    // The delegation card starts at the question, which is the specialist's first event.
    #expect(work.entries.map(\.id) == ["job-1", "delegation-q1"])
    guard case .question = rows[2] else { return #expect(Bool(false), "expected a question card") }
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

@Test func progressRevisionsWithUniqueSyncIdsShowOnlyTheLatestCard() {
    let first = event(.progressCard(ProgressCardData(cardId: "plan", title: "Progress", steps: [ProgressStep(label: "Inspect", state: .running)])), id: "plan-1")
    let latest = event(.progressCard(ProgressCardData(cardId: "plan", title: "Progress", steps: [ProgressStep(label: "Inspect", state: .done)])), id: "plan-2")
    let rows = chatRows(from: [first, latest])
    #expect(rows.map(\.id) == ["work-plan-2"])
    guard case .work(let work) = rows.first, case .progress(let value) = work.entries.first else {
        return #expect(Bool(false), "expected progress inside the work")
    }
    #expect(work.entries.count == 1)
    #expect(value == latest)
}

@Test func transientStartupStatusUsesOneRowAndLeavesWhenRealWorkArrives() {
    let prompt = event(ask("check this"), id: "u1", agent: "phone")
    let starting = event(.thought(ThoughtData(text: "Starting OpenClaw…", transient: true)), id: "s1")
    let workspace = event(.thought(ThoughtData(text: "preparing workspace…", transient: true)), id: "s2")

    #expect(chatRows(from: [prompt, starting, workspace]).map(\.id) == ["u1", "work-s2"])

    let meaningful = event(.thought(ThoughtData(text: "Checking project files")), id: "t1")
    #expect(chatRows(from: [prompt, starting, workspace, meaningful]).map(\.id) == ["u1", "work-t1"])

    let final = event(reply("Done", done: true), id: "m1")
    #expect(chatRows(from: [prompt, starting, workspace, final]).map(\.id) == ["u1", "m1"])
}

@Test func theMainAgentsWorkBetweenTwoMessagesIsOneRow() {
    let events = [
        event(ask("tidy up"), id: "u1", agent: "phone"),
        toolCall("c1", "shell", args: ["cmd": .string("ls")], at: 1_000),
        toolResult("c1", output: "README.md", at: 1_400),
        event(.thought(ThoughtData(text: "and now the other one")), id: "t1"),
        toolCall("c2", "fs_read", args: ["path": .string("/tmp/x")], at: 2_000),
        toolResult("c2", ok: false, output: "no such file", at: 3_500),
        event(reply("Tidied.", done: true), id: "m1"),
    ]
    let rows = chatRows(from: events)

    // Everything between the ask and the reply is one row, keyed on where the work started.
    #expect(rows.map(\.id) == ["u1", "work-call-c1", "m1"])
    guard case .work(let work) = rows[1] else { return #expect(Bool(false), "expected one work row") }
    // Inside it the order is kept, and the thought keeps the two tool runs apart.
    #expect(work.entries.map(\.id) == ["tools-c1", "t1", "tools-c2"])
    #expect(work.steps == 2)
    #expect(work.failed == 1)
    #expect(work.duration == .milliseconds(3_500))
    // The reply ended the turn, so the work is settled even if the caller says the thread
    // is still generating: nothing after a reply is live.
    #expect(!work.running)
    #expect(!chatRows(from: events, generating: true).contains { if case .work(let w) = $0 { w.running } else { false } })
}

@Test func aFinalReplyRendersAfterToolHistoryThatArrivesLater() {
    let events = [
        event(ask("tidy up"), id: "u1", agent: "phone"),
        event(reply("Tidied.", done: true), id: "m1"),
        toolCall("c1", "shell", args: ["cmd": .string("ls")]),
        toolResult("c1", output: "README.md"),
    ]

    #expect(chatRows(from: events).map(\.id) == ["u1", "work-call-c1", "m1"])
}

@Test func aLateToolReplayDoesNotMoveWorkAcrossTheNextUserMessage() {
    let events = [
        event(ask("first"), id: "u1", agent: "phone"),
        event(reply("First done.", done: true), id: "m1"),
        toolCall("c1", "shell"),
        toolResult("c1"),
        event(ask("second"), id: "u2", agent: "phone"),
        event(reply("Second done.", done: true), id: "m2"),
    ]

    #expect(chatRows(from: events).map(\.id) == ["u1", "work-call-c1", "m1", "u2", "m2"])
}

@Test func aRunningTurnsLastWorkRowIsLiveAndSaysWhatIsHappeningNow() {
    let partial = [
        event(ask("tidy up"), id: "u1", agent: "phone"),
        event(.thought(ThoughtData(text: "Having a look")), id: "t1"),
        toolCall("c1", "shell", args: ["cmd": .string("ls")]),
    ]
    let rows = chatRows(from: partial, generating: true)
    #expect(rows.map(\.id) == ["u1", "work-t1"])
    guard case .work(let work) = rows[1] else { return #expect(Bool(false), "expected work") }
    #expect(work.running)
    // The newest thing is the status: the running tool, not the thought before it.
    #expect(work.status == "Running ls")

    // A progress card's title is written to be read, so it wins while it is the newest.
    let withProgress = partial + [event(
        .progressCard(ProgressCardData(cardId: "job", title: "Sorting the files", steps: [], percent: 40)),
        id: "p1"
    )]
    guard case .work(let progressing) = chatRows(from: withProgress, generating: true)[1] else {
        return #expect(Bool(false), "expected work")
    }
    #expect(progressing.status == "Sorting the files · 40%")
    // The card's steps only move when reported, so the live line under it is what ran last.
    #expect(progressing.activity == "Running ls")

    // Not generating: the same events are a settled row, however unfinished they look.
    guard case .work(let settled) = chatRows(from: partial)[1] else { return #expect(Bool(false), "expected work") }
    #expect(!settled.running)
}

@Test func aCardThatNeedsAPersonClosesTheWorkAndStandsBelowIt() {
    let rows = chatRows(from: [
        event(ask("send it"), id: "u1", agent: "phone"),
        toolCall("c1", "shell"),
        event(.approvalCard(ApprovalCardData(actionId: "a1", actionClass: "send-message", target: "bob")), id: "a1"),
        // After the answer the agent carries on: a second run of work, then the reply.
        toolCall("c2", "mail_send"),
        toolResult("c2"),
        event(reply("Sent.", done: true), id: "m1"),
    ], generating: true)

    #expect(rows.map(\.id) == ["u1", "work-call-c1", "a1", "work-call-c2", "m1"])
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
    #expect(rows.map(\.id) == ["work-d1", "m1"])
    guard case .work(let work) = rows[0] else { return #expect(Bool(false), "expected work") }
    #expect(work.entries.map(\.id) == ["delegation-d1"])
    // The specialist's one call counts as a step of the turn's work.
    #expect(work.steps == 1)
}

/// A rule proposal is a row of its own, drawn where it was raised, and it survives an export:
/// it is the one card that is not about permission but about what Yorozu noticed.
@Test func aRuleProposalIsARowOfItsOwn() {
    let rule = ApprovalRule(
        id: "r1",
        actionClass: "purchase",
        decision: .always,
        scope: ["merchant": ApprovalRuleField(mode: .exact, value: "Kurasu")]
    )
    let events = [
        YorozuEvent(id: "m1", threadId: "t", ts: 1, agentId: "phone",
            payload: .message(MessageData(role: .user, text: "reorder the coffee"))),
        YorozuEvent(id: "p1", threadId: "t", ts: 2, agentId: "main",
            payload: .ruleProposal(RuleProposalData(proposalId: "prop1", rule: rule, approvals: 3))),
    ]

    #expect(chatRows(from: events).map(\.id) == ["m1", "p1"])
    guard case .proposal(let event) = chatRows(from: events)[1] else {
        Issue.record("the proposal should be a row of its own")
        return
    }
    #expect(event.id == "p1")

    let markdown = threadMarkdown(
        thread: ThreadSummary(id: "t", title: "Coffee", archived: false, lastActivity: 2),
        events: events
    )
    #expect(markdown.contains("**Rule suggested** — purchase at Kurasu"))
}


@Test func reasoningOpensWhileStreamingAndSettlesAtTheNextActivity() throws {
    let prompt = event(ask("inspect"), id: "ask", at: 1_000)
    let thought = event(.thought(ThoughtData(text: "Checking the code")), id: "thought", at: 2_000)
    let live = chatRows(from: [prompt, thought], generating: true, activeEventId: "ask")
    guard case .work(let work) = live[1], case .thought(let reasoning) = work.entries[0] else {
        Issue.record("expected reasoning in the work row")
        return
    }
    #expect(reasoning.running)
    #expect(reasoning.label == "Thinking…")
    #expect(reasoning.text == "Checking the code")
    #expect(work.label(at: Date(timeIntervalSince1970: 10)) == "Working for 9s")
    #expect(work.label(at: Date(timeIntervalSince1970: 11)) == "Working for 10s")

    let rows = chatRows(from: [prompt, thought, toolCall("read", "Read", at: 7_000)], generating: true, activeEventId: "ask")
    guard case .work(let next) = rows[1], case .thought(let settled) = next.entries[0] else {
        Issue.record("expected settled reasoning")
        return
    }
    #expect(next.running)
    #expect(!settled.running)
    #expect(settled.label == "Thought for 5 s")
    #expect(settled.id == reasoning.id)
}

@Test func finishedWorkIncludesTheReplyTimeAndStaysLiveUntilTheHostSettles() throws {
    let events = [
        event(ask("inspect"), id: "ask", at: 1_000),
        event(.thought(ThoughtData(text: "Checking")), id: "thought", at: 2_000),
        event(reply("Done", done: true), id: "reply", at: 193_000),
    ]
    guard case .work(let live) = chatRows(from: events, generating: true, activeEventId: "ask")[1],
          case .work(let done) = chatRows(from: events)[1],
          case .thought(let thought) = done.entries[0] else {
        Issue.record("expected work before the reply")
        return
    }
    #expect(live.running)
    #expect(live.label(at: Date(timeIntervalSince1970: 194)) == "Working for 3m 13s")
    #expect(!done.running)
    #expect(done.label() == "Worked for 3m 12s")
    #expect(!thought.running)
    #expect(thought.label == "Thought for 191 s")
    #expect(chatRows(from: events).map(\.id) == ["ask", "work-thought", "reply"])
}

@Test(arguments: [StopStatusData.Status.stopped, .completed, .requested, .withdrawn, .unknown, .unconfirmed])
func turnFoldUsesTheTargetedStopOutcome(_ status: StopStatusData.Status) throws {
    let events = [
        event(ask("inspect"), id: "ask", at: 1_000),
        event(.thought(ThoughtData(text: "Checking")), id: "thought", at: 2_000),
        event(reply("Partial", done: true), id: "reply", at: 41_000),
        event(ask("next"), id: "next", at: 42_000),
        toolCall("read", "Read", at: 43_000),
        // A delayed status belongs to the old turn, never the one now running.
        event(.stopStatus(StopStatusData(targetEventId: "ask", requestId: "stop", status: status)), id: "status", at: 200_000),
    ]
    let rows = chatRows(from: events, generating: true, activeEventId: "next")
    let works = rows.compactMap { row -> TurnWork? in
        if case .work(let work) = row { return work }
        return nil
    }
    #expect(works.count == 2)
    let first = try #require(works.first)
    let last = try #require(works.last)
    let expected = status == .stopped ? "You stopped after 40s" :
        status == .unconfirmed ? "Stop unconfirmed after 40s" : "Worked for 40s"
    #expect(first.label() == expected)
    #expect(!first.running)
    #expect(last.running)
    #expect(last.stopStatus == nil)
    #expect(last.label(at: Date(timeIntervalSince1970: 45)) == "Working for 3s")
}

@Test func stoppingReasoningWithoutAReplyFreezesItsDuration() throws {
    let events = [
        event(ask("inspect"), id: "ask", at: 1_000),
        event(.thought(ThoughtData(text: "Checking")), id: "thought", at: 2_000),
        event(.stopStatus(StopStatusData(targetEventId: "ask", requestId: "stop", status: .stopped)), id: "status", at: 41_000),
    ]
    guard case .work(let stopped) = chatRows(from: events, generating: true, activeEventId: "ask")[1],
          case .thought(let thought) = stopped.entries[0] else {
        Issue.record("expected stopped reasoning")
        return
    }
    #expect(!stopped.running)
    #expect(stopped.label(at: Date(timeIntervalSince1970: 500)) == "You stopped after 40s")
    #expect(!thought.running)
    #expect(thought.label == "Thought for 39 s")
}

@Test func anAdmittedTurnHasATimerBeforeAnyAgentOutput() throws {
    let prompt = event(ask("inspect"), id: "ask", at: 1_000)
    guard case .work(let work) = chatRows(from: [prompt], generating: true, activeEventId: "ask").last else {
        Issue.record("expected a live work timer")
        return
    }
    #expect(work.running)
    #expect(work.label(at: Date(timeIntervalSince1970: 4)) == "Working for 3s")
    #expect(work.label(at: Date(timeIntervalSince1970: 0)) == "Working for 0s")
    #expect(chatRows(from: [prompt]).map(\.id) == ["ask"])
}

@Test func stoppingBeforeAnyActivityStillLeavesAStoppedFold() {
    let events = [
        event(ask("inspect"), id: "ask", at: 1_000),
        event(reply("", done: true), id: "reply", at: 41_000),
        event(.stopStatus(StopStatusData(targetEventId: "ask", requestId: "stop", status: .stopped)), id: "status", at: 50_000),
    ]
    let rows = chatRows(from: events)
    #expect(rows.map(\.id) == ["ask", "work-ask", "reply"])
    guard case .work(let work) = rows[1] else {
        Issue.record("expected a stopped fold even with no trace")
        return
    }
    #expect(work.label() == "You stopped after 40s")
    #expect(!work.running)
}
