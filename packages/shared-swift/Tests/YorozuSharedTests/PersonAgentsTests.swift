import Foundation
import Testing
@testable import YorozuShared

@Test func personAgentSettingsWireRejectsUnknownAuthorityAndBounds() throws {
    let requests = [
        #"{"version":1,"expectedRevision":2,"action":"create","agent":{"name":"Ada","role":"Keep notes","pluginId":"hermes","allowedTools":["file"]}}"#,
        #"{"version":1,"expectedRevision":2,"action":"update","agentId":"agent-a","patch":{"model":"subscription/model"}}"#,
        #"{"version":1,"expectedRevision":2,"action":"default","agentId":"agent-a"}"#,
        #"{"version":1,"expectedRevision":2,"action":"create-team","team":{"name":"Notes","agentIds":["agent-a"]}}"#,
        #"{"version":1,"expectedRevision":2,"action":"update-team","teamId":"team-a","patch":{"agentIds":["agent-a"]}}"#,
        #"{"version":1,"expectedRevision":2,"action":"remember","expectedJournalRevision":3,"preference":{"allAgents":true,"text":"Use short paragraphs.\nAvoid repetition."}}"#,
        #"{"version":1,"expectedRevision":2,"action":"share-knowledge","expectedJournalRevision":3,"knowledge":{"fromAgentId":"agent-a","toAgentIds":["agent-b"],"text":"The meeting is on Tuesday."}}"#,
    ]
    for json in requests {
        let original = Data(json.utf8)
        let control = try JSONDecoder().decode(PersonAgentControlData.self, from: original)
        #expect(control.isValid)
        let encoded = try JSONEncoder().encode(control)
        #expect(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary == JSONSerialization.jsonObject(with: original) as? NSDictionary)
    }
    let base = try #require(JSONSerialization.jsonObject(with: Data(requests[0].utf8)) as? [String: Any])
    let input = try #require(base["agent"] as? [String: Any])
    let invalid: [[String: Any]] = [
        base.merging(["version": 2]) { _, new in new },
        base.merging(["expectedRevision": -1]) { _, new in new },
        base.merging(["expectedRevision": 9_007_199_254_740_992]) { _, new in new },
        base.merging(["agent": input.merging(["apiKey": "synthetic"]) { _, new in new }]) { _, new in new },
        base.merging(["agent": input.merging(["workspace": "/tmp/arbitrary"]) { _, new in new }]) { _, new in new },
        base.merging(["agent": input.merging(["name": String(repeating: "😀", count: 41)]) { _, new in new }]) { _, new in new },
        base.merging(["agent": input.merging(["allowedTools": ["file", "file"]]) { _, new in new }]) { _, new in new },
        base.merging(["agent": input.merging(["allowedTools": ["anything"]]) { _, new in new }]) { _, new in new },
        base.merging(["agent": input.merging(["model": NSNull()]) { _, new in new }]) { _, new in new },
        base.merging(["agent": input.merging(["directories": [["path": "/tmp/../outside", "access": "write"]]]) { _, new in new }]) { _, new in new },
        ["version": 1, "expectedRevision": 2, "action": "default", "agentId": "agent-a\n"],
        ["version": 1, "expectedRevision": 2, "action": "remember", "preference": ["allAgents": true, "text": "Short answers"]],
        ["version": 1, "expectedRevision": 2, "action": "remember", "expectedJournalRevision": 3,
            "preference": ["allAgents": true, "agentId": "agent-a", "text": "Short answers"]],
        ["version": 1, "expectedRevision": 2, "action": "remember", "expectedJournalRevision": 3,
            "preference": ["allAgents": true, "text": "Short answers", "allowedTools": ["terminal"]]],
    ]
    for value in invalid {
        let data = try JSONSerialization.data(withJSONObject: value)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PersonAgentControlData.self, from: data) }
    }
}

@Test func personAgentCatalogChecksMembershipAndHistoryIdentifiersAreAdditive() throws {
    let agent = PersonAgent(id: "agent-a", name: "Ada", role: "Keep notes", pluginId: .hermes,
        workspace: "/tmp/agent-a/workspace", memoryDir: "/tmp/agent-a/memory", allowedTools: [.file, .memory])
    var registry = PersonAgentRegistry(revision: 2, defaultAgentId: agent.id, agents: [agent], journalRevision: 3)
    #expect(registry.isValid)
    registry.teams = [PersonAgentTeam(id: "team-a", name: "Notes", agentIds: [agent.id])]
    #expect(!registry.isValid)
    registry.agents[0].teamIds = ["team-a"]
    #expect(registry.isValid)
    #expect(try JSONDecoder().decode(PersonAgentRegistry.self, from: JSONEncoder().encode(registry)) == registry)
    registry.defaultAgentId = "missing"
    #expect(!registry.isValid)
    let older = try JSONDecoder().decode(ThreadListData.self, from: Data(#"{"threads":[{"id":"old","title":"","archived":false,"lastActivity":1}]}"#.utf8))
    #expect(older.personAgents == nil && older.threads[0].personAgentId == nil)
    let thread = ThreadSummary(id: "conversation", title: "Notes", archived: false, lastActivity: 1,
        personAgentId: agent.id, personAgentName: agent.name)
    #expect(try JSONDecoder().decode(ThreadSummary.self, from: JSONEncoder().encode(thread)) == thread)
    let creation = ThreadCreateData(personAgentId: agent.id)
    #expect(try JSONDecoder().decode(ThreadCreateData.self, from: JSONEncoder().encode(creation)) == creation)
}
