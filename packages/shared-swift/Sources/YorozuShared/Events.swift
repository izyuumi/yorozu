import Foundation

/// Wire events exchanged between Mac, phone and relay. See docs/spec-v1.html sections 3, 7, 8.
///
/// JSON shape is `{ id, threadId, ts, agentId, parentAgentId?, kind, data }`, identical to
/// `YorozuEvent` in packages/shared/src/events.ts.
public struct YorozuEvent: Codable, Equatable, Sendable {
    public var id: String
    public var threadId: String
    /// Epoch milliseconds.
    public var ts: Int
    public var agentId: String
    /// Set when the emitting agent was delegated to by another.
    public var parentAgentId: String?
    public var payload: Payload

    public init(
        id: String,
        threadId: String,
        ts: Int,
        agentId: String,
        parentAgentId: String? = nil,
        payload: Payload
    ) {
        self.id = id
        self.threadId = threadId
        self.ts = ts
        self.agentId = agentId
        self.parentAgentId = parentAgentId
        self.payload = payload
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case message, reaction, thought
        case toolCall = "tool_call"
        case toolResult = "tool_result"
        case approvalCard = "approval_card"
        case approvalAnswer = "approval_answer"
        case ruleProposal = "rule_proposal"
        case ruleList = "rule_list"
        case ruleUpdate = "rule_update"
        case ruleDelete = "rule_delete"
        case approvalSettings = "approval_settings"
        case questionCard = "question_card"
        case questionAnswer = "question_answer"
        case progressCard = "progress_card"
        case toolResultRequest = "tool_result_request"
        case threadCreate = "thread_create"
        case threadList = "thread_list"
        case threadArchive = "thread_archive"
        case threadRename = "thread_rename"
        case threadPin = "thread_pin"
        case threadRead = "thread_read"
        case threadSetModel = "thread_set_model"
        case threadSetEffort = "thread_set_effort"
        case threadSetBypass = "thread_set_bypass"
        case threadRecover = "thread_recover"
        case modelList = "model_list"
        case projectList = "project_list"
        case interrupt
        case syncRequest = "sync_request"
        case syncDelta = "sync_delta"
        case deviceList = "device_list"
        case deviceRemove = "device_remove"
        case receipt
    }

    public enum Payload: Equatable, Sendable {
        case message(MessageData)
        case reaction(ReactionData)
        case thought(ThoughtData)
        case toolCall(ToolCallData)
        case toolResult(ToolResultData)
        case approvalCard(ApprovalCardData)
        case approvalAnswer(ApprovalAnswerData)
        case ruleProposal(RuleProposalData)
        case ruleList(RuleListData)
        case ruleUpdate(RuleUpdateData)
        case ruleDelete(RuleDeleteData)
        case approvalSettings(ApprovalSettingsData)
        case questionCard(QuestionCardData)
        case questionAnswer(QuestionAnswerData)
        case progressCard(ProgressCardData)
        case toolResultRequest(ToolResultRequestData)
        case threadCreate(ThreadCreateData)
        case threadList(ThreadListData)
        case threadArchive(ThreadArchiveData)
        case threadRename(ThreadRenameData)
        case threadPin(ThreadPinData)
        case threadRead(ThreadReadData)
        case threadSetModel(ThreadSetModelData)
        case threadSetEffort(ThreadSetEffortData)
        case threadSetBypass(ThreadSetBypassData)
        case threadRecover(ThreadRecoverData)
        case modelList(ModelListData)
        case projectList(ProjectListData)
        case interrupt(InterruptData)
        case syncRequest(SyncRequestData)
        case syncDelta(SyncDeltaData)
        case deviceList(DeviceListData)
        case deviceRemove(DeviceRemoveData)
        case receipt(ReceiptData)

        public var kind: Kind {
            switch self {
            case .message: .message
            case .reaction: .reaction
            case .thought: .thought
            case .toolCall: .toolCall
            case .toolResult: .toolResult
            case .approvalCard: .approvalCard
            case .approvalAnswer: .approvalAnswer
            case .ruleProposal: .ruleProposal
            case .ruleList: .ruleList
            case .ruleUpdate: .ruleUpdate
            case .ruleDelete: .ruleDelete
            case .approvalSettings: .approvalSettings
            case .questionCard: .questionCard
            case .questionAnswer: .questionAnswer
            case .progressCard: .progressCard
            case .toolResultRequest: .toolResultRequest
            case .threadCreate: .threadCreate
            case .threadList: .threadList
            case .threadArchive: .threadArchive
            case .threadRename: .threadRename
            case .threadPin: .threadPin
            case .threadRead: .threadRead
            case .threadSetModel: .threadSetModel
            case .threadSetEffort: .threadSetEffort
            case .threadSetBypass: .threadSetBypass
            case .threadRecover: .threadRecover
            case .modelList: .modelList
            case .projectList: .projectList
            case .interrupt: .interrupt
            case .syncRequest: .syncRequest
            case .syncDelta: .syncDelta
            case .deviceList: .deviceList
            case .deviceRemove: .deviceRemove
            case .receipt: .receipt
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, threadId, ts, agentId, parentAgentId, kind, data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        threadId = try c.decode(String.self, forKey: .threadId)
        ts = try c.decode(Int.self, forKey: .ts)
        agentId = try c.decode(String.self, forKey: .agentId)
        parentAgentId = try c.decodeIfPresent(String.self, forKey: .parentAgentId)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .message: payload = .message(try c.decode(MessageData.self, forKey: .data))
        case .reaction: payload = .reaction(try c.decode(ReactionData.self, forKey: .data))
        case .thought: payload = .thought(try c.decode(ThoughtData.self, forKey: .data))
        case .toolCall: payload = .toolCall(try c.decode(ToolCallData.self, forKey: .data))
        case .toolResult: payload = .toolResult(try c.decode(ToolResultData.self, forKey: .data))
        case .approvalCard: payload = .approvalCard(try c.decode(ApprovalCardData.self, forKey: .data))
        case .approvalAnswer: payload = .approvalAnswer(try c.decode(ApprovalAnswerData.self, forKey: .data))
        case .ruleProposal: payload = .ruleProposal(try c.decode(RuleProposalData.self, forKey: .data))
        case .ruleList: payload = .ruleList(try c.decode(RuleListData.self, forKey: .data))
        case .ruleUpdate: payload = .ruleUpdate(try c.decode(RuleUpdateData.self, forKey: .data))
        case .ruleDelete: payload = .ruleDelete(try c.decode(RuleDeleteData.self, forKey: .data))
        case .approvalSettings: payload = .approvalSettings(try c.decode(ApprovalSettingsData.self, forKey: .data))
        case .questionCard: payload = .questionCard(try c.decode(QuestionCardData.self, forKey: .data))
        case .questionAnswer: payload = .questionAnswer(try c.decode(QuestionAnswerData.self, forKey: .data))
        case .progressCard: payload = .progressCard(try c.decode(ProgressCardData.self, forKey: .data))
        case .toolResultRequest: payload = .toolResultRequest(try c.decode(ToolResultRequestData.self, forKey: .data))
        case .threadCreate: payload = .threadCreate(try c.decode(ThreadCreateData.self, forKey: .data))
        case .threadList: payload = .threadList(try c.decode(ThreadListData.self, forKey: .data))
        case .threadArchive: payload = .threadArchive(try c.decode(ThreadArchiveData.self, forKey: .data))
        case .threadRename: payload = .threadRename(try c.decode(ThreadRenameData.self, forKey: .data))
        case .threadPin: payload = .threadPin(try c.decode(ThreadPinData.self, forKey: .data))
        case .threadRead: payload = .threadRead(try c.decode(ThreadReadData.self, forKey: .data))
        case .threadSetModel: payload = .threadSetModel(try c.decode(ThreadSetModelData.self, forKey: .data))
        case .threadRecover: payload = .threadRecover(try c.decode(ThreadRecoverData.self, forKey: .data))
        case .threadSetBypass: payload = .threadSetBypass(try c.decode(ThreadSetBypassData.self, forKey: .data))
        case .threadSetEffort: payload = .threadSetEffort(try c.decode(ThreadSetEffortData.self, forKey: .data))
        case .modelList: payload = .modelList(try c.decode(ModelListData.self, forKey: .data))
        case .projectList: payload = .projectList(try c.decode(ProjectListData.self, forKey: .data))
        case .interrupt: payload = .interrupt(try c.decode(InterruptData.self, forKey: .data))
        case .syncRequest: payload = .syncRequest(try c.decode(SyncRequestData.self, forKey: .data))
        case .syncDelta: payload = .syncDelta(try c.decode(SyncDeltaData.self, forKey: .data))
        case .deviceList: payload = .deviceList(try c.decode(DeviceListData.self, forKey: .data))
        case .deviceRemove: payload = .deviceRemove(try c.decode(DeviceRemoveData.self, forKey: .data))
        case .receipt: payload = .receipt(try c.decode(ReceiptData.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(threadId, forKey: .threadId)
        try c.encode(ts, forKey: .ts)
        try c.encode(agentId, forKey: .agentId)
        try c.encodeIfPresent(parentAgentId, forKey: .parentAgentId)
        try c.encode(payload.kind, forKey: .kind)
        switch payload {
        case .message(let d): try c.encode(d, forKey: .data)
        case .reaction(let d): try c.encode(d, forKey: .data)
        case .thought(let d): try c.encode(d, forKey: .data)
        case .toolCall(let d): try c.encode(d, forKey: .data)
        case .toolResult(let d): try c.encode(d, forKey: .data)
        case .approvalCard(let d): try c.encode(d, forKey: .data)
        case .approvalAnswer(let d): try c.encode(d, forKey: .data)
        case .ruleProposal(let d): try c.encode(d, forKey: .data)
        case .ruleList(let d): try c.encode(d, forKey: .data)
        case .ruleUpdate(let d): try c.encode(d, forKey: .data)
        case .ruleDelete(let d): try c.encode(d, forKey: .data)
        case .approvalSettings(let d): try c.encode(d, forKey: .data)
        case .questionCard(let d): try c.encode(d, forKey: .data)
        case .questionAnswer(let d): try c.encode(d, forKey: .data)
        case .progressCard(let d): try c.encode(d, forKey: .data)
        case .toolResultRequest(let d): try c.encode(d, forKey: .data)
        case .threadCreate(let d): try c.encode(d, forKey: .data)
        case .threadList(let d): try c.encode(d, forKey: .data)
        case .threadArchive(let d): try c.encode(d, forKey: .data)
        case .threadRename(let d): try c.encode(d, forKey: .data)
        case .threadPin(let d): try c.encode(d, forKey: .data)
        case .threadRead(let d): try c.encode(d, forKey: .data)
        case .threadSetModel(let d): try c.encode(d, forKey: .data)
        case .threadRecover(let d): try c.encode(d, forKey: .data)
        case .threadSetBypass(let d): try c.encode(d, forKey: .data)
        case .threadSetEffort(let d): try c.encode(d, forKey: .data)
        case .modelList(let d): try c.encode(d, forKey: .data)
        case .projectList(let d): try c.encode(d, forKey: .data)
        case .interrupt(let d): try c.encode(d, forKey: .data)
        case .syncRequest(let d): try c.encode(d, forKey: .data)
        case .syncDelta(let d): try c.encode(d, forKey: .data)
        case .deviceList(let d): try c.encode(d, forKey: .data)
        case .deviceRemove(let d): try c.encode(d, forKey: .data)
        case .receipt(let d): try c.encode(d, forKey: .data)
        }
    }
}

/// A file sent along with a message: a photo, a screenshot, a PDF. The bytes travel inline
/// rather than as a reference, because the relay stores nothing — a link to it would have
/// nowhere to point.
public struct MessageAttachment: Codable, Equatable, Sendable {
    /// Largest attachment this device will send, decoded. A message is sealed, framed and held
    /// whole in memory at both ends and at the relay, so the cap is about what that costs.
    /// Mirrors `ATTACHMENT_MAX_BYTES` in packages/shared/src/events.ts.
    public static let maxBytes = 5 * 1024 * 1024
    public static let maxCount = 10
    public static let maxTotalBytes = 20 * 1024 * 1024
    public static let maxPerMessage = maxCount
    public static let messageMaxBytes = maxTotalBytes

    public static func withinLimits(_ attachments: [MessageAttachment]) -> Bool {
        attachments.count <= maxCount
            && attachments.allSatisfy { ($0.bytes?.count ?? maxBytes + 1) <= maxBytes }
            && attachments.compactMap(\.bytes).reduce(0) { $0 + $1.count } <= maxTotalBytes
    }

    /// Original file name. What a text-only model is told was attached.
    public var name: String
    /// IANA media type, e.g. "image/jpeg". `image/*` is what a vision model is handed.
    public var mime: String
    /// The file itself, standard base64 with padding.
    public var data: String

    public init(name: String, mime: String, data: String) {
        self.name = name
        self.mime = mime
        self.data = data
    }

    /// Wraps raw bytes, refusing anything over ``maxBytes`` rather than sending a frame the
    /// other end would have to reject: the cap is the sender's job, and the user is standing
    /// right here to be told.
    public init?(name: String, mime: String, bytes: Data) {
        guard bytes.count <= Self.maxBytes else { return nil }
        self.init(name: name, mime: mime, data: bytes.base64EncodedString())
    }

    /// The bytes back, or nil if what arrived was not base64 after all.
    public var bytes: Data? { Data(base64Encoded: data) }
    public var byteCount: Int { bytes?.count ?? 0 }

    public var isImage: Bool { mime.hasPrefix("image/") }
}

public struct MessageData: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, agent }
    public var role: Role
    public var text: String
    /// Set on the last message of a turn — a delegated agent's, so the phone's inline card for
    /// that delegation stops spinning, and the main agent's, so the composer stops offering
    /// Stop. A flag rather than a kind of its own: the final message already ends the turn.
    public var done: Bool?
    /// Photos and files the user sent with this message. Only set on a `user` message.
    public var attachments: [MessageAttachment]
    /// Source compatibility for callers that still handle one attachment.
    public var attachment: MessageAttachment? { attachments.first }

    public init(
        role: Role,
        text: String,
        done: Bool? = nil,
        attachment: MessageAttachment? = nil,
        attachments: [MessageAttachment] = []
    ) {
        self.role = role
        self.text = text
        self.done = done
        self.attachments = attachments.isEmpty ? attachment.map { [$0] } ?? [] : attachments
    }

    private enum CodingKeys: String, CodingKey { case role, text, done, attachment, attachments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        done = try c.decodeIfPresent(Bool.self, forKey: .done)
        attachments = try c.decodeIfPresent([MessageAttachment].self, forKey: .attachments)
            ?? c.decodeIfPresent(MessageAttachment.self, forKey: .attachment).map { [$0] }
            ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(done, forKey: .done)
        guard !attachments.isEmpty else { return }
        // The first item keeps older Yorozu clients useful; current clients prefer the array.
        try c.encode(attachments[0], forKey: .attachment)
        try c.encode(attachments, forKey: .attachments)
    }
}

/// A reaction targets an immutable message. Latest event from one device wins; `remove` clears
/// that device's matching emoji while preserving reactions from other devices.
public struct ReactionData: Codable, Equatable, Sendable {
    public var messageId: String
    public var emoji: String
    public var remove: Bool?

    public init(messageId: String, emoji: String, remove: Bool? = nil) {
        self.messageId = messageId
        self.emoji = emoji
        self.remove = remove
    }
}

public struct ThoughtData: Codable, Equatable, Sendable {
    public var text: String
    /// Live lifecycle status, replaced by newer status and removed when substantive work arrives.
    public var transient: Bool?
    public init(text: String, transient: Bool? = nil) {
        self.text = text
        self.transient = transient
    }
}

public struct ToolCallData: Codable, Equatable, Sendable {
    public var callId: String
    public var name: String
    public var args: [String: JSONValue]
    public init(callId: String, name: String, args: [String: JSONValue]) {
        self.callId = callId
        self.name = name
        self.args = args
    }
}

public struct ToolResultData: Codable, Equatable, Sendable {
    public var callId: String
    public var ok: Bool
    public var output: String
    /// True when ``output`` is only the head of what the tool printed. The rest is on the Mac,
    /// one ``ToolResultRequestData`` away. Nil means this is all there was.
    public var truncated: Bool?
    public init(callId: String, ok: Bool, output: String, truncated: Bool? = nil) {
        self.callId = callId
        self.ok = ok
        self.output = output
        self.truncated = truncated
    }
}

/// A device asking for the whole of a truncated tool result. Answered to that device alone with
/// the full `tool_result` under the id it already holds, so it replaces the short one in place.
public struct ToolResultRequestData: Codable, Equatable, Sendable {
    public var callId: String
    public init(callId: String) { self.callId = callId }
}

/// What an action commits, field by field: the concrete payload rather than the tool mechanics
/// behind it. Every field is optional because no one action carries all of them — a message has
/// a recipient and no merchant, a purchase the other way round.
public struct ApprovalScope: Codable, Equatable, Sendable {
    /// send, purchase, transfer, book, delete, edit, run, subscribe, trade.
    public var operation: String?
    public var recipient: String?
    public var account: String?
    public var merchant: String?
    public var category: String?
    public var quantity: Double?
    /// The first 200 characters of what would be sent or written.
    public var contentSummary: String?
    /// One line the tool declares: what happens once this runs.
    public var consequence: String?

    public init(
        operation: String? = nil,
        recipient: String? = nil,
        account: String? = nil,
        merchant: String? = nil,
        category: String? = nil,
        quantity: Double? = nil,
        contentSummary: String? = nil,
        consequence: String? = nil
    ) {
        self.operation = operation
        self.recipient = recipient
        self.account = account
        self.merchant = merchant
        self.category = category
        self.quantity = quantity
        self.contentSummary = contentSummary
        self.consequence = consequence
    }

    /// The fields worth drawing, in the order the card draws them, skipping the empty ones.
    public var rows: [(label: String, value: String)] {
        [
            ("To", recipient),
            ("Merchant", merchant),
            ("Account", account),
            ("Category", category),
            ("Quantity", quantity.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }),
        ].compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
    }
}

/// One item of a batch. A decision covers exactly the items the card listed.
public struct BatchItem: Codable, Equatable, Sendable, Identifiable {
    public var label: String
    public var detail: String?
    /// Local only: the list is drawn from a value type with no id of its own on the wire.
    public var id: String { detail.map { "\(label)\u{1F}\($0)" } ?? label }

    public init(label: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey { case label, detail }
}

/// How a rule matches one scope field.
public struct ApprovalRuleField: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case exact, prefix, glob }
    public var mode: Mode
    public var value: String
    public init(mode: Mode, value: String) {
        self.mode = mode
        self.value = value
    }
}

/// A standing decision. Global: it matches on what an action is, never on which agent takes it.
public struct ApprovalRule: Codable, Equatable, Sendable, Identifiable {
    public enum Decision: String, Codable, Sendable, CaseIterable { case never, always }
    public var id: String
    public var actionClass: String
    public var decision: Decision
    /// Per-field patterns, keyed by scope field. A field left out is not constrained — "any".
    public var scope: [String: ApprovalRuleField]?
    public var maxAmount: Double?
    /// Absent means enabled.
    public var enabled: Bool?
    public var createdAt: Double?
    public var lastUsed: Double?
    public var useCount: Int?

    public init(
        id: String,
        actionClass: String,
        decision: Decision,
        scope: [String: ApprovalRuleField]? = nil,
        maxAmount: Double? = nil,
        enabled: Bool? = nil,
        createdAt: Double? = nil,
        lastUsed: Double? = nil,
        useCount: Int? = nil
    ) {
        self.id = id
        self.actionClass = actionClass
        self.decision = decision
        self.scope = scope
        self.maxAmount = maxAmount
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastUsed = lastUsed
        self.useCount = useCount
    }

    /// The scope fields a rule can constrain, in the order an editor lists them. Kept in step
    /// with `APPROVAL_SCOPE_FIELDS` in packages/shared/src/events.ts.
    public static let scopeFields = ["target", "operation", "recipient", "account", "merchant", "category"]

    public var isEnabled: Bool { enabled ?? true }
}

/// Pending external action awaiting an answer. See ``ApprovalAnswerData`` for the choices.
public struct ApprovalCardData: Codable, Equatable, Sendable {
    public var nativeAgent: ThreadAgent?
    public var actionId: String
    /// e.g. "send-message", "purchase", "delete-file".
    public var actionClass: String
    public var target: String
    public var amount: Double?
    /// What the action commits, field by field.
    public var scope: ApprovalScope?
    /// The exact items one decision covers, when the tool declared a batch.
    public var items: [BatchItem]?
    /// Set when no stored rule may stand in for a fresh answer to this card.
    public var mustConfirm: Bool?
    /// The narrowest rule that would cover this action: what "Always allow" opens prefilled.
    public var suggestedRule: ApprovalRule?

    public init(
        actionId: String,
        actionClass: String,
        target: String,
        amount: Double? = nil,
        scope: ApprovalScope? = nil,
        items: [BatchItem]? = nil,
        mustConfirm: Bool? = nil,
        suggestedRule: ApprovalRule? = nil,
        nativeAgent: ThreadAgent? = nil
    ) {
        self.actionId = actionId
        self.actionClass = actionClass
        self.target = target
        self.amount = amount
        self.scope = scope
        self.items = items
        self.mustConfirm = mustConfirm
        self.nativeAgent = nativeAgent
        self.suggestedRule = suggestedRule
    }
}

public struct ApprovalAnswerData: Codable, Equatable, Sendable {
    /// Declaration order is the order the card shows the choices in. `yes` runs this one
    /// action; `task` also covers the same scope for the rest of the turn and expires with it;
    /// `always` runs it and saves ``rule``, which persists until revoked. Neither is a refusal.
    public enum Answer: String, Codable, Sendable, CaseIterable { case yes, task, always, no, discuss }
    public var actionId: String
    public var answer: Answer
    /// The rule the editor produced, sent with `always`.
    public var rule: ApprovalRule?
    /// Where the answer was given. `notification` is a lock-screen button, which the runtime
    /// honours only for a card it judged quick-approvable itself: the relay chose which buttons
    /// the push drew, and the relay is not trusted to decide what a button may approve.
    public var source: Source?
    public enum Source: String, Codable, Sendable { case notification }
    public init(actionId: String, answer: Answer, rule: ApprovalRule? = nil, source: Source? = nil) {
        self.actionId = actionId
        self.answer = answer
        self.rule = rule
        self.source = source
    }
}

/// The runtime has taken a command this device sent. The outbox holds a command until this
/// arrives: a socket that accepted a send is not a runtime that received it.
public struct ReceiptData: Codable, Equatable, Sendable {
    public var eventId: String
    public init(eventId: String) { self.eventId = eventId }
}

/// Repeated matching approvals, offered back as a rule. Never active until the user saves it.
public struct RuleProposalData: Codable, Equatable, Sendable {
    public var proposalId: String
    public var rule: ApprovalRule
    /// How many matching approvals prompted it.
    public var approvals: Int
    public init(proposalId: String, rule: ApprovalRule, approvals: Int) {
        self.proposalId = proposalId
        self.rule = rule
        self.approvals = approvals
    }
}

/// Every stored rule, as Settings lists them. Sent on request and after any change.
public struct RuleListData: Codable, Equatable, Sendable {
    public var rules: [ApprovalRule]
    public init(rules: [ApprovalRule] = []) { self.rules = rules }
}

/// Global approval configuration. An empty payload requests current state; `yolo` updates it.
public struct ApprovalSettingsData: Codable, Equatable, Sendable {
    public var yolo: Bool?
    public init(yolo: Bool? = nil) { self.yolo = yolo }
}

/// Saves a rule: a new one, or the edited form of the one with the same id.
public struct RuleUpdateData: Codable, Equatable, Sendable {
    public var rule: ApprovalRule
    public init(rule: ApprovalRule) { self.rule = rule }
}

/// Revokes a rule outright. Answered with a fresh `rule_list`.
public struct RuleDeleteData: Codable, Equatable, Sendable {
    public var ruleId: String
    public init(ruleId: String) { self.ruleId = ruleId }
}

/// A choice the agent needs made before it can carry on, raised by its `ask_user` tool. Unlike
/// an approval card this is not about permission: nothing is pending, the agent simply does not
/// know which way to go, and its tool call stays suspended until an answer goes back.
public struct QuestionCardData: Codable, Equatable, Sendable {
    public var questionId: String
    public var question: String
    /// The choices, in the order the card lists them. May be empty when only free text fits.
    public var options: [String]
    /// Whether the card also offers a free-text field. Absent on the wire means it does not.
    public var allowOther: Bool?
    public init(questionId: String, question: String, options: [String], allowOther: Bool? = nil) {
        self.questionId = questionId
        self.question = question
        self.options = options
        self.allowOther = allowOther
    }

    /// What the card draws, rather than what the wire carries: an absent flag is a no.
    public var offersFreeText: Bool { allowOther == true }
}

public struct QuestionAnswerData: Codable, Equatable, Sendable {
    public var questionId: String
    /// One of the options, or whatever was typed when the card offered free text.
    public var answer: String
    public init(questionId: String, answer: String) {
        self.questionId = questionId
        self.answer = answer
    }
}

/// One line of a progress card.
public struct ProgressStep: Codable, Equatable, Sendable, Identifiable {
    /// Declaration order is the order a step moves through, which is also how the card reads.
    public enum State: String, Codable, Sendable, CaseIterable { case pending, running, done, failed }
    public var label: String
    public var state: State
    /// The label is what tells two steps of one card apart; a card is a handful of lines.
    public var id: String { label }
    public init(label: String, state: State) {
        self.label = label
        self.state = state
    }

    /// Hand-written so a state this build has never heard of is a step not started yet, rather
    /// than a card that fails to decode: the runtime may be newer than the app.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        state = (try? c.decode(State.self, forKey: .state)) ?? .pending
    }
}

/// A long job reporting where it has got to, raised by the agent's `report_progress` tool.
/// The runtime re-emits an update under the event id it first used, so a client that upserts
/// on the id moves this card along instead of stacking another one under it.
public struct ProgressCardData: Codable, Equatable, Sendable {
    public var cardId: String
    public var title: String
    public var steps: [ProgressStep]
    /// 0–100. Nil when the job cannot say, and the steps are the whole of the progress.
    public var percent: Double?
    public init(cardId: String, title: String, steps: [ProgressStep], percent: Double? = nil) {
        self.cardId = cardId
        self.title = title
        self.steps = steps
        self.percent = percent
    }

    /// What the bar fills to, 0–1: the reported percentage, or the steps that are finished
    /// when the job did not report one. A card with no steps at all has nothing to show.
    public var fraction: Double? {
        if let percent { return min(1, max(0, percent / 100)) }
        guard !steps.isEmpty else { return nil }
        return Double(steps.filter { $0.state == .done }.count) / Double(steps.count)
    }

    /// A job is still going until every step has settled one way or the other.
    public var running: Bool { steps.contains { $0.state == .pending || $0.state == .running } }
}

/// Who answers a thread. `yorozu` is today's loop; the other two are native CLI coding agents,
/// each thread one of their sessions. Absent on the wire means `yorozu`.
public enum ThreadAgent: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case yorozu
    case claudeCode = "claude-code"
    case codex

    public var id: Self { self }

    /// What a picker and a row call it.
    public var label: String {
        switch self {
        case .yorozu: "Yorozu"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The small glyph a row wears. Nil for Yorozu: its rows are drawn as they always were.
    public var symbol: String? {
        switch self {
        case .yorozu: nil
        case .claudeCode: "chevron.left.forwardslash.chevron.right"
        case .codex: "terminal"
        }
    }

    /// Whether the agent needs a folder to work in. Yorozu works everywhere; the coding agents
    /// each run in one project.
    public var needsFolder: Bool { self != .yorozu }
}

/// One folder a coding agent's thread can be started in. Only the folder itself is here: what
/// is inside it never leaves the Mac.
public struct ProjectFolder: Codable, Equatable, Sendable, Identifiable {
    /// Absolute path on the Mac. What `thread_create` carries back as `cwd`.
    public var path: String
    /// The folder's own name, e.g. "yorozu".
    public var name: String
    /// Epoch milliseconds a thread was last started in it. Nil for a folder never used.
    public var lastUsed: Double?

    public var id: String { path }

    public init(path: String, name: String, lastUsed: Double? = nil) {
        self.path = path
        self.name = name
        self.lastUsed = lastUsed
    }
}

/// The Mac's known project folders, recents first. Pushed with the thread list; a device sends
/// an empty one to ask.
public struct ProjectListData: Codable, Equatable, Sendable {
    public var projects: [ProjectFolder]
    public init(projects: [ProjectFolder]) { self.projects = projects }
}

public struct ThreadCreateData: Codable, Equatable, Sendable {
    public var title: String?
    /// Which agent answers the thread, for its whole life. Nil means `yorozu`.
    public var agent: ThreadAgent?
    /// The working directory a native agent runs in, fixed at creation. Only they have one.
    public var cwd: String?
    public init(title: String? = nil, agent: ThreadAgent? = nil, cwd: String? = nil) {
        self.title = title
        self.agent = agent
        self.cwd = cwd
    }
}

/// Portable reasoning levels supported by both subscription CLI providers. Nil on a thread
/// leaves the provider's own default in charge.
public enum ReasoningEffort: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case minimal, low, medium, high, xhigh, max, ultra, persistent

    public var id: Self { self }
    public var label: String { rawValue.capitalized }
}

/// Renames `threadId` from the base fields. A title the user chose: auto-titling leaves it alone.
public struct ThreadRenameData: Codable, Equatable, Sendable {
    public var title: String
    public init(title: String) { self.title = title }
}

public struct ThreadSummary: Codable, Equatable, Sendable, Identifiable {
    public var interruptedTurnId: String?
    public var bypass: Bool?
    public var id: String
    /// Empty until the runtime auto-titles the thread or the user renames it.
    public var title: String
    public var archived: Bool
    /// When the thread was last written to, epoch milliseconds. What the lists order on.
    public var lastActivity: Double
    /// One line of the newest message in the thread, whoever said it, for a row's preview.
    /// Nil in a thread nothing has been said in yet, so a row draws nothing rather than a blank.
    public var lastMessage: String?
    /// Pinned threads lead the phone's list.
    public var pinned: Bool
    /// The `<providerId>/<model>` spec this thread's turns run on. Nil — nearly always — means
    /// the Mac's configured chain, which is what the picker draws as "Default".
    public var model: String?
    /// How much reasoning each turn requests. Nil means the provider's default.
    public var effort: ReasoningEffort?
    /// Which agent answers this thread. Nil means `yorozu`, which is also what a runtime older
    /// than the field is saying by leaving it out — and an agent this build does not know.
    public var agent: ThreadAgent?
    /// A native agent's working directory. Nil on a `yorozu` thread.
    public var cwd: String?
    /// When the thread was last read, on any device, epoch milliseconds. The runtime owns it,
    /// so reading on the phone clears the dot on the Mac too. Nil means never.
    public var lastReadAt: Double?
    /// `ts` of the newest agent message in the thread. Nil where the agent has not spoken yet.
    public var lastAgentAt: Double?

    public init(
        id: String,
        title: String,
        archived: Bool,
        lastActivity: Double,
        lastMessage: String? = nil,
        pinned: Bool = false,
        model: String? = nil,
        effort: ReasoningEffort? = nil,
        agent: ThreadAgent? = nil,
        cwd: String? = nil,
        lastReadAt: Double? = nil,
        lastAgentAt: Double? = nil,
        bypass: Bool? = nil,
        interruptedTurnId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.archived = archived
        self.lastActivity = lastActivity
        self.lastMessage = lastMessage
        self.pinned = pinned
        self.model = model
        self.effort = effort
        self.agent = agent
        self.cwd = cwd
        self.lastReadAt = lastReadAt
        self.lastAgentAt = lastAgentAt
        self.bypass = bypass
        self.interruptedTurnId = interruptedTurnId
    }

    /// Hand-written only to tolerate a runtime older than the last two fields: both were added
    /// after v1 shipped, and a cached list written before them must still read back.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        archived = try c.decode(Bool.self, forKey: .archived)
        lastActivity = try c.decode(Double.self, forKey: .lastActivity)
        lastMessage = try c.decodeIfPresent(String.self, forKey: .lastMessage)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .effort)
        // An agent a newer runtime knows and this build does not is not a thread that fails to
        // list: it is drawn as an ordinary one.
        agent = ThreadAgent(rawValue: try c.decodeIfPresent(String.self, forKey: .agent) ?? "")
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        bypass = try c.decodeIfPresent(Bool.self, forKey: .bypass)
        interruptedTurnId = try c.decodeIfPresent(String.self, forKey: .interruptedTurnId)
        lastReadAt = try c.decodeIfPresent(Double.self, forKey: .lastReadAt)
        lastAgentAt = try c.decodeIfPresent(Double.self, forKey: .lastAgentAt)
    }

    /// What a list draws: an untitled thread is one the runtime has not named yet.
    public var displayTitle: String { title.isEmpty ? "New chat" : title }

    /// The last path component of ``cwd``: the repo a coding agent's row is subtitled with.
    public var repoName: String? {
        guard let cwd else { return nil }
        let name = cwd.split(separator: "/").last.map(String.init) ?? cwd
        return name.isEmpty ? nil : name
    }

    /// Whether the agent has said something here since anyone last read it. The one definition
    /// of unread — what every dot, bold title and app badge on both platforms is drawn from.
    ///
    /// Deliberately not "a reply arrived while this device had the thread closed": that answer
    /// differs per device, and was wrong on any device that happened to be asleep for it.
    public var isUnread: Bool { (lastAgentAt ?? 0) > (lastReadAt ?? 0) }

    /// ``lastActivity`` as a date, which is what a row formats relative to now.
    public var lastActivityDate: Date { Date(timeIntervalSince1970: lastActivity / 1000) }
}

public struct ThreadListData: Codable, Equatable, Sendable {
    public var threads: [ThreadSummary]
    public init(threads: [ThreadSummary]) { self.threads = threads }
}

/// Archives `threadId` from the base fields, or brings it back when ``archived`` is false.
/// The flag is optional because the frame meant "archive" before unarchiving existed, and a
/// phone from then still sends `{}`.
public struct ThreadArchiveData: Codable, Equatable, Sendable {
    public var archived: Bool?
    public init(archived: Bool? = nil) { self.archived = archived }
}

/// Pins or unpins `threadId` from the base fields.
public struct ThreadPinData: Codable, Equatable, Sendable {
    public var pinned: Bool
    public init(pinned: Bool) { self.pinned = pinned }
}

/// The thread named in the event's base fields was read, up to ``at``. Sent only by a device
/// that is genuinely looking at it — see ``ChatModel/isReading(_:)`` — and answered with a
/// fresh `thread_list`, which is what drops the dot on every other device too.
///
/// The runtime keeps the later of what it holds and ``at``, so two devices reporting out of
/// order cannot walk the mark backwards. ``reset`` is the exception "Mark as unread" needs.
public struct ThreadReadData: Codable, Equatable, Sendable {
    /// Epoch milliseconds read up to. Normally now; `lastAgentAt - 1` to mark unread.
    public var at: Double
    /// Set only by "Mark as unread": assign ``at`` rather than taking the later of the two.
    public var reset: Bool?

    public init(at: Double, reset: Bool? = nil) {
        self.at = at
        self.reset = reset
    }
}

/// Sets the thread named in the event's base fields to one model, as a spec from
/// ``ModelListData``. Nil — which encodes as an absent field, and which the runtime reads the
/// same as an explicit null — puts the thread back on the Mac's configured chain.
public struct ThreadSetModelData: Codable, Equatable, Sendable {
    public var model: String?
    public init(model: String?) { self.model = model }
}

/// Sets one thread's reasoning effort. Nil resets it to the provider default.
public struct ThreadSetEffortData: Codable, Equatable, Sendable {
    public var effort: ReasoningEffort?
    public init(effort: ReasoningEffort?) { self.effort = effort }
}

/// One model a thread can be put on, named the way a picker draws it.
public struct ModelOption: Codable, Equatable, Sendable, Identifiable {
    public var efforts: [ReasoningEffort]?
    /// The `<providerId>/<model>` spec. What ``ThreadSetModelData`` carries.
    public var id: String
    /// The model's own name, e.g. "claude-opus-5".
    public var label: String
    /// The provider entry it belongs to, e.g. "Claude". What a menu groups on.
    public var providerLabel: String

    public init(id: String, label: String, providerLabel: String, efforts: [ReasoningEffort]? = nil) {
        self.efforts = efforts
        self.id = id
        self.label = label
        self.providerLabel = providerLabel
    }

    /// Both names on one line, which is what a menu row has room for: the provider is what
    /// tells two models with similar names apart.
    public var menuLabel: String { label == providerLabel ? label : "\(providerLabel) · \(label)" }
}

/// Every model the Mac is configured for. Pushed with the thread list rather than asked for,
/// so a picker one tap from a thread has real names before it is opened.
public struct ModelListData: Codable, Equatable, Sendable {
    public var models: [ModelOption]
    public var agentModels: [String: [ModelOption]]?
    public init(models: [ModelOption], agentModels: [String: [ModelOption]]? = nil) {
        self.models = models
        self.agentModels = agentModels
    }
}

/// The user pressed stop: cancel the turn running in `threadId` and every agent it
/// delegated to. Carries nothing of its own.
public struct InterruptData: Codable, Equatable, Sendable {
    public init() {}
}

/// Last event id the device already holds, per thread.
public struct SyncRequestData: Codable, Equatable, Sendable {
    public var lastSeen: [String: String]
    public init(lastSeen: [String: String]) { self.lastSeen = lastSeen }
}

public struct SyncDeltaData: Codable, Equatable, Sendable {
    public var events: [YorozuEvent]
    /// Threads with a turn still running on the Mac when this page was made.
    public var workingThreadIds: [String]?
    public var more: Bool?
    public init(events: [YorozuEvent], workingThreadIds: [String]? = nil, more: Bool? = nil) {
        self.events = events
        self.workingThreadIds = workingThreadIds
        self.more = more
    }
}

/// One device this Mac is paired with, as the Devices tab lists them. Public keys only: they
/// are identifiers here, and the short form of ``pub`` is what the user sees.
public struct DeviceInfo: Codable, Equatable, Sendable, Identifiable {
    /// How the device reaches the runtime.
    public enum Via: String, Codable, Sendable { case relay, local }
    /// X25519 public key, base64url. What the sidecar seals for, and the device's identity.
    public var pub: String
    /// Ed25519 key the relay knows the device by, when it announced one. A different key from
    /// ``pub`` and not derivable from it, so revoking at the relay needs it carried here.
    public var signingPub: String?
    public var via: Via
    /// Epoch milliseconds the runtime last heard from it.
    public var lastSeen: Double
    public var online: Bool

    public var id: String { pub }

    /// Enough of the key to tell two devices apart, which is all a list needs.
    public var shortId: String { String(pub.prefix(8)) }

    public init(pub: String, signingPub: String? = nil, via: Via, lastSeen: Double, online: Bool) {
        self.pub = pub
        self.signingPub = signingPub
        self.via = via
        self.lastSeen = lastSeen
        self.online = online
    }
}

public struct DeviceListData: Codable, Equatable, Sendable {
    public var devices: [DeviceInfo]
    public init(devices: [DeviceInfo]) { self.devices = devices }
}

/// Forget a device: dropped from the runtime's `devices.json`, and the relay is told to revoke
/// it so it cannot rejoin against the nonce either. Answered with a fresh `device_list`.
public struct DeviceRemoveData: Codable, Equatable, Sendable {
    public var pub: String
    public init(pub: String) { self.pub = pub }
}

/// Arbitrary JSON, for tool arguments the schema cannot know ahead of time.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// Payload carried by a pairing QR code.
public struct QrPayload: Codable, Equatable, Sendable {
    public var v: Int
    public var relayUrl: String
    /// Mac X25519 public key, base64url, 32 raw bytes. Used for the session key agreement.
    public var macPubkey: String
    /// One-time relay join token.
    public var token: String
    /// Relay room to join: base64url sha256 of the Mac's Ed25519 relay key, which is a
    /// different key from `macPubkey` and so cannot be derived from it.
    public var roomId: String?
    /// A Mac-minted secret the relay never sees: the QR goes from the Mac's screen to this
    /// phone's camera. The first `hello` proves the phone holds it (``YorozuCrypto/helloProof``),
    /// which is what stops a relay from enrolling a device of its own.
    public var secret: String?

    public init(
        v: Int = 1, relayUrl: String, macPubkey: String, token: String, roomId: String? = nil,
        secret: String? = nil
    ) {
        self.v = v
        self.relayUrl = relayUrl
        self.macPubkey = macPubkey
        self.token = token
        self.roomId = roomId
        self.secret = secret
    }

    public func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    /// The one parser for every way a pairing arrives: the QR, a pasted string, a tapped
    /// `yorozu://` link, or the JSON form older codes carried. Throws on anything that is
    /// not a v1 payload.
    public static func decode(_ text: String) throws -> QrPayload {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("yorozu:") { return try decodePairingString(text) }
        let payload = try JSONDecoder().decode(QrPayload.self, from: Data(text.utf8))
        guard payload.v == 1 else {
            throw YorozuCrypto.CryptoError.malformed("not a Yorozu v1 QR payload")
        }
        return payload
    }

    /// `yorozu://pair?v=1&relay=<urlencoded>&key=<base64url>&token=<base64url>`, the compact
    /// form the Mac shows for copying and encodes in the QR.
    private static func decodePairingString(_ text: String) throws -> QrPayload {
        func malformed() -> Error {
            YorozuCrypto.CryptoError.malformed("not a Yorozu v1 pairing string")
        }
        /// Base64url, unpadded, is the only thing the keys and the token are ever spelled in.
        /// The same check `decodePairingString` makes in TypeScript, so neither side accepts a
        /// code the other would refuse.
        func base64Url(_ value: String?) throws -> String {
            let alphabet = CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
            )
            guard let value, !value.isEmpty, value.unicodeScalars.allSatisfy(alphabet.contains) else {
                throw malformed()
            }
            return value
        }
        let items = URLComponents(string: text)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard query["v"] == "1", let relayUrl = query["relay"], !relayUrl.isEmpty else {
            throw malformed()
        }
        return QrPayload(
            relayUrl: relayUrl,
            macPubkey: try base64Url(query["key"]),
            token: try base64Url(query["token"]),
            roomId: query["room"].flatMap { $0.isEmpty ? nil : $0 },
            secret: try query["secret"].flatMap { $0.isEmpty ? nil : $0 }.map(base64Url)
        )
    }
}

public struct ThreadSetBypassData: Codable, Equatable, Sendable {
    public var bypass: Bool
    public init(bypass: Bool) { self.bypass = bypass }
}

public struct ThreadRecoverData: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case `continue`, dismiss }
    public var turnId: String
    public var action: Action
    public init(turnId: String, action: Action) { self.turnId = turnId; self.action = action }
}
