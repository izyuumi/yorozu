import Foundation
import Testing

@testable import YorozuShared

/// When a message stops being a bubble and becomes a document, and how a quoted reply is
/// written down and read back. Both are plain string rules, which is what makes them testable
/// away from the view that asks them.

@Test func aMessageIsOnlyLongEnoughToReadElsewhereWhenItIsReallyLong() {
    #expect(!needsReader("short"))
    #expect(!needsReader(String(repeating: "a", count: readerCharacterLimit)))
    #expect(needsReader(String(repeating: "a", count: readerCharacterLimit + 1)))
    // Lines count too: a wall of short ones is just as unreadable in a bubble.
    let lines = Array(repeating: "x", count: readerLineLimit).joined(separator: "\n")
    #expect(!needsReader(lines))
    #expect(needsReader(lines + "\nx"))
}

@Test func theExcerptStopsAtTheLineLimitAndSaysThatItDid() {
    let long = (1...50).map { "line \($0)" }.joined(separator: "\n")
    let excerpt = readerExcerpt(long)
    #expect(excerpt.hasSuffix("…"))
    #expect(excerpt.contains("line 30"))
    #expect(!excerpt.contains("line 31"))
    // A message that fits comes back untouched — no ellipsis on something that was not cut.
    #expect(readerExcerpt("hello") == "hello")
}

@Test func theExcerptCutsOnAWordAndNotThroughOne() {
    let prose = String(repeating: "alpha beta ", count: 200)
    let excerpt = readerExcerpt(prose)
    #expect(excerpt.count <= readerCharacterLimit + 1)
    #expect(excerpt.hasSuffix("alpha…") || excerpt.hasSuffix("beta…"))
    // One unbroken run has no word to cut on, so the hard cut is all there is.
    #expect(readerExcerpt(String(repeating: "z", count: 2000)).count == readerCharacterLimit + 1)
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
