import Foundation
import Testing

@testable import YorozuShared

/// One saved rule, used wherever a kind carries one.
private let sampleRule = ApprovalRule(
    id: "r1",
    actionClass: "purchase",
    decision: .always,
    scope: ["merchant": ApprovalRuleField(mode: .exact, value: "Kurasu")],
    maxAmount: 48,
    enabled: true,
    createdAt: 1_700_000_000_000,
    lastUsed: 1_700_000_100_000,
    useCount: 4
)

private func roundTrip(_ event: YorozuEvent) throws -> YorozuEvent {
    try JSONDecoder().decode(YorozuEvent.self, from: JSONEncoder().encode(event))
}

@Test(arguments: YorozuEvent.Kind.allCases)
func everyKindRoundTrips(kind: YorozuEvent.Kind) throws {
    let payload: YorozuEvent.Payload =
        switch kind {
        case .message:
            .message(
                MessageData(
                    role: .user,
                    text: "hi",
                    attachment: MessageAttachment(name: "receipt.png", mime: "image/png", data: "aGk=")
                )
            )
        case .thought: .thought(ThoughtData(text: "checking the catalog"))
        case .toolCall: .toolCall(ToolCallData(callId: "c1", name: "shell", args: ["cmd": .string("ls")]))
        case .toolResult: .toolResult(ToolResultData(callId: "c1", ok: true, output: "README.md"))
        case .approvalCard:
            .approvalCard(
                ApprovalCardData(
                    actionId: "a1",
                    actionClass: "purchase",
                    target: "amazon",
                    amount: 12,
                    scope: ApprovalScope(
                        operation: "purchase",
                        merchant: "Kurasu",
                        quantity: 2,
                        contentSummary: "Ethiopia Guji, whole bean",
                        consequence: "Charges the Visa."
                    ),
                    items: [BatchItem(label: "Ethiopia Guji", detail: "1kg")],
                    mustConfirm: true,
                    suggestedRule: sampleRule
                )
            )
        case .approvalAnswer:
            .approvalAnswer(
                ApprovalAnswerData(actionId: "a1", answer: .always, rule: sampleRule)
            )
        case .ruleProposal:
            .ruleProposal(RuleProposalData(proposalId: "p1", rule: sampleRule, approvals: 3))
        case .ruleList: .ruleList(RuleListData(rules: [sampleRule]))
        case .ruleUpdate: .ruleUpdate(RuleUpdateData(rule: sampleRule))
        case .ruleDelete: .ruleDelete(RuleDeleteData(ruleId: "r1"))
        case .questionCard:
            .questionCard(
                QuestionCardData(
                    questionId: "q1",
                    question: "Which flight?",
                    options: ["the 09:15", "the 14:40"],
                    allowOther: true
                )
            )
        case .questionAnswer: .questionAnswer(QuestionAnswerData(questionId: "q1", answer: "the 09:15"))
        case .progressCard:
            .progressCard(
                ProgressCardData(
                    cardId: "job-1",
                    title: "Booking the table",
                    steps: [
                        ProgressStep(label: "find a restaurant", state: .done),
                        ProgressStep(label: "call them", state: .running),
                    ],
                    percent: 50
                )
            )
        case .threadCreate: .threadCreate(ThreadCreateData(title: "Groceries"))
        case .threadList:
            .threadList(ThreadListData(threads: [
                ThreadSummary(
                    id: "t1",
                    title: "Groceries",
                    archived: false,
                    lastActivity: 1_757_640_000_000,
                    lastMessage: "and eggs",
                    pinned: true
                )
            ]))
        case .threadArchive: .threadArchive(ThreadArchiveData(archived: false))
        case .threadRename: .threadRename(ThreadRenameData(title: "Weekend plans"))
        case .threadPin: .threadPin(ThreadPinData(pinned: true))
        case .threadRead: .threadRead(ThreadReadData(at: 1_757_640_000_000, reset: true))
        case .threadSetModel: .threadSetModel(ThreadSetModelData(model: "claude/claude-opus-5"))
        case .modelList:
            .modelList(ModelListData(models: [
                ModelOption(id: "claude/claude-opus-5", label: "claude-opus-5", providerLabel: "Claude"),
                ModelOption(id: "local/", label: "LM Studio", providerLabel: "LM Studio"),
            ]))
        case .interrupt: .interrupt(InterruptData())
        case .syncRequest: .syncRequest(SyncRequestData(lastSeen: ["home": "e9"]))
        case .syncDelta:
            .syncDelta(SyncDeltaData(events: [
                YorozuEvent(id: "e2", threadId: "home", ts: 2, agentId: "main", payload: .thought(ThoughtData(text: "x")))
            ]))
        case .deviceList:
            .deviceList(DeviceListData(devices: [
                DeviceInfo(pub: "k1", signingPub: "s1", via: .relay, lastSeen: 1_757_640_000_000, online: true),
                DeviceInfo(pub: "local-1", via: .local, lastSeen: 1_757_640_000_001, online: true),
            ]))
        case .deviceRemove: .deviceRemove(DeviceRemoveData(pub: "k1"))
        }
    let event = YorozuEvent(
        id: "e1",
        threadId: "home",
        ts: 1_757_640_000_000,
        agentId: "researcher",
        parentAgentId: "main",
        payload: payload
    )
    #expect(event.payload.kind == kind)
    #expect(try roundTrip(event) == event)
}

@Test func eventJsonUsesTheSharedShape() throws {
    let event = YorozuEvent(
        id: "e1",
        threadId: "home",
        ts: 1,
        agentId: "main",
        payload: .message(MessageData(role: .agent, text: "hi"))
    )
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
    #expect(json?["kind"] as? String == "message")
    #expect((json?["data"] as? [String: Any])?["role"] as? String == "agent")
    #expect(json?["parentAgentId"] == nil)
}

@Test func aFinishedDelegationFlagsItsLastMessage() throws {
    let event = YorozuEvent(
        id: "e1",
        threadId: "home",
        ts: 1,
        agentId: "calendar",
        parentAgentId: "main",
        payload: .message(MessageData(role: .agent, text: "booked", done: true))
    )
    #expect(try roundTrip(event) == event)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
    #expect((json?["data"] as? [String: Any])?["done"] as? Bool == true)

    // Absent on every other message, so the flag means exactly one thing on the wire.
    let plain = YorozuEvent(
        id: "e2",
        threadId: "home",
        ts: 1,
        agentId: "main",
        payload: .message(MessageData(role: .agent, text: "hi"))
    )
    let plainJson = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
    #expect((plainJson?["data"] as? [String: Any])?["done"] == nil)
}

@Test func qrPayloadsRoundTripAndUntrustedInputIsRejected() throws {
    let qr = QrPayload(relayUrl: "wss://relay.yumi.to", macPubkey: "AAA", token: "t", roomId: "r")
    #expect(try QrPayload.decode(qr.encoded()) == qr)
    // Payloads minted before rooms were carried in the QR still decode.
    let legacy = QrPayload(relayUrl: "wss://relay.yumi.to", macPubkey: "AAA", token: "t")
    #expect(try QrPayload.decode(legacy.encoded()).roomId == nil)
    #expect(throws: (any Error).self) { try QrPayload.decode(#"{"v":2,"relayUrl":"","macPubkey":"","token":""}"#) }
    #expect(throws: (any Error).self) { try QrPayload.decode("not json") }
}

@Test func pairingStringsAreParsedWhereverTheyCameFrom() throws {
    // What TypeScript's `encodePairingString` writes, percent-encoding and all.
    let code = "yorozu://pair?v=1&relay=ws%3A%2F%2F127.0.0.1%3A8791&key=AAA&token=t-_&room=r"
    #expect(
        try QrPayload.decode(code)
            == QrPayload(relayUrl: "ws://127.0.0.1:8791", macPubkey: "AAA", token: "t-_", roomId: "r")
    )
    // Whitespace is what a paste out of Messages brings with it.
    #expect(try QrPayload.decode("  \(code)\n").roomId == "r")
    #expect(try QrPayload.decode("yorozu://pair?v=1&relay=ws://r&key=AAA&token=t").roomId == nil)

    #expect(throws: (any Error).self) { try QrPayload.decode("yorozu://pair?v=1&relay=ws://r&token=t") }
    #expect(throws: (any Error).self) { try QrPayload.decode("yorozu://pair?v=1&key=AAA&token=t") }
    #expect(throws: (any Error).self) { try QrPayload.decode("yorozu://pair?v=1&relay=ws://r&key=AAA") }
    #expect(throws: (any Error).self) { try QrPayload.decode("yorozu://pair?v=2&relay=ws://r&key=AAA&token=t") }
    #expect(throws: (any Error).self) {
        try QrPayload.decode("yorozu://pair?v=1&relay=ws://r&key=not%20base64!&token=t")
    }
    #expect(throws: (any Error).self) { try QrPayload.decode("yorozu://nonsense") }
}

@Test func aDeviceListUsesTheSharedShape() throws {
    let event = YorozuEvent(
        id: "e1",
        threadId: "",
        ts: 1,
        agentId: "main",
        payload: .deviceList(
            DeviceListData(devices: [
                DeviceInfo(pub: "k1", signingPub: "s1", via: .relay, lastSeen: 2, online: false)
            ])
        )
    )
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
    #expect(json?["kind"] as? String == "device_list")
    let device = ((json?["data"] as? [String: Any])?["devices"] as? [[String: Any]])?.first
    #expect(device?["pub"] as? String == "k1")
    #expect(device?["signingPub"] as? String == "s1")
    #expect(device?["via"] as? String == "relay")
    #expect(device?["online"] as? Bool == false)

    // What the runtime writes, decoded as the Mac app receives it: a local device has no
    // relay identity, so `signingPub` is absent rather than empty.
    let wire = #"{"id":"e1","threadId":"","ts":1,"agentId":"main","kind":"device_list","data":{"devices":[{"pub":"local-1","via":"local","lastSeen":3,"online":true}]}}"#
    let decoded = try JSONDecoder().decode(YorozuEvent.self, from: Data(wire.utf8))
    guard case .deviceList(let data) = decoded.payload else { return #expect(Bool(false)) }
    #expect(data.devices.first?.signingPub == nil)
    #expect(data.devices.first?.shortId == "local-1")
}


/// The two fields a row draws beyond the title were added after v1: a summary from a runtime
/// that predates them has to read back as an unpinned thread with no preview, not fail to decode.
@Test func aThreadSummaryRoundTripsAndToleratesAnOlderRuntime() throws {
    let summary = ThreadSummary(
        id: "t1",
        title: "Groceries",
        archived: false,
        lastActivity: 1_757_640_000_000,
        lastMessage: "and eggs",
        pinned: true
    )
    let encoded = try JSONEncoder().encode(summary)
    #expect(try JSONDecoder().decode(ThreadSummary.self, from: encoded) == summary)

    let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    #expect(json?["lastMessage"] as? String == "and eggs")
    #expect(json?["pinned"] as? Bool == true)

    let v1 = Data(#"{"id":"t1","title":"","archived":false,"lastActivity":1}"#.utf8)
    let old = try JSONDecoder().decode(ThreadSummary.self, from: v1)
    #expect(old.lastMessage == nil)
    #expect(old.pinned == false)
    // And a thread on no model of its own, which is what "Default" is.
    #expect(old.model == nil)
    #expect(old.displayTitle == "New chat")
    #expect(old.lastActivityDate == Date(timeIntervalSince1970: 0.001))
}

/// `{}` is what a phone older than unarchiving sends, and it still means archive.
@Test func archivingCarriesAnOptionalFlag() throws {
    let legacy = try JSONDecoder().decode(ThreadArchiveData.self, from: Data("{}".utf8))
    #expect(legacy.archived == nil)
    #expect(try JSONEncoder().encode(ThreadArchiveData()) == Data("{}".utf8))

    let back = ThreadArchiveData(archived: false)
    #expect(try JSONDecoder().decode(ThreadArchiveData.self, from: JSONEncoder().encode(back)) == back)
}

@Test func anAttachmentIsBytesAndACapBothSidesAgreeOn() throws {
    let bytes = Data("hi".utf8)
    let attachment = try #require(MessageAttachment(name: "note.txt", mime: "text/plain", bytes: bytes))
    #expect(attachment.data == "aGk=")
    #expect(attachment.bytes == bytes)
    #expect(!attachment.isImage)
    #expect(MessageAttachment(name: "p.png", mime: "image/png", data: "aGk=").isImage)

    // The cap is the sender's job: over it, there is no attachment to send at all.
    #expect(MessageAttachment(name: "big", mime: "application/pdf", bytes: Data(count: 5 * 1024 * 1024)) != nil)
    #expect(MessageAttachment(name: "big", mime: "application/pdf", bytes: Data(count: 5 * 1024 * 1024 + 1)) == nil)
    // Mirrors ATTACHMENT_MAX_BYTES in packages/shared/src/events.ts.
    #expect(MessageAttachment.maxBytes == 5 * 1024 * 1024)
}

@Test func anAttachmentTravelsInTheMessagesOwnJson() throws {
    let event = YorozuEvent(
        id: "e1",
        threadId: "home",
        ts: 1,
        agentId: "phone",
        payload: .message(
            MessageData(
                role: .user,
                text: "what is this?",
                attachment: MessageAttachment(name: "receipt.png", mime: "image/png", data: "aGk=")
            )
        )
    )
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
    let data = try #require(json?["data"] as? [String: Any])
    let attachment = try #require(data["attachment"] as? [String: Any])
    #expect(attachment["name"] as? String == "receipt.png")
    #expect(attachment["mime"] as? String == "image/png")
    #expect(attachment["data"] as? String == "aGk=")

    // A message without one says nothing about attachments, so the key stays absent on the wire.
    let plain = YorozuEvent(
        id: "e2", threadId: "home", ts: 1, agentId: "phone",
        payload: .message(MessageData(role: .user, text: "hi"))
    )
    let plainJson = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
    #expect((plainJson?["data"] as? [String: Any])?["attachment"] == nil)
}

/// The wire spells the three grants out, and the declaration order is the card's button order:
/// Allow once, Allow for this task, Always allow, Don't allow, Discuss.
@Test func approvalAnswersRoundTripOnTheWire() throws {
    #expect(
        ApprovalAnswerData.Answer.allCases.map(\.rawValue) == ["yes", "task", "always", "no", "discuss"]
    )

    for answer in ApprovalAnswerData.Answer.allCases {
        let data = ApprovalAnswerData(actionId: "a1", answer: answer)
        let encoded = try JSONEncoder().encode(data)
        #expect(try JSONDecoder().decode(ApprovalAnswerData.self, from: encoded) == data)
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(json?["answer"] as? String == answer.rawValue)
    }

    let wire = Data(#"{"actionId":"a1","answer":"always"}"#.utf8)
    let decoded = try JSONDecoder().decode(ApprovalAnswerData.self, from: wire)
    #expect(decoded.answer == .always)
    // An answer with no rule on it is one typed in prose rather than saved from the editor.
    #expect(decoded.rule == nil)

    // The editor's rule travels with the answer, so the runtime saves what was on screen.
    let edited = ApprovalAnswerData(actionId: "a1", answer: .always, rule: sampleRule)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any]
    #expect(((json?["rule"] as? [String: Any])?["maxAmount"] as? Double) == 48)
}

/// A card older than the structured scope still decodes: every field beyond the first four is
/// optional, so a runtime that has not been updated yet does not break the phone.
@Test func anApprovalCardWithoutTheStructuredFieldsStillDecodes() throws {
    let wire = Data(#"{"actionId":"a1","actionClass":"purchase","target":"amazon"}"#.utf8)
    let card = try JSONDecoder().decode(ApprovalCardData.self, from: wire)
    #expect(card.scope == nil)
    #expect(card.items == nil)
    #expect(card.mustConfirm == nil)
    #expect(card.suggestedRule == nil)
}

/// What the card draws of a scope: the fields that were filled in, in a fixed order, and
/// nothing for the ones that were not.
@Test func aScopeOnlyOffersTheFieldsThatWereFilledIn() {
    let scope = ApprovalScope(
        operation: "purchase",
        account: "Visa ••4242",
        merchant: "Kurasu",
        quantity: 2,
        consequence: "Charges the Visa."
    )
    #expect(scope.rows.map(\.label) == ["Merchant", "Account", "Quantity"])
    #expect(scope.rows.map(\.value) == ["Kurasu", "Visa ••4242", "2"])
    #expect(ApprovalScope().rows.isEmpty)
}

/// A rule as one phrase: what the card's button and the Settings row both say it covers.
@Test func aRuleDescribesTheScopeItActuallyCovers() {
    #expect(sampleRule.summary.hasPrefix("purchase at Kurasu up to "))

    let toADomain = ApprovalRule(
        id: "r2",
        actionClass: "send-message",
        decision: .always,
        scope: ["recipient": ApprovalRuleField(mode: .glob, value: "*@example.com")]
    )
    #expect(toADomain.summary == "message to *@example.com")

    let underAPath = ApprovalRule(
        id: "r3",
        actionClass: "edit-file",
        decision: .always,
        scope: ["target": ApprovalRuleField(mode: .prefix, value: "/Users/yumi/Projects/")]
    )
    #expect(underAPath.summary == "file change on /Users/yumi/Projects/…")

    // Absent means enabled: a rule from a runtime that never wrote the flag is not switched off.
    #expect(toADomain.isEnabled)
    #expect(!ApprovalRule(id: "r4", actionClass: "purchase", decision: .always, enabled: false).isEnabled)
}

/// The editor: it opens on exactly what the rule pins down, widening a field to Any drops it,
/// and a rule that pins nothing down at all cannot be saved.
@Test func theRuleEditorWidensOnlyWhereItIsToldTo() {
    var draft = RuleEditorView.Draft(rule: sampleRule)
    #expect(draft.fields.filter { !$0.isAny }.map(\.id) == ["merchant"])
    #expect(draft.rule == sampleRule)

    // Widened: any merchant, but still capped, and still a purchase.
    let merchant = draft.fields.firstIndex { $0.id == "merchant" }!
    draft.fields[merchant].isAny = true
    #expect(draft.rule.scope == nil)
    #expect(draft.rule.maxAmount == 48)
    // Nothing pinned down and nothing but a cap is a blanket grant, which cannot be saved.
    #expect(!draft.isNarrowEnough)

    // Narrowed instead: a category the card never filled in.
    draft.fields[merchant].isAny = false
    let category = draft.fields.firstIndex { $0.id == "category" }!
    draft.fields[category].isAny = false
    draft.fields[category].value = " groceries "
    #expect(draft.isNarrowEnough)
    // Trimmed, because a pattern with a stray space in it silently matches nothing.
    #expect(draft.rule.scope?["category"] == ApprovalRuleField(mode: .exact, value: "groceries"))
    // And everything the rule carries that the editor is not about survives the round trip.
    #expect(draft.rule.id == sampleRule.id)
    #expect(draft.rule.useCount == 4)
    #expect(draft.rule.createdAt == sampleRule.createdAt)

    // The cap comes off on its own.
    draft.hasCap = false
    #expect(draft.rule.maxAmount == nil)
}

/// The wire shape of a question card, and what an absent `allowOther` means: a card offering
/// only its options, rather than one whose free-text field failed to decode.
@Test func questionCardsRoundTripAndOnlyOfferFreeTextWhenTheySaySo() throws {
    let card = QuestionCardData(
        questionId: "q1",
        question: "Which flight?",
        options: ["the 09:15", "the 14:40"],
        allowOther: true
    )
    #expect(try JSONDecoder().decode(QuestionCardData.self, from: JSONEncoder().encode(card)) == card)
    #expect(card.offersFreeText)

    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any]
    #expect(json?["questionId"] as? String == "q1")
    #expect(json?["options"] as? [String] == ["the 09:15", "the 14:40"])
    #expect(json?["allowOther"] as? Bool == true)

    // What the runtime writes when the card is options-only: the key is absent, not false.
    let wire = Data(#"{"questionId":"q2","question":"Tea or coffee?","options":["tea","coffee"]}"#.utf8)
    let plain = try JSONDecoder().decode(QuestionCardData.self, from: wire)
    #expect(plain.allowOther == nil)
    #expect(!plain.offersFreeText)
    // And re-encoding it leaves the key absent, rather than writing a false the runtime
    // would then have to read back as "offers free text: no".
    let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
    #expect(reencoded?["allowOther"] == nil)
}

@Test func progressCardsRoundTripAndKnowHowFarAlongTheyAre() throws {
    let card = ProgressCardData(
        cardId: "job-1",
        title: "Booking the table",
        steps: [
            ProgressStep(label: "find a restaurant", state: .done),
            ProgressStep(label: "call them", state: .running),
        ],
        percent: 50
    )
    #expect(try JSONDecoder().decode(ProgressCardData.self, from: JSONEncoder().encode(card)) == card)
    #expect(card.fraction == 0.5)
    #expect(card.running)

    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any]
    #expect(json?["cardId"] as? String == "job-1")
    #expect((json?["steps"] as? [[String: Any]])?.first?["state"] as? String == "done")

    // No percentage reported: the steps that are finished are the progress there is.
    let counted = ProgressCardData(
        cardId: "job-2",
        title: "Tidying",
        steps: [
            ProgressStep(label: "a", state: .done),
            ProgressStep(label: "b", state: .done),
            ProgressStep(label: "c", state: .pending),
        ]
    )
    #expect(counted.fraction == 2.0 / 3.0)
    // And a card with no steps at all has nothing to draw a bar from.
    #expect(ProgressCardData(cardId: "job-3", title: "Thinking", steps: []).fraction == nil)

    // Every step settled, one of them badly: the job is over, and the card says so.
    let failed = ProgressCardData(
        cardId: "job-4",
        title: "Booking",
        steps: [ProgressStep(label: "call them", state: .failed)]
    )
    #expect(!failed.running)

    // A runtime newer than this app can name a state it has never heard of; that is a step
    // not started yet, not a card that refuses to decode.
    let wire = Data(#"{"cardId":"j","title":"t","steps":[{"label":"x","state":"skipped"}]}"#.utf8)
    let tolerant = try JSONDecoder().decode(ProgressCardData.self, from: wire)
    #expect(tolerant.steps.first?.state == .pending)
    #expect(tolerant.percent == nil)
}


/// The thread's model crosses the wire as the spec the runtime knows it by, and going back to
/// the default is the absence of one — which is what an encoded nil is.
@Test func aThreadCarriesTheModelItRunsOn() throws {
    let summary = ThreadSummary(
        id: "t1",
        title: "Kyoto in April",
        archived: false,
        lastActivity: 1,
        model: "claude/claude-opus-5"
    )
    let encoded = try JSONEncoder().encode(summary)
    #expect(try JSONDecoder().decode(ThreadSummary.self, from: encoded) == summary)
    let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    #expect(json?["model"] as? String == "claude/claude-opus-5")

    // The runtime writes `null` for "back to the default"; this end writes the field away
    // entirely. Both decode to nil, which is what makes the two forms one meaning.
    #expect(try JSONEncoder().encode(ThreadSetModelData(model: nil)) == Data("{}".utf8))
    let explicitNull = try JSONDecoder().decode(
        ThreadSetModelData.self,
        from: Data(#"{"model":null}"#.utf8)
    )
    #expect(explicitNull.model == nil)
}

/// A menu row names the provider as well as the model, unless that would say it twice.
@Test func aModelOptionNamesItsProvider() {
    #expect(
        ModelOption(id: "claude/claude-opus-5", label: "claude-opus-5", providerLabel: "Claude")
            .menuLabel == "Claude · claude-opus-5"
    )
    #expect(
        ModelOption(id: "local/", label: "LM Studio", providerLabel: "LM Studio").menuLabel
            == "LM Studio"
    )
}
