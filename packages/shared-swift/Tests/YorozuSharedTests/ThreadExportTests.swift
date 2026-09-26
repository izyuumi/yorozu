import Foundation
import Testing

@testable import YorozuShared

private let utc = TimeZone(identifier: "UTC")!
private let posix = Locale(identifier: "en_US_POSIX")

/// The same stamp the export writes, so the test asserts on the structure around it rather than
/// on how this OS spells "1:46 PM" — that changed once already, and it is not what is under test.
private func stamp(_ seconds: Int) -> String {
    var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
    style.locale = posix
    style.timeZone = utc
    return Date(timeIntervalSince1970: Double(seconds)).formatted(style)
}

private func event(
    _ id: String,
    _ payload: YorozuEvent.Payload,
    at seconds: Int,
    agent: String = "main",
    parent: String? = nil
) -> YorozuEvent {
    YorozuEvent(
        id: id,
        threadId: "home",
        ts: seconds * 1000,
        agentId: agent,
        parentAgentId: parent,
        payload: payload
    )
}

@Test func aThreadExportsAsATranscriptWithItsToolUseFoldedAway() {
    let thread = ThreadSummary(id: "home", title: "Invoices", archived: false, lastActivity: 0)
    let events = [
        event("m1", .message(MessageData(role: .user, text: "find the invoice")), at: 1_000_000),
        event("c1", .toolCall(ToolCallData(callId: "c1", name: "fs_find", args: ["q": .string("invoice")])), at: 1_000_001),
        event("r1", .toolResult(ToolResultData(callId: "c1", ok: true, output: "one hit")), at: 1_000_002),
        event("m2", .message(MessageData(role: .agent, text: "Found it.", done: true)), at: 1_000_003),
    ]

    let markdown = threadMarkdown(
        thread: thread,
        events: events,
        now: Date(timeIntervalSince1970: 1_000_100),
        locale: posix,
        timeZone: utc
    )

    // Title, when it was exported, and one heading per message saying who and when.
    #expect(markdown.hasPrefix("# Invoices\n"))
    #expect(markdown.contains("*Exported \(stamp(1_000_100))*"))
    #expect(markdown.contains("## You — \(stamp(1_000_000))"))
    #expect(markdown.contains("## Yorozu — \(stamp(1_000_003))"))
    #expect(markdown.contains("find the invoice"))
    #expect(markdown.contains("Found it."))
    // The tool run is kept but folded, between the question and the answer where it happened.
    #expect(markdown.contains("<details><summary>Ran fs_find</summary>"))
    #expect(markdown.contains("- `fs_find` (q=invoice) — ok"))
    #expect(markdown.contains("</details>"))
    let tools = try! #require(markdown.range(of: "<details>"))
    #expect(markdown.range(of: "Found it.")!.lowerBound > tools.lowerBound)
    #expect(markdown.hasSuffix("\n"))
}

@Test func anEmptyThreadStillExportsItsTitleAndAnAttachmentIsNoted() {
    let thread = ThreadSummary(id: "home", title: "", archived: false, lastActivity: 0)
    let empty = threadMarkdown(thread: thread, events: [], locale: posix, timeZone: utc)
    // An untitled thread exports under the name the list draws it with.
    #expect(empty.hasPrefix("# New chat\n"))

    let photo = MessageAttachment(name: "receipt.png", mime: "image/png", data: "aGVsbG8=")
    let second = MessageAttachment(name: "kitchen.jpg", mime: "image/jpeg", data: "aGVsbG8=")
    let withPhoto = threadMarkdown(
        thread: thread,
        events: [
            event("m1", .message(MessageData(role: .user, text: "", attachments: [photo, second])), at: 0)
        ],
        locale: posix,
        timeZone: utc
    )
    // Every one of them is named, in the order they were sent.
    #expect(withPhoto.contains("*Attached: receipt.png (5 bytes)*"))
    #expect(withPhoto.contains("*Attached: kitchen.jpg (5 bytes)*"))
    // A photo with no words says so rather than leaving a heading with nothing under it.
    #expect(withPhoto.contains("*(no text)*"))
}

@Test func stoppedRepliesExportPartialTextAndAStopMarker() {
    let thread = ThreadSummary(id: "home", title: "Work", archived: false, lastActivity: 0)
    let markdown = threadMarkdown(thread: thread, events: [
        event("m1", .message(MessageData(role: .agent, text: "Working", done: true, interrupted: true)), at: 1),
        event("m2", .message(MessageData(role: .agent, text: "", done: true, interrupted: true)), at: 2)
    ], locale: posix, timeZone: utc)
    #expect(markdown.contains("Working\n\n*Stopped*"))
    #expect(markdown.components(separatedBy: "*Stopped*").count == 3)
    #expect(!markdown.contains("*(no text)*"))
}

@Test func aDelegationExportsAsOneFoldedNoteUnderItsSpecialist() {
    let thread = ThreadSummary(id: "home", title: "Trip", archived: false, lastActivity: 0)
    let markdown = threadMarkdown(
        thread: thread,
        events: [
            event("d1", .message(MessageData(role: .agent, text: "Booked the 9:05.", done: true)), at: 0, agent: "travel", parent: "main"),
            event("m1", .message(MessageData(role: .agent, text: "All set.", done: true)), at: 1),
        ],
        locale: posix,
        timeZone: utc
    )

    #expect(markdown.contains("<details><summary>Delegated to travel</summary>"))
    #expect(markdown.contains("Booked the 9:05."))
    // The specialist's work is behind the note; the main agent's reply is the transcript.
    #expect(markdown.contains("## Yorozu — "))
    #expect(markdown.contains("All set."))
}

@Test func anExportedFileIsNamedAfterTheThreadAndIsSafeToWrite() {
    #expect(ThreadMarkdown(title: "Invoices", text: "").filename == "Invoices.md")
    #expect(ThreadMarkdown(title: "9/12 plans: q?", text: "").filename == "9-12 plans- q-.md")
    #expect(ThreadMarkdown(title: "   ", text: "").filename == "Thread.md")
    #expect(ThreadMarkdown(title: String(repeating: "x", count: 200), text: "").filename.count == 63)
}
