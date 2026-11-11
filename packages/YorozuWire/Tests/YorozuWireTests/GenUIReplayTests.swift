import Foundation
import Testing
@testable import YorozuWire

/// The plugin's card replies (capability `presentation`), replayed through the decoders: the card rides along and
/// the text and every other field decode as they do without it. The fixture is the exact JSON the plugin puts in a
/// sealed box, read from the plugin's tree so there is one copy (`plugins/openclaw-yorozu/test/presentations.test.ts`
/// pins it). `PresentationTests` covers the card.
struct GenUIReplayTests {
    private func event(_ name: String) throws -> WireEvent {
        let repo = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let url = repo.appending(path: "plugins/openclaw-yorozu/test/fixtures/genui-wire.json")
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        return try JSONDecoder().decode(WireEvent.self, from: Data(try #require(fixture[name]).utf8))
    }

    private let convId = "00000000-0000-4000-8000-000000003000"
    private let agentId = "00000000-0000-4000-8000-000000003001"

    @Test func replyWithCardKeepsItsText() throws {
        let expected = Reply(convId: convId, messageId: agentId, text: "Here are the costs.", ts: 1_700_000_001_000)
        guard case .reply(var reply) = try event("reply") else {
            Issue.record("not a reply")
            return
        }
        #expect(reply.presentation != nil)
        reply.presentation = nil
        #expect(reply == expected)
        // A session without the capability gets the same reply with the field left out.
        #expect(try event("replyOldApp") == .reply(expected))
    }

    @Test func historyPageWithCardKeepsItsText() throws {
        guard case .history(let page) = try event("history") else {
            Issue.record("not a history page")
            return
        }
        #expect(page.convId == convId)
        #expect(page.more == false)
        #expect(page.rev == 2)
        #expect(page.before == nil && page.after == nil)
        #expect(page.items.map(\.kind) == [.user, .agent])
        #expect(page.items.map(\.seq) == [0, 1])
        #expect(page.items.map(\.ts) == [1_700_000_000_000, 1_700_000_001_000])
        #expect(page.items.map(\.text) == ["Show me the costs", "Here are the costs."])
        let agent = try #require(page.items.last)
        #expect(agent.id == agentId)
        #expect(agent.attachments == nil && agent.replyTo == nil && agent.reactions == nil && agent.tools == nil)
        #expect(agent.presentation != nil && page.items.first?.presentation == nil)
    }
}
