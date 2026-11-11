import Foundation
import Testing
import YorozuWire

/// A reply's card in the client's model: taken from a history item, kept across a merge, stored with the conversation.
@Suite struct PresentationStoreTests {
    private let id = "00000000-0000-4000-8000-000000003001"
    private let card = Presentation(title: "Trip costs", tone: .info, blocks: [
        .text("Totals per traveler."),
        .table(.init(caption: "Costs", headers: ["Traveler", "Paid"], rows: [[.string("Traveler A"), .number(120)]], rowHeaderColumnIndex: 0),
            alt: "Costs\nTraveler, Paid\nTraveler A, 120"),
        .unknown(alt: "alt"),
    ])

    private func history(_ presentation: Presentation?) -> ChatItem {
        ChatItem(HistoryItem(kind: .agent, id: id, seq: 2, ts: 20, text: "Here are the costs.", presentation: presentation))
    }

    @Test func historyItemGivesTheChatItemItsCard() {
        let item = history(card)
        #expect(item.presentation == card)
        #expect(item.text == "Here are the costs.")
        #expect(history(nil).presentation == nil)
    }

    /// The plugin no longer stores the card (evicted, or the conversation was deleted there): the local one stays.
    @Test func mergeKeepsALocalCardWhenHistoryHasNone() {
        var conversation = Conversation(id: WireEvent.newId(), createdAt: 1, updatedAt: 1)
        conversation.items = [ChatItem(id: id, kind: .agent, text: "Here are the costs.", ts: 20, presentation: card)]
        conversation.merge([history(nil)])
        #expect(conversation.items.map(\.id) == [id])
        #expect(conversation.items.first?.seq == 2)
        #expect(conversation.items.first?.presentation == card)
    }

    @Test func mergeTakesTheCardHistoryCarries() {
        var conversation = Conversation(id: WireEvent.newId(), createdAt: 1, updatedAt: 1)
        conversation.items = [ChatItem(id: id, kind: .agent, text: "Here are the costs.", ts: 20, presentation: card)]
        let newer = Presentation(blocks: [.text("Newer.")])
        conversation.merge([history(newer)])
        #expect(conversation.items.first?.presentation == newer)
        // A live reply without a card gains the one its history item has.
        conversation.items = [ChatItem(id: id, kind: .agent, text: "Here are the costs.", ts: 20)]
        conversation.merge([history(card)])
        #expect(conversation.items.first?.presentation == card)
    }

    @Test func storedConversationKeepsTheCard() throws {
        var conversation = Conversation(id: WireEvent.newId(), createdAt: 1, updatedAt: 1)
        conversation.items = [history(card)]
        #expect(try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation)) == conversation)
    }

    /// What the reply row shows, in order: a card never hides the reply's text, except a card-only reply's fallback.
    @Test func rowShowsTextThenCard() {
        let item = history(card)
        #expect(Presentation.parts(text: item.text, card: item.presentation) == [.text, .card])
        let cardOnly = ChatItem(id: id, kind: .agent, text: card.fallbackText, ts: 20, presentation: card)
        #expect(cardOnly.text == "Trip costs\n\nTotals per traveler.\n\nCosts\nTraveler, Paid\nTraveler A, 120\n\nalt")
        #expect(Presentation.parts(text: cardOnly.text, card: cardOnly.presentation) == [.card])
        let blank = Presentation(title: "Trip costs", blocks: [.divider, .unknown(alt: nil)])
        #expect(Presentation.parts(text: "Trip costs", card: blank) == [.text])
        #expect(Presentation.parts(text: item.text, card: nil) == [.text])
    }

    /// A conversation stored before cards existed.
    @Test func storedItemWithoutTheFieldDecodes() throws {
        let json = #"{"id":"\#(id)","kind":"agent","text":"Here are the costs.","ts":20,"seq":2}"#
        let item = try JSONDecoder().decode(ChatItem.self, from: Data(json.utf8))
        #expect(item == ChatItem(id: id, kind: .agent, text: "Here are the costs.", ts: 20, seq: 2))
        #expect(item.presentation == nil)
    }
}
