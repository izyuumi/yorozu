import Foundation
import Testing

@testable import YorozuShared

/// When a message stops being a bubble and becomes a document, and how a quoted reply is
/// written down and read back. Both are plain string rules, which is what makes them testable
/// away from the view that asks them.

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

@Test func aQuotedReplyIsOneMessageWithABlockquoteOnTop() {
    #expect(quotedMessage(quoting: "the invoice", body: "which one?") == "> the invoice\n\nwhich one?")
    // Every line of the quote is quoted, and a blank line inside it stays inside it — with no
    // trailing space, which `> ` on an empty line would leave in every reply ever sent.
    #expect(quotedMessage(quoting: "one\n\ntwo", body: "ok") == "> one\n>\n> two\n\nok")
    // A quote with nothing typed yet is still a message: the quote alone.
    #expect(quotedMessage(quoting: "just this", body: "   ") == "> just this")
}

@Test func splittingAQuoteGivesBackWhatWentIn() {
    let message = quotedMessage(quoting: "the invoice\nfrom March", body: "which one?")
    let parts = splitQuote(message)
    #expect(parts.quote == "the invoice\nfrom March")
    #expect(parts.body == "which one?")
    // Prose that never had a quote comes back whole and unclaimed.
    let plain = splitQuote("nothing quoted here\n> not leading")
    #expect(plain.quote == nil)
    #expect(plain.body == "nothing quoted here\n> not leading")
}

@Test func theChipShowsOneLineOfWhateverIsBeingQuoted() {
    #expect(snippet("  many   spaces\nand a line break ") == "many spaces and a line break")
    let long = snippet(String(repeating: "word ", count: 100), limit: 20)
    #expect(long.count == 20)
    #expect(long.hasSuffix("…"))
}
