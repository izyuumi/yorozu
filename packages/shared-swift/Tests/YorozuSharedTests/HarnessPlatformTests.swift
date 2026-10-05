import Foundation
import Testing
@testable import YorozuShared

private let platformOrigin = HarnessOrigin(agentId: "agent-a", pluginId: .hermes,
    conversationId: "conversation-a", sessionId: "host-session-alias", bindingEpoch: "epoch-1")

@Test func platformActionsBindExactCurrentOriginAndExplicitChoice() throws {
    let action = HarnessActionData(requestId: "request-1", origin: platformOrigin, kind: .approval,
        title: "Send the note?", choices: [.init(id: "yes", label: "Send"), .init(id: "no", label: "Decline")],
        ui: .init(targetId: "ui-1", label: "Open harness"))
    let answer = HarnessActionAnswerData(requestId: "request-1", origin: platformOrigin, choiceId: "yes")
    #expect(action.accepts(answer))
    var stale = answer; stale.origin.bindingEpoch = "old-epoch"
    #expect(!action.accepts(stale))
    var forged = answer; forged.origin.agentId = "agent-b"
    #expect(!action.accepts(forged))
    #expect(!action.accepts(.init(requestId: "request-1", origin: platformOrigin, choiceId: "always")))
    #expect(!action.accepts(.init(requestId: "request-1", origin: platformOrigin, text: "Grant all tools")))
    #expect(action.accepts(.init(requestId: "request-1", origin: platformOrigin, uiTargetId: "ui-1")))
    #expect(!action.accepts(.init(requestId: "request-1", origin: platformOrigin, uiTargetId: "https://example.test")))
    let encoded = try JSONEncoder().encode(answer)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["rule"] = ["decision": "always"]
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(HarnessActionAnswerData.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

@Test func platformCatalogAdmitsConnectionReferencesAndRejectsExecutableDetails() throws {
    let connected = PersonAgentRuntime(mode: .connected, connectionId: "connection-a")
    #expect(connected.isValid)
    #expect(!PersonAgentRuntime(mode: .managed, connectionId: "connection-a").isValid)
    #expect(!PersonAgentRuntime(mode: .connected).isValid)
    let input = PersonAgentInput(name: "Ada", role: "Secretary", pluginId: .openclaw,
        runtime: connected, allowedTools: [])
    #expect(try JSONDecoder().decode(PersonAgentInput.self, from: JSONEncoder().encode(input)) == input)
    let bad = #"{"version":1,"mode":"connected","connectionId":"connection-a","endpoint":"ws://localhost:1","token":"synthetic"}"#
    #expect(throws: (any Error).self) { try JSONDecoder().decode(PersonAgentRuntime.self, from: Data(bad.utf8)) }
    #expect(!PersonAgentRegistry(revision: 0, agents: [], defaultHarnessId: .hermes).isValid)
    #expect(!PersonAgentRegistry(revision: 0, agents: [], harnesses: [
        .init(id: .hermes, label: "Hermes", available: false, modes: [.managed])
    ], defaultHarnessId: .hermes).isValid)
}

@Test func platformExchangesKeepSenderIdentityAndReceiptCertaintySeparate() throws {
    var message = AgentExchangeData(exchangeId: "exchange-1", messageId: "message-1", deliveryId: "delivery-1",
        origin: platformOrigin, fromAgentId: "agent-a", toAgentId: "agent-b", text: "Please check the draft", createdAt: 1)
    #expect(message.isValid)
    message.fromAgentId = "agent-b"
    #expect(!message.isValid)
    let accepted = AgentExchangeStatusData(exchangeId: "exchange-1", messageId: "message-1", deliveryId: "delivery-1",
        delivery: .accepted, execution: .notStarted)
    #expect(accepted.isValid)
    #expect(!AgentExchangeStatusData(exchangeId: "exchange-1", messageId: "message-1", deliveryId: "delivery-1",
        delivery: .delivered, execution: .completed, handoff: .notSubmitted).isValid)
    let event = YorozuEvent(id: "receipt-1", threadId: "agent-exchange-inspection", ts: 1, agentId: "host",
        payload: .agentExchangeStatus(accepted))
    #expect(try JSONDecoder().decode(YorozuEvent.self, from: JSONEncoder().encode(event)) == event)
}
