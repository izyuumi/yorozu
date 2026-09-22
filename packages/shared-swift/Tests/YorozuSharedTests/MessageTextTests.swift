import Foundation
import Testing

@testable import YorozuShared

/// When a message stops being a bubble and becomes a document: a plain string rule, which is
/// what makes it testable away from the view that asks it.

@Test func aMessageIsOnlyLongEnoughToReadElsewhereWhenItIsReallyLong() {
    #expect(!needsReader("short"))
    // Lines count: a wall of short ones is unreadable in a bubble.
    let lines = Array(repeating: "x", count: readerLineLimit).joined(separator: "\n")
    #expect(!needsReader(lines))
    #expect(needsReader(lines + "\nx"))
    // Characters count too, once there is a line boundary to cut on.
    let paragraphs = Array(repeating: String(repeating: "a", count: 500), count: 3).joined(separator: "\n")
    #expect(needsReader(paragraphs))
}

@Test func theExcerptStopsAtTheLineLimit() {
    let long = (1...50).map { "line \($0)" }.joined(separator: "\n")
    let excerpt = readerExcerpt(long)
    #expect(excerpt.hasSuffix("line 30"))
    #expect(!excerpt.contains("line 31"))
    // A message that fits comes back untouched.
    #expect(readerExcerpt("hello") == "hello")
}

@Test func theExcerptCutsBetweenLinesAndNeverInsideOne() {
    let line = String(repeating: "alpha beta ", count: 50)
    let excerpt = readerExcerpt([line, line, line].joined(separator: "\n"))
    // Whole lines only: the third line would cross the character limit, so it is dropped
    // entirely rather than cut, and the two before it are on screen intact with no ellipsis.
    #expect(excerpt == [line, line].joined(separator: "\n").trimmingCharacters(in: .whitespaces))
    #expect(!excerpt.contains("…"))
    // One enormous line has no boundary to cut on, so it is drawn whole rather than cut.
    let single = String(repeating: "z", count: 2000)
    #expect(readerExcerpt(single) == single)
    #expect(!needsReader(single))
}
