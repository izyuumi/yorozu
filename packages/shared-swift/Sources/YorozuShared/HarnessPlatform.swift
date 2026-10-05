import Foundation

public struct PersonAgentExchangeSummary: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var exchangeId: String
    public var fromAgentId: String
    public var toAgentId: String
    public init(exchangeId: String, fromAgentId: String, toAgentId: String) {
        self.exchangeId = exchangeId; self.fromAgentId = fromAgentId; self.toAgentId = toAgentId
    }
    public var isValid: Bool {
        version == 1 && PersonAgentWire.text(exchangeId, 128)
            && PersonAgentWire.id(fromAgentId) && PersonAgentWire.id(toAgentId)
    }
    private enum CodingKeys: String, CodingKey { case version, exchangeId, fromAgentId, toAgentId }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["version", "exchangeId", "fromAgentId", "toAgentId"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version); exchangeId = try c.decode(String.self, forKey: .exchangeId)
        fromAgentId = try c.decode(String.self, forKey: .fromAgentId); toAgentId = try c.decode(String.self, forKey: .toAgentId)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}


public struct PersonAgentRuntime: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case managed, connected }
    public var version: Int
    public var mode: Mode
    public var connectionId: String?
    public init(version: Int = 1, mode: Mode, connectionId: String? = nil) { self.version = version; self.mode = mode; self.connectionId = connectionId }
    public var isValid: Bool { version == 1 && (mode == .managed ? connectionId == nil : connectionId.map(PersonAgentWire.id) == true) }
    private enum CodingKeys: String, CodingKey { case version, mode, connectionId }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["version", "mode", "connectionId"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        mode = try c.decode(Mode.self, forKey: .mode)
        connectionId = try c.decodeIfPresent(String.self, forKey: .connectionId)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}


public struct PersonAgentHarnessDescriptor: Codable, Equatable, Sendable {

    public var id: PersonAgentPlugin
    public var label: String
    public var available: Bool
    public var modes: [PersonAgentRuntime.Mode]
    public var capabilities: [String]
    public var unavailableReason: String?
    public init(id: PersonAgentPlugin, label: String, available: Bool, modes: [PersonAgentRuntime.Mode], capabilities: [String] = [], unavailableReason: String? = nil) { self.id = id; self.label = label; self.available = available; self.modes = modes; self.capabilities = capabilities; self.unavailableReason = unavailableReason }
    public var isValid: Bool { PersonAgentWire.text(label, 80) && modes.count <= 2 && Set(modes).count == modes.count && capabilities.count <= 32 && Set(capabilities).count == capabilities.count && capabilities.allSatisfy { $0.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil } && (unavailableReason.map { PersonAgentWire.text($0, 512) } ?? true) }
    private enum CodingKeys: String, CodingKey { case id, label, available, modes, capabilities, unavailableReason }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["id", "label", "available", "modes", "capabilities", "unavailableReason"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PersonAgentPlugin.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        available = try c.decode(Bool.self, forKey: .available)
        modes = try c.decode([PersonAgentRuntime.Mode].self, forKey: .modes)
        capabilities = try c.decode([String].self, forKey: .capabilities)
        unavailableReason = try c.decodeIfPresent(String.self, forKey: .unavailableReason)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}


public struct PersonAgentConnectionDescriptor: Codable, Equatable, Sendable {

    public var id: String
    public var pluginId: PersonAgentPlugin
    public var label: String
    public var available: Bool
    public var unavailableReason: String?
    public init(id: String, pluginId: PersonAgentPlugin, label: String, available: Bool, unavailableReason: String? = nil) { self.id = id; self.pluginId = pluginId; self.label = label; self.available = available; self.unavailableReason = unavailableReason }
    public var isValid: Bool { PersonAgentWire.id(id) && PersonAgentWire.text(label, 80) && (unavailableReason.map { PersonAgentWire.text($0, 512) } ?? true) }
    private enum CodingKeys: String, CodingKey { case id, pluginId, label, available, unavailableReason }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["id", "pluginId", "label", "available", "unavailableReason"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pluginId = try c.decode(PersonAgentPlugin.self, forKey: .pluginId)
        label = try c.decode(String.self, forKey: .label)
        available = try c.decode(Bool.self, forKey: .available)
        unavailableReason = try c.decodeIfPresent(String.self, forKey: .unavailableReason)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}

/// Host-verified ownership stamp. Session/work identifiers are host aliases; matching structure alone does not establish authority.
public struct HarnessOrigin: Codable, Equatable, Sendable {

    public var version: Int
    public var agentId: String
    public var pluginId: PersonAgentPlugin
    public var conversationId: String
    public var sessionId: String
    public var workId: String?
    public var bindingEpoch: String
    public init(version: Int = 1, agentId: String, pluginId: PersonAgentPlugin, conversationId: String, sessionId: String, workId: String? = nil, bindingEpoch: String) { self.version = version; self.agentId = agentId; self.pluginId = pluginId; self.conversationId = conversationId; self.sessionId = sessionId; self.workId = workId; self.bindingEpoch = bindingEpoch }
    public var isValid: Bool { version == 1 && PersonAgentWire.id(agentId) && PersonAgentWire.text(conversationId, 128) && PersonAgentWire.text(sessionId, 128) && PersonAgentWire.text(bindingEpoch, 128) && (workId.map { PersonAgentWire.text($0, 128) } ?? true) }
    private enum CodingKeys: String, CodingKey { case version, agentId, pluginId, conversationId, sessionId, workId, bindingEpoch }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["version", "agentId", "pluginId", "conversationId", "sessionId", "workId", "bindingEpoch"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        agentId = try c.decode(String.self, forKey: .agentId)
        pluginId = try c.decode(PersonAgentPlugin.self, forKey: .pluginId)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        workId = try c.decodeIfPresent(String.self, forKey: .workId)
        bindingEpoch = try c.decode(String.self, forKey: .bindingEpoch)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}


public struct HarnessActionChoice: Codable, Equatable, Sendable {

    public var id: String
    public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
    public var isValid: Bool { PersonAgentWire.text(id, 128) && PersonAgentWire.text(label, 256) }
    private enum CodingKeys: String, CodingKey { case id, label }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["id", "label"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}

/// An opaque target resolved by the host against the originating harness. Never a client-launchable URL.
public struct HarnessUITarget: Codable, Equatable, Sendable {

    public var targetId: String
    public var label: String
    public init(targetId: String, label: String) { self.targetId = targetId; self.label = label }
    public var isValid: Bool { PersonAgentWire.text(targetId, 128) && PersonAgentWire.text(label, 256) }
    private enum CodingKeys: String, CodingKey { case targetId, label }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["targetId", "label"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetId = try c.decode(String.self, forKey: .targetId)
        label = try c.decode(String.self, forKey: .label)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}


public struct HarnessActionData: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case approval, question; case signIn = "sign-in"; case openUI = "open-ui" }
    public enum State: String, Codable, Sendable { case pending, cancelled, resolved }
    public func accepts(_ answer: HarnessActionAnswerData) -> Bool {
        isValid && answer.isValid && state == .pending && requestId == answer.requestId && origin == answer.origin
            && (answer.uiTargetId != nil ? ui?.targetId == answer.uiTargetId
                : (answer.choiceId == nil || choices.contains { $0.id == answer.choiceId })
                    && (answer.text == nil || allowText == true))
    }
    public var version: Int
    public var requestId: String
    public var origin: HarnessOrigin
    public var kind: Kind
    public var title: String
    public var text: String?
    public var choices: [HarnessActionChoice]
    public var allowText: Bool?
    public var ui: HarnessUITarget?
    public var state: State
    public init(version: Int = 1, requestId: String, origin: HarnessOrigin, kind: Kind, title: String, text: String? = nil, choices: [HarnessActionChoice] = [], allowText: Bool? = nil, ui: HarnessUITarget? = nil, state: State = .pending) { self.version = version; self.requestId = requestId; self.origin = origin; self.kind = kind; self.title = title; self.text = text; self.choices = choices; self.allowText = allowText; self.ui = ui; self.state = state }
    public var isValid: Bool { version == 1 && PersonAgentWire.text(requestId, 128) && origin.isValid && PersonAgentWire.text(title, 512) && (text.map { PersonAgentWire.knowledge($0) } ?? true) && choices.count <= 32 && choices.allSatisfy(\.isValid) && Set(choices.map(\.id)).count == choices.count && (ui?.isValid ?? true) }
    private enum CodingKeys: String, CodingKey { case version, requestId, origin, kind, title, text, choices, allowText, ui, state }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["version", "requestId", "origin", "kind", "title", "text", "choices", "allowText", "ui", "state"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        requestId = try c.decode(String.self, forKey: .requestId)
        origin = try c.decode(HarnessOrigin.self, forKey: .origin)
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        choices = try c.decode([HarnessActionChoice].self, forKey: .choices)
        allowText = try c.decodeIfPresent(Bool.self, forKey: .allowText)
        ui = try c.decodeIfPresent(HarnessUITarget.self, forKey: .ui)
        state = try c.decode(State.self, forKey: .state)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}


public struct HarnessActionAnswerData: Codable, Equatable, Sendable {

    public var version: Int
    public var requestId: String
    public var origin: HarnessOrigin
    public var choiceId: String?
    public var text: String?
    public var uiTargetId: String?
    public init(version: Int = 1, requestId: String, origin: HarnessOrigin, choiceId: String? = nil, text: String? = nil, uiTargetId: String? = nil) { self.version = version; self.requestId = requestId; self.origin = origin; self.choiceId = choiceId; self.text = text; self.uiTargetId = uiTargetId }
    public var isValid: Bool { version == 1 && PersonAgentWire.text(requestId, 128) && origin.isValid && (choiceId.map { PersonAgentWire.text($0, 128) } ?? true) && (text.map { PersonAgentWire.knowledge($0) } ?? true) && (uiTargetId.map { PersonAgentWire.text($0, 128) } ?? true) && (uiTargetId != nil ? choiceId == nil && text == nil : choiceId != nil || text != nil) }
    private enum CodingKeys: String, CodingKey { case version, requestId, origin, choiceId, text, uiTargetId }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["version", "requestId", "origin", "choiceId", "text", "uiTargetId"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        requestId = try c.decode(String.self, forKey: .requestId)
        origin = try c.decode(HarnessOrigin.self, forKey: .origin)
        choiceId = try c.decodeIfPresent(String.self, forKey: .choiceId)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        uiTargetId = try c.decodeIfPresent(String.self, forKey: .uiTargetId)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}


public struct HarnessActionStatusData: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case requested, applied, rejected, unknown; case noLongerNeeded = "no-longer-needed" }
    public var version: Int
    public var operationId: String
    public var requestId: String
    public var origin: HarnessOrigin
    public var status: Status
    public var reason: String?
    public init(version: Int = 1, operationId: String, requestId: String, origin: HarnessOrigin, status: Status, reason: String? = nil) { self.version = version; self.operationId = operationId; self.requestId = requestId; self.origin = origin; self.status = status; self.reason = reason }
    public var isValid: Bool { version == 1 && PersonAgentWire.text(operationId, 128) && PersonAgentWire.text(requestId, 128) && origin.isValid && (reason.map { PersonAgentWire.text($0, 512) } ?? true) }
    private enum CodingKeys: String, CodingKey { case version, operationId, requestId, origin, status, reason }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["version", "operationId", "requestId", "origin", "status", "reason"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        operationId = try c.decode(String.self, forKey: .operationId)
        requestId = try c.decode(String.self, forKey: .requestId)
        origin = try c.decode(HarnessOrigin.self, forKey: .origin)
        status = try c.decode(Status.self, forKey: .status)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}

/// Separate agent exchange inspection stream; never injected as a user message.
public struct AgentExchangeData: Codable, Equatable, Sendable {

    public var version: Int
    public var exchangeId: String
    public var messageId: String
    public var deliveryId: String
    public var origin: HarnessOrigin
    public var fromAgentId: String
    public var toAgentId: String
    public var text: String
    public var createdAt: Int
    public init(version: Int = 1, exchangeId: String, messageId: String, deliveryId: String, origin: HarnessOrigin, fromAgentId: String, toAgentId: String, text: String, createdAt: Int) { self.version = version; self.exchangeId = exchangeId; self.messageId = messageId; self.deliveryId = deliveryId; self.origin = origin; self.fromAgentId = fromAgentId; self.toAgentId = toAgentId; self.text = text; self.createdAt = createdAt }
    public var isValid: Bool { version == 1 && PersonAgentWire.text(exchangeId, 128) && PersonAgentWire.text(messageId, 128) && PersonAgentWire.text(deliveryId, 128) && origin.isValid && PersonAgentWire.id(fromAgentId) && PersonAgentWire.id(toAgentId) && origin.agentId == fromAgentId && PersonAgentWire.revision(createdAt) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= 65536 && !text.contains("\0") }
    private enum CodingKeys: String, CodingKey { case version, exchangeId, messageId, deliveryId, origin, fromAgentId, toAgentId, text, createdAt }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["version", "exchangeId", "messageId", "deliveryId", "origin", "fromAgentId", "toAgentId", "text", "createdAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        exchangeId = try c.decode(String.self, forKey: .exchangeId)
        messageId = try c.decode(String.self, forKey: .messageId)
        deliveryId = try c.decode(String.self, forKey: .deliveryId)
        origin = try c.decode(HarnessOrigin.self, forKey: .origin)
        fromAgentId = try c.decode(String.self, forKey: .fromAgentId)
        toAgentId = try c.decode(String.self, forKey: .toAgentId)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Int.self, forKey: .createdAt)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}

/// Host acceptance and native delivery do not establish execution. Unknown never means safe to retry.
public struct AgentExchangeStatusData: Codable, Equatable, Sendable {
    public enum Delivery: String, Codable, Sendable { case accepted, delivered, rejected, unknown }
    public enum Execution: String, Codable, Sendable { case running, completed, failed, unknown; case notStarted = "not-started" }
    public enum Handoff: String, Codable, Sendable { case notSubmitted = "not-submitted" }
    public var version: Int
    public var exchangeId: String
    public var messageId: String
    public var deliveryId: String
    public var attemptId: String?
    public var delivery: Delivery
    public var execution: Execution
    public var handoff: Handoff?
    public var reason: String?
    public init(version: Int = 1, exchangeId: String, messageId: String, deliveryId: String, attemptId: String? = nil, delivery: Delivery, execution: Execution, handoff: Handoff? = nil, reason: String? = nil) { self.version = version; self.exchangeId = exchangeId; self.messageId = messageId; self.deliveryId = deliveryId; self.attemptId = attemptId; self.delivery = delivery; self.execution = execution; self.handoff = handoff; self.reason = reason }
    public var isValid: Bool { version == 1 && PersonAgentWire.text(exchangeId, 128) && PersonAgentWire.text(messageId, 128) && PersonAgentWire.text(deliveryId, 128) && (attemptId.map { PersonAgentWire.text($0, 128) } ?? true) && (reason.map { PersonAgentWire.text($0, 512) } ?? true) && (delivery != .rejected || execution == .notStarted) && (handoff != .notSubmitted || delivery != .delivered && execution == .notStarted) }
    private enum CodingKeys: String, CodingKey { case version, exchangeId, messageId, deliveryId, attemptId, delivery, execution, handoff, reason }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["version", "exchangeId", "messageId", "deliveryId", "attemptId", "delivery", "execution", "handoff", "reason"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        exchangeId = try c.decode(String.self, forKey: .exchangeId)
        messageId = try c.decode(String.self, forKey: .messageId)
        deliveryId = try c.decode(String.self, forKey: .deliveryId)
        attemptId = try c.decodeIfPresent(String.self, forKey: .attemptId)
        delivery = try c.decode(Delivery.self, forKey: .delivery)
        execution = try c.decode(Execution.self, forKey: .execution)
        handoff = try c.decodeIfPresent(Handoff.self, forKey: .handoff)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}
