import Foundation
import Testing
@testable import YorozuWire

struct PresentationFallbackTests {
    private func fixtureCard() throws -> Presentation {
        guard case .reply(let reply) = try GenUIFixture.event("reply") else { throw CocoaError(.coderInvalidValue) }
        return try #require(reply.presentation)
    }

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

    @Test func unknownBlocksAndMissingTitle() throws {
        let card = Presentation(blocks: [.divider, .unknown(alt: "Gauge: 3"), .unknown(alt: ""), .unknown(alt: nil), .context("Note")])
        #expect(card.fallbackText == "Gauge: 3\n\nNote")
        #expect(card.isFallback(for: "Gauge: 3\n\nNote"))
        #expect(!card.isFallback(for: "Gauge: 3"))
        #expect(!Presentation(blocks: [.divider]).isFallback(for: ""))
    }

    @Test func truncatedFallback() {
        let card = Presentation(title: "T", blocks: [.text(String(repeating: "a", count: 40_000))])
        let text = "T\n\n" + String(repeating: "a", count: 32768 - 14 - 3) + "…(truncated)"
        #expect(text.utf8.count == 32768)
        #expect(card.isFallback(for: text))
        #expect(!card.isFallback(for: String(text.dropLast(12))))
        let emoji = Presentation(blocks: [.text(String(repeating: "a", count: 32752) + "😀")])
        #expect(emoji.fallbackText == String(repeating: "a", count: 32752) + "…(truncated)")
    }

    @Test func cardThatDoesNotRenderShowsTextOnly() {
        let card = Presentation(title: "T", blocks: [.divider, .unknown(alt: nil)])
        #expect(!card.renders)
        #expect(Presentation.parts(text: "T", card: card) == [.text])
        #expect(Presentation.parts(text: "Hi", card: nil) == [.text])
        #expect(Presentation.parts(text: "", card: nil) == [])
    }
}
