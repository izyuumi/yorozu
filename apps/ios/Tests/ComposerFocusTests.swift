import Foundation
import Testing
import YorozuWire

@MainActor
@Suite struct ComposerFocusTests {
    private let harness: ModelHarness

    init() throws {
        harness = try ModelHarness()
    }

    private func pairedModel() throws -> AppModel {
        _ = try harness.store(paired: true)
        return harness.makeModel()
    }

    @Test func onlyAnExplicitNewConversationFocuses() {
        #expect(ComposerFocus.iosShouldFocus(.explicitNew))
        #expect(!ComposerFocus.iosShouldFocus(.existing))
        #expect(!ComposerFocus.iosShouldFocus(.autoBlank))
    }

    @Test(arguments: [WidgetLink.new, .ask]) func aNewConversationLinkRequestsTextFocus(link: WidgetLink) throws {
        let model = try pairedModel()
        model.open(link)
        let request = try #require(model.composeRequest)
        #expect(!request.talk)
        #expect(model.requestedConversation == request.convId)
    }

    @Test func talkRequestsVoiceNotTextFocus() throws {
        let model = try pairedModel()
        model.open(.talk)
        let request = try #require(model.composeRequest)
        #expect(request.talk)
        #expect(model.requestedConversation == request.convId)
    }

    @Test func anExistingConversationLinkRequestsNoFocus() throws {
        let model = try pairedModel()
        model.open(.conversation(harness.convId))
        #expect(model.requestedConversation == harness.convId)
        #expect(model.composeRequest == nil)
    }

    @Test func newConversationIdRequestsTextFocus() throws {
        let model = try pairedModel()
        let id = model.newConversationId()
        #expect(WireEvent.isId(id))
        #expect(model.composeRequest == ComposeRequest(convId: id, talk: false))
    }
}
