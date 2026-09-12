import Foundation
import Testing

@testable import YorozuShared

/// Searching one thread: the ranges a bubble highlights and the hits the arrows step through
/// are the same answer read twice, so both are pinned here.

private func message(_ id: String, _ role: MessageData.Role, _ text: String) -> YorozuEvent {
    YorozuEvent(
        id: id,
        threadId: "t",
        ts: 0,
        agentId: "phone",
        payload: .message(MessageData(role: role, text: text))
    )
}

@Test func rangesAreEveryOccurrenceLeftToRightAndNeverOverlap() {
    let text = "the cat sat on the mat"
    let ranges = searchRanges(in: text, term: "the")
    #expect(ranges.count == 2)
    #expect(ranges.map { text.distance(from: text.startIndex, to: $0.lowerBound) } == [0, 15])
    #expect(ranges.allSatisfy { text[$0] == "the" })
    // A repeat inside itself is matched once, not once per overlapping position.
    #expect(searchRanges(in: "aaaa", term: "aa").count == 2)
}

@Test func searchingIgnoresCaseAndAccentsAndAnEmptyTermMatchesNothing() {
    #expect(searchRanges(in: "Café CAFE cafe", term: "cafe").count == 3)
    #expect(searchRanges(in: "anything", term: "").isEmpty)
    // Whitespace is not a search: the field says so the moment it is cleared to a space.
    #expect(searchRanges(in: "anything", term: "   ").isEmpty)
    #expect(searchRanges(in: "anything", term: "missing").isEmpty)
}

@Test func hitsAreInReadingOrderAndCountEveryOccurrenceNotEveryMessage() {
    let events = [
        message("a", .user, "where is the invoice"),
        message("b", .agent, "the invoice is in the Downloads folder"),
        message("c", .agent, "nothing to see"),
    ]
    let hits = searchHits(in: events, term: "the")
    #expect(hits.map(\.eventId) == ["a", "b", "b"])
    #expect(hits.map(\.occurrence) == [0, 0, 1])
    // Two hits in one bubble are two hits, so "2 of 3" means what it says.
    #expect(hits.count == 3)
    #expect(Set(hits.map(\.id)).count == 3)
    #expect(searchHits(in: events, term: "").isEmpty)
}

@Test func highlightingMarksTheRenderedWordRatherThanItsMarkup() {
    let attributed = AttributedString.chatInline("the **total** is due", highlight: "total")
    let plain = String(attributed.characters)
    #expect(plain == "the total is due")
    let marked = attributed.runs.filter { $0.backgroundColor != nil }
    #expect(marked.count == 1)
    #expect(String(attributed[marked[0].range].characters) == "total")
    // Nothing to search for leaves the text exactly as it was rendered.
    let untouched = AttributedString.chatInline("the **total** is due")
    #expect(untouched.runs.allSatisfy { $0.backgroundColor == nil })
}
