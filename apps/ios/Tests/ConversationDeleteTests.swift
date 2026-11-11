import Foundation
import Testing
import YorozuWire

@MainActor
@Suite struct ConversationDeleteTests {
    private let harness: ModelHarness
    private let active = WireEvent.newId()
    private let archived = WireEvent.newId()

    init() throws {
        harness = try ModelHarness()
        _ = try harness.store(paired: true)
        harness.seed([
            Conversation(id: active, createdAt: 1, updatedAt: 1),
            Conversation(id: archived, createdAt: 1, updatedAt: 1, archived: true),
        ])
    }

    /// A ready model over the seeded chats, and its transport answering each send with `sendResult`.
    private func ready(sendResult: Bool = true) async throws -> (AppModel, ScriptedTransport) {
        let model = try await harness.openFirstSession()
        let transport = try #require(harness.scripted)
        await transport.setSendResult(sendResult)
        try #require(model.canPatch)
        try #require(model.conversations[active] != nil)
        try #require(model.conversations[archived]?.archived == true)
        return (model, transport)
    }

    private func patches(_ transport: ScriptedTransport) async -> [ConvPatch] {
        await transport.sent.compactMap { event -> ConvPatch? in
            if case .convPatch(let patch) = event { return patch }
            return nil
        }
    }

    /// `patch()` sends from a task of its own, so the recorded send is awaited.
    private func patchSent(_ transport: ScriptedTransport) async -> Bool {
        for _ in 0..<100 {
            if await !patches(transport).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Long enough for a send that should not happen, or a removal that should not follow, to show up.
    private func pause() async { try? await Task.sleep(for: .milliseconds(100)) }

    @Test func deleteOnAnActiveChatIsRefused() async throws {
        let (model, transport) = try await ready()
        #expect(model.delete(active) == false)
        await pause()
        #expect(await patches(transport).isEmpty)
        #expect(model.conversations[active] != nil)
    }

    @Test func deleteOnAnUnknownChatIsRefused() async throws {
        let (model, transport) = try await ready()
        #expect(model.delete(WireEvent.newId()) == false)
        await pause()
        #expect(await patches(transport).isEmpty)
    }

    @Test func deleteOnAnArchivedChatSendsOnePatchAndForgetsIt() async throws {
        let (model, transport) = try await ready()
        #expect(model.delete(archived) == true)
        #expect(await patchSent(transport))
        let gone = await harness.settled { model.conversations[archived] == nil }
        #expect(gone)
        #expect(await patches(transport) == [ConvPatch(convId: archived, deleted: true)])
    }

    @Test func deleteOnAnArchivedChatKeepsItWhenTheSendFails() async throws {
        let (model, transport) = try await ready(sendResult: false)
        #expect(model.delete(archived) == true)
        #expect(await patchSent(transport))
        await pause()
        #expect(await patches(transport) == [ConvPatch(convId: archived, deleted: true)])
        #expect(model.conversations[archived] != nil)
    }

    @Test func deleteIsRefusedOnceAnUpdateWithoutArchivedMakesTheChatActive() async throws {
        let (model, transport) = try await ready()
        await transport.emit(.event(.convUpdate(ConvUpdate(convId: archived))))
        let applied = await harness.settled { model.conversations[archived] != nil && model.conversations[archived]?.archived != true }
        try #require(applied)
        #expect(model.delete(archived) == false)
        await pause()
        #expect(await patches(transport).isEmpty)
        #expect(model.conversations[archived] != nil)
    }
}
