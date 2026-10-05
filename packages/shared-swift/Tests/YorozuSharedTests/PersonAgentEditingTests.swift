import Foundation
import Testing
@testable import YorozuShared

private func editorCatalog() -> PersonAgentRegistry {
    let agent = PersonAgent(id: "ada", name: "Ada", role: "Keep notes", pluginId: .hermes,
        model: "subscription/model", accountBindingId: "saved-account", workspace: "/tmp/ada/workspace",
        memoryDir: "/tmp/ada/memory", allowedTools: [.file, .memory],
        directories: [PersonAgentDirectoryGrant(path: "/tmp/notes", access: .read)])
    return PersonAgentRegistry(revision: 8, defaultAgentId: agent.id, agents: [agent], journalRevision: 4)
}

@Test func agentEditorCapturesRevisionAndExplicitlyResetsBindings() throws {
    let catalog = editorCatalog()
    var editor = PersonAgentEditorDraft(catalog: catalog, agent: catalog.agents[0])
    editor.name = "  Ada Notes  "
    editor.model = ""
    editor.connection = " "
    let request = try #require(editor.request)
    #expect(request.expectedRevision == 8)
    guard case .update(let id, let patch) = request.action else { Issue.record("Expected update"); return }
    #expect(id == "ada" && patch.name == "Ada Notes")
    #expect(patch.clear == [.model, .accountBindingId])
    #expect(patch.model == nil && patch.accountBindingId == nil)
    let data = try JSONEncoder().encode(request)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let payload = try #require(object["patch"] as? [String: Any])
    #expect(payload["model"] == nil && payload["accountBindingId"] == nil)
    #expect(payload["workspace"] == nil && payload["memoryDir"] == nil && payload["teamIds"] == nil)
    #expect(try JSONDecoder().decode(PersonAgentControlData.self, from: data) == request)
    editor.directories.append(PersonAgentDirectoryGrant(path: "/tmp/../private", access: .write))
    #expect(editor.request == nil)
}

@Test func agentPatchResetRejectsConflictingOrUnknownAuthority() throws {
    let invalid = [
        #"{"clear":["model","model"]}"#,
        #"{"clear":["workspace"]}"#,
        #"{"clear":["model"],"model":"replacement"}"#,
        #"{"clear":["accountBindingId"],"accountBindingId":"replacement"}"#,
        #"{"clear":null}"#,
        #"{"model":null}"#,
    ]
    for value in invalid {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PersonAgentPatch.self, from: Data(value.utf8)) }
    }
    let older = try JSONDecoder().decode(PersonAgentPatch.self, from: Data(#"{"role":"Keep notes"}"#.utf8))
    #expect(older.clear == nil && older.model == nil && older.accountBindingId == nil)
}

@Test func agentEditorNeverTreatsAnotherOperationAsSaveConfirmation() {
    var catalog = editorCatalog()
    let submission = PersonAgentSubmission(operationId: "our-save")
    #expect(submission.blocksSubmission(in: catalog))
    catalog.lastControlResult = PersonAgentControlResult(operationId: "another-save", status: .applied, revision: 9)
    #expect(submission.result(in: catalog) == nil && submission.blocksSubmission(in: catalog))
    catalog.lastControlResult = PersonAgentControlResult(operationId: "our-save", status: .unknown, revision: 9)
    #expect(submission.blocksSubmission(in: catalog)) // An uncertain write is never automatically resubmitted.
    catalog.lastControlResult = PersonAgentControlResult(operationId: "our-save", status: .rejected, revision: 8)
    #expect(!submission.blocksSubmission(in: catalog))
    catalog.lastControlResult = PersonAgentControlResult(operationId: "our-save", status: .applied, revision: 9)
    #expect(submission.result(in: catalog)?.status == .applied)
}

@Test func personChatsRemainBoundToTheirAgentAndKeepTasksOutOfTheChatList() {
    let first = ThreadSummary(id: "a", title: "Notes", archived: false, lastActivity: 2, personAgentId: "ada")
    let second = ThreadSummary(id: "b", title: "More notes", archived: false, lastActivity: 3, personAgentId: "ada")
    let other = ThreadSummary(id: "other", title: "Research", archived: false, lastActivity: 4, personAgentId: "bea")
    var archived = first; archived.id = "archive"; archived.archived = true
    var child = first; child.id = "task"; child.harnessTask = HarnessTaskSummary(taskId: "task", parentThreadId: "a", state: .running, canSteer: true, canStop: true)
    let legacy = ThreadSummary(id: "legacy", title: "Existing history", archived: false, lastActivity: 5)
    let threads = [first, second, other, archived, child, legacy]
    #expect(personAgentChats(threads, agentId: "ada").map(\.id) == ["b", "a"])
    #expect(personAgentChats(threads).map(\.id) == ["other", "b", "a"])
}

@Test func agentEditorRequiresPublishedAvailabilityAndDoesNotInventAHarnessDefault() throws {
    var catalog = PersonAgentRegistry(revision: 1, agents: [], harnesses: [
        .init(id: .hermes, label: "Hermes", available: true, modes: [.managed]),
        .init(id: .openclaw, label: "OpenClaw", available: false, modes: [.managed]),
    ])
    var editor = PersonAgentEditorDraft(catalog: catalog)
    editor.name = "Ada"; editor.role = "Secretary"
    #expect(editor.plugin == nil && editor.request == nil)
    editor.plugin = .openclaw
    #expect(editor.request == nil)
    editor.plugin = .hermes
    #expect(editor.request != nil)
    catalog.defaultHarnessId = .hermes
    #expect(PersonAgentEditorDraft(catalog: catalog).plugin == .hermes)
}

@Test func connectedAgentEditorUsesOnlyPublishedConnectionReferences() throws {
    let catalog = PersonAgentRegistry(revision: 1, agents: [], harnesses: [
        .init(id: .openclaw, label: "OpenClaw", available: true, modes: [.connected]),
    ], connections: [
        .init(id: "running-one", pluginId: .openclaw, label: "Mac agent", available: true),
        .init(id: "running-two", pluginId: .hermes, label: "Other harness", available: true),
    ])
    var editor = PersonAgentEditorDraft(catalog: catalog)
    editor.name = "Bea"; editor.role = "Research"; editor.plugin = .openclaw
    editor.runtimeMode = .connected
    #expect(editor.request == nil)
    editor.runtimeConnectionId = "running-two"
    #expect(editor.request == nil)
    editor.runtimeConnectionId = "running-one"
    let request = try #require(editor.request)
    guard case .create(let input) = request.action else { Issue.record("Expected creation"); return }
    #expect(input.runtime == PersonAgentRuntime(mode: .connected, connectionId: "running-one"))
    #expect(input.model == nil && input.accountBindingId == nil)
}

@Test func previousAgentHistoryIncludesArchivesButExcludesExchangeStreams() {
    let archived = ThreadSummary(id: "old-topic", title: "Prior notes", archived: true, lastActivity: 1, personAgentId: "ada")
    let exchange = ThreadSummary(id: "agent-exchange-test", title: "Exchange", archived: false, lastActivity: 2,
        personAgentId: "ada", personAgentExchange: .init(exchangeId: "exchange", fromAgentId: "ada", toAgentId: "bea"))
    #expect(personAgentHistory([archived, exchange], agentId: "ada").map(\.id) == [archived.id])
    #expect(personAgentChats([archived, exchange], agentId: "ada").isEmpty)
}
