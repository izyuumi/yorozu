import Foundation
import Testing
@testable import YorozuWire

/// Cards (capability `presentation`): the plugin's exact output from the shared fixture, and the tolerant reader's
/// rules for what it can't check.
struct PresentationTests {
    private func fixture(_ name: String) throws -> WireEvent {
        let url = try #require(Bundle.module.url(forResource: "genui-wire", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        return try JSONDecoder().decode(WireEvent.self, from: Data(try #require(fixture[name]).utf8))
    }

    private let ids = #""convId":"00000000-0000-4000-8000-000000003000","messageId":"00000000-0000-4000-8000-000000003001""#

    /// A reply with `text` "Hello" and the given JSON as its `presentation`.
    private func reply(presentation json: String) throws -> Reply {
        let event = try JSONDecoder().decode(WireEvent.self,
            from: Data(#"{"kind":"reply","data":{\#(ids),"text":"Hello","ts":1,"presentation":\#(json)}}"#.utf8))
        guard case .reply(let reply) = event else { throw CocoaError(.coderInvalidValue) }
        return reply
    }

    private func card(blocks json: String) throws -> Presentation {
        try #require(try reply(presentation: #"{"blocks":[\#(json)]}"#).presentation)
    }

    @Test func fixtureReplyDecodesEveryBlockAndTheSameText() throws {
        guard case .reply(let reply) = try fixture("reply") else {
            Issue.record("not a reply")
            return
        }
        #expect(reply.text == "Here are the costs.")
        let card = try #require(reply.presentation)
        #expect(card.title == "Trip costs")
        #expect(card.tone == .info)
        let table = Presentation.Table(caption: "Costs", headers: ["Traveler", "Paid"],
            rows: [[.string("Traveler A"), .number(120)], [.string("Traveler B"), .number(80)]], rowHeaderColumnIndex: 0)
        let chart = Presentation.Chart(title: "Paid", chartType: .bar, categories: ["Traveler A", "Traveler B"],
            series: [.init(name: "Paid", values: [120, 80])])
        #expect(card.blocks == [
            .text("Totals per traveler."),
            .divider,
            .table(table, alt: "Costs\nTraveler, Paid\nTraveler A, 120\nTraveler B, 80"),
            .chart(chart, alt: "Paid\nPaid: 120, 80"),
            .context("As of today."),
        ])
        #expect(table.rowHeader == 0)
        #expect(card.drawn == card.blocks)
        #expect(card.renders)
        #expect(card.fellBack == 0)
    }

    @Test func fixtureHistoryItemCarriesTheCard() throws {
        guard case .history(let page) = try fixture("history"), case .reply(let reply) = try fixture("reply") else {
            Issue.record("not a history page and a reply")
            return
        }
        #expect(page.items.map(\.text) == ["Show me the costs", "Here are the costs."])
        #expect(page.items.first?.presentation == nil)
        #expect(page.items.last?.presentation == reply.presentation)
        #expect(reply.presentation != nil)
    }

    /// New app, old plugin: no field, no card, no error.
    @Test func replyWithoutPresentationDecodesWithoutACard() throws {
        guard case .reply(let reply) = try fixture("replyOldApp") else {
            Issue.record("not a reply")
            return
        }
        #expect(reply.text == "Here are the costs.")
        #expect(reply.presentation == nil)
    }

    @Test func pieAndLineAndAreaChartsDecode() throws {
        let card = try card(blocks: """
            {"type":"chart","chartType":"pie","title":"Share","segments":[{"label":"A","value":3},{"label":"B","value":1}],"alt":"Share"},
            {"type":"chart","chartType":"line","title":"Trend","categories":["Mon","Tue"],"series":[{"name":"Steps","values":[1,2.5]}],"xLabel":"Day","yLabel":"Count","alt":"Trend"},
            {"type":"chart","chartType":"area","title":"Load","categories":["Mon"],"series":[{"name":"One","values":[-1]},{"name":"Two","values":[4]}],"alt":"Load"}
            """)
        #expect(card.blocks == [
            .chart(.init(title: "Share", chartType: .pie, segments: [.init(label: "A", value: 3), .init(label: "B", value: 1)]), alt: "Share"),
            .chart(.init(title: "Trend", chartType: .line, categories: ["Mon", "Tue"], series: [.init(name: "Steps", values: [1, 2.5])],
                xLabel: "Day", yLabel: "Count"), alt: "Trend"),
            .chart(.init(title: "Load", chartType: .area, categories: ["Mon"],
                series: [.init(name: "One", values: [-1]), .init(name: "Two", values: [4])]), alt: "Load"),
        ])
    }

    @Test func unknownBlockTypeFallsBackToItsAlt() throws {
        let card = try card(blocks: """
            {"type":"buttons","buttons":[{"label":"Yes"}],"alt":"Yes / No"},{"type":"text","text":"Hi","alt":"Hi"},7,{"type":"select"}
            """)
        #expect(card.blocks == [.unknown(alt: "Yes / No"), .text("Hi"), .unknown(alt: nil), .unknown(alt: nil)])
        #expect(card.drawn == [.unknown(alt: "Yes / No"), .text("Hi")])
        #expect(card.renders)
        #expect(card.fellBack == 3)
    }

    @Test(arguments: [
        // A row shorter than the headers.
        #"{"type":"table","caption":"T","headers":["A","B"],"rows":[["x",1],["y"]],"alt":"alt"}"#,
        // What JSON makes of a number that isn't finite.
        #"{"type":"table","caption":"T","headers":["A"],"rows":[[null]],"alt":"alt"}"#,
        #"{"type":"table","caption":"T","headers":["A"],"rows":[[true]],"alt":"alt"}"#,
        #"{"type":"table","caption":"T","headers":[],"rows":[],"alt":"alt"}"#,
        #"{"type":"chart","chartType":"bar","title":"C","categories":["A","B"],"series":[{"name":"S","values":[1]}],"alt":"alt"}"#,
        #"{"type":"chart","chartType":"line","title":"C","categories":["A"],"series":[{"name":"S","values":[null]}],"alt":"alt"}"#,
        #"{"type":"chart","chartType":"pie","title":"C","segments":[{"label":"A","value":-1}],"alt":"alt"}"#,
        #"{"type":"chart","chartType":"pie","title":"C","segments":[],"alt":"alt"}"#,
        #"{"type":"chart","chartType":"radar","title":"C","alt":"alt"}"#,
        #"{"type":"text","alt":"alt"}"#,
    ])
    func invalidBlockFallsBackToItsAlt(json: String) throws {
        let card = try card(blocks: json)
        #expect(card.blocks == [.unknown(alt: "alt")])
        #expect(card.drawn == card.blocks)
        #expect(card.renders)
        #expect(card.fellBack == 1)
    }

    @Test func nonFiniteNumbersFailTheCheck() {
        let table = Presentation.Table(headers: ["A"], rows: [[.number(.infinity)]])
        #expect(!table.valid)
        let chart = Presentation.Chart(chartType: .bar, categories: ["A"], series: [.init(name: "S", values: [.nan])])
        #expect(!chart.valid)
        #expect(!Presentation.Chart(chartType: .pie, segments: [.init(label: "A", value: .infinity)]).valid)
    }

    @Test func rowHeaderIndexOutsideTheHeadersIsIgnored() throws {
        let card = try card(blocks: #"{"type":"table","caption":"T","headers":["A"],"rows":[["x"]],"rowHeaderColumnIndex":3,"alt":"alt"}"#)
        guard case .table(let table, _) = card.blocks.first else {
            Issue.record("not a table")
            return
        }
        #expect(table.rowHeader == nil)
    }

    /// Nothing to draw: the bubble shows the reply's text.
    @Test(arguments: [
        #"{"title":"Only a title","blocks":[]}"#,
        #"{"blocks":[{"type":"divider","alt":""}]}"#,
        #"{"blocks":[{"type":"buttons"},{"type":"table","headers":["A"],"rows":[[]],"alt":""}]}"#,
    ])
    func cardWithNoRenderableBlockLeavesTheText(json: String) throws {
        let reply = try reply(presentation: json)
        #expect(reply.text == "Hello")
        #expect(try #require(reply.presentation).renders == false)
    }

    /// A presentation that isn't a card, or holds a number no Double does, is dropped; the reply decodes with the rest.
    @Test(arguments: ["7", #""card""#, "[]", "{}", #"{"blocks":"none"}"#,
        #"{"blocks":[{"type":"table","caption":"T","headers":["A"],"rows":[[1e999]],"alt":"alt"}]}"#])
    func malformedPresentationIsDroppedAndTheReplyDecodes(json: String) throws {
        let reply = try reply(presentation: json)
        #expect(reply.text == "Hello")
        #expect(reply.presentation == nil)
    }

    @Test func unknownToneAndTitleTypeAreIgnored() throws {
        let card = try #require(try reply(presentation: #"{"title":7,"tone":"festive","blocks":[{"type":"text","text":"Hi"}]}"#).presentation)
        #expect(card == Presentation(blocks: [.text("Hi")]))
    }

    @Test func oversizedPresentationIsDroppedAndTheReplyDecodes() throws {
        func json(_ length: Int) -> String {
            #"{"blocks":[{"type":"text","text":"\#(String(repeating: "a", count: length))"}]}"#
        }
        let overhead = json(0).utf8.count
        let atLimit = try reply(presentation: json(Presentation.maxBytes - overhead))
        #expect(atLimit.presentation?.renders == true)
        let over = try reply(presentation: json(Presentation.maxBytes - overhead + 1))
        #expect(over.text == "Hello")
        #expect(over.presentation == nil)
    }

    @Test func oversizedPresentationOnAHistoryItemIsDroppedAndTheItemDecodes() throws {
        let big = #"{"blocks":[{"type":"text","text":"\#(String(repeating: "a", count: Presentation.maxBytes))"}]}"#
        let json = #"{"kind":"history","data":{"convId":"00000000-0000-4000-8000-000000003000","items":[{"kind":"agent","id":"00000000-0000-4000-8000-000000003001","seq":1,"ts":1,"text":"Hello","presentation":\#(big)}],"more":false,"rev":1}}"#
        guard case .history(let page) = try JSONDecoder().decode(WireEvent.self, from: Data(json.utf8)) else {
            Issue.record("not a history page")
            return
        }
        #expect(page.items.map(\.text) == ["Hello"])
        #expect(page.items.first?.presentation == nil)
    }

    /// What the app stores with a conversation decodes back to the same card.
    @Test func cardRoundTripsThroughCodable() throws {
        guard case .reply(let reply) = try fixture("reply") else {
            Issue.record("not a reply")
            return
        }
        var card = try #require(reply.presentation)
        card.blocks.append(.unknown(alt: "alt"))
        card.blocks.append(.unknown(alt: nil))
        #expect(try JSONDecoder().decode(Presentation.self, from: JSONEncoder().encode(card)) == card)
    }
}
