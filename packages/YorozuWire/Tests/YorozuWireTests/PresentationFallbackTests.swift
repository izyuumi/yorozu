import Foundation
import Testing
@testable import YorozuWire

/// A card-only reply's text is the card's fallback (the plugin's `fallback()`): the card alone shows; any other text
/// shows in its bubble above the card.
struct PresentationFallbackTests {
    private func fixtureCard() throws -> Presentation {
        guard case .reply(let reply) = try GenUIFixture.event("reply") else { throw CocoaError(.coderInvalidValue) }
        return try #require(reply.presentation)
    }

    /// The fixture's card as the plugin would send it with empty text: title, then each non-empty alt (the divider's is "").
    @Test func cardOnlyReplyTextIsTheFallback() throws {
        let card = try fixtureCard()
        let text = "Trip costs\n\nTotals per traveler.\n\nCosts\nTraveler, Paid\nTraveler A, 120\nTraveler B, 80\n\nPaid\nPaid: 120, 80\n\nAs of today."
        #expect(card.fallbackText == text)
        #expect(card.isFallback(for: text))
        #expect(Presentation.parts(text: text, card: card) == [.card])
    }

    @Test func replyWithItsOwnTextShowsTextThenCard() throws {
        let card = try fixtureCard()
        #expect(!card.isFallback(for: "Here are the costs."))
        #expect(Presentation.parts(text: "Here are the costs.", card: card) == [.text, .card])
        #expect(Presentation.parts(text: "", card: card) == [.card])
    }

    /// Blocks that fell back keep their wire alt in the fallback; empty or missing alts and no title are skipped.
    @Test func unknownBlocksAndMissingTitle() throws {
        let card = Presentation(blocks: [.divider, .unknown(alt: "Gauge: 3"), .unknown(alt: ""), .unknown(alt: nil), .context("Note")])
        #expect(card.fallbackText == "Gauge: 3\n\nNote")
        #expect(card.isFallback(for: "Gauge: 3\n\nNote"))
        #expect(!card.isFallback(for: "Gauge: 3"))
        #expect(!Presentation(blocks: [.divider]).isFallback(for: ""))
    }

    /// Over 32768 bytes of UTF-8 the plugin cuts by code point, leaving room for the marker.
    @Test func truncatedFallback() {
        let card = Presentation(title: "T", blocks: [.text(String(repeating: "a", count: 40_000))])
        let text = "T\n\n" + String(repeating: "a", count: 32768 - 14 - 3) + "…(truncated)"
        #expect(text.utf8.count == 32768)
        #expect(card.isFallback(for: text))
        #expect(!card.isFallback(for: String(text.dropLast(12))))
        // A 4-byte scalar that would cross the limit isn't split.
        let emoji = Presentation(blocks: [.text(String(repeating: "a", count: 32752) + "😀")])
        #expect(emoji.fallbackText == String(repeating: "a", count: 32752) + "…(truncated)")
    }

    /// A card that draws nothing leaves the text, even its fallback, in the bubble.
    @Test func cardThatDoesNotRenderShowsTextOnly() {
        let card = Presentation(title: "T", blocks: [.divider, .unknown(alt: nil)])
        #expect(!card.renders)
        #expect(Presentation.parts(text: "T", card: card) == [.text])
        #expect(Presentation.parts(text: "Hi", card: nil) == [.text])
        #expect(Presentation.parts(text: "", card: nil) == [])
    }
}
