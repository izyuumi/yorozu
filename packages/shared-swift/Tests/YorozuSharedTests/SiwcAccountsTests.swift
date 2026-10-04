import Foundation
import Testing
@testable import YorozuShared

private func accountStatus(_ result: SiwcAccountControlResult? = nil) -> SiwcAccountStatusData {
    SiwcAccountStatusData(nativeIntegration: .wiredUnverified, available: true, state: .available, revision: 2,
        activeAccountBindingId: "binding-a", accounts: [SiwcAccountSummary(accountBindingId: "binding-a", phase: .ready, planUse: true, active: true)],
        lastControlResult: result)
}

@Test func siwcAccountWireRoundTripsSafeControlsAndProjection() throws {
    let controls = [SiwcAccountControlData(method: .signIn), SiwcAccountControlData(method: .signIn, bindingId: "binding-a", returning: true),
        SiwcAccountControlData(method: .cancel, attemptId: "attempt-a"), SiwcAccountControlData(method: .status),
        SiwcAccountControlData(method: .select, bindingId: "binding-a"), SiwcAccountControlData(method: .signOut, bindingId: "binding-a"),
        SiwcAccountControlData(method: .verifyPending, bindingId: "binding-a")]
    for control in controls {
        #expect(control.isValid)
        let event = YorozuEvent(id: "operation-a", threadId: "", ts: 1, agentId: "device", payload: .siwcAccountControl(control))
        #expect(try JSONDecoder().decode(YorozuEvent.self, from: JSONEncoder().encode(event)) == event)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(control)) as? [String: Any])
        #expect(json["operationId"] == nil)
    }
    let projection = accountStatus(SiwcAccountControlResult(operationId: "operation-a", status: .completed))
    let listing = ThreadListData(threads: [], siwcAccounts: projection)
    #expect(try JSONDecoder().decode(ThreadListData.self, from: JSONEncoder().encode(listing)) == listing)
    #expect(try JSONDecoder().decode(ThreadListData.self, from: Data(#"{"threads":[]}"#.utf8)).siwcAccounts == nil)
}

@Test func siwcAccountStrictDecodingNeverRetainsForbiddenDataAsUnknown() throws {
    let invalidControls = [
        #"{"version":1,"method":"sign-in","returning":true}"#,
        #"{"version":1,"method":"status","operationId":"duplicate"}"#,
        #"{"version":1,"method":"cancel","attemptId":null}"#,
        #"{"version":1,"method":"sign-in","authorizationUrl":"synthetic-forbidden"}"#,
    ]
    for json in invalidControls {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SiwcAccountControlData.self, from: Data(json.utf8)) }
        let event = "{\"id\":\"op\",\"threadId\":\"\",\"ts\":1,\"agentId\":\"device\",\"kind\":\"siwc_account_control\",\"data\":\(json)}"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(YorozuEvent.self, from: Data(event.utf8)) }
    }
    let safe = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(accountStatus())) as? [String: Any])
    let account = try #require((safe["accounts"] as? [[String: Any]])?.first)
    let invalid = [safe.merging(["productionReady": true]) { _, new in new },
        safe.merging(["activeAccountBindingId": "missing"]) { _, new in new },
        safe.merging(["accounts": [account, account]]) { _, new in new },
        safe.merging(["accounts": [account.merging(["phase": "signed-out"]) { _, new in new }]]) { _, new in new },
        safe.merging(["accessToken": "synthetic-forbidden"]) { _, new in new }]
    for object in invalid {
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SiwcAccountStatusData.self, from: data) }
        for kind in ["siwc_account_status", "thread_list"] {
            let payload: Any = kind == "thread_list" ? ["threads": [], "siwcAccounts": object] as [String: Any] : object
            let event = try JSONSerialization.data(withJSONObject: ["id": "op", "threadId": "", "ts": 1, "agentId": "main", "kind": kind, "data": payload])
            #expect(throws: (any Error).self) { try JSONDecoder().decode(YorozuEvent.self, from: event) }
        }
    }
}

private actor SiwcSettingsTransport: ChatTransport {
    private var updates: AsyncStream<TransportUpdate>.Continuation?
    private var held: [TransportUpdate] = []
    private(set) var sent: [YorozuEvent] = []
    func connect() -> AsyncStream<TransportUpdate> {
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        updates = continuation
        for update in held { continuation.yield(update) }
        held = []
        return stream
    }
    func send(_ event: YorozuEvent) { sent.append(event) }
    func close() { updates?.finish(); updates = nil }
    func yield(_ update: TransportUpdate) { if let updates { updates.yield(update) } else { held.append(update) } }
}
@MainActor private func siwcEventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<100 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
    return predicate()
}

@MainActor @Test func siwcAccountModelUsesExactReceiptsAndNeverOutboxOrHistory() async throws {
    let transport = SiwcSettingsTransport()
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["siwc-accounts-v1"])))
    await transport.yield(.state(.paired)); await transport.yield(.ownerOnline(true))
    let model = ChatModel(transport: transport); model.start(); defer { model.close() }
    #expect(await siwcEventually { model.canDeliver && model.supportsSiwcAccounts })
    model.applyEvent(YorozuEvent(id: "status", threadId: "", ts: 1, agentId: "main", payload: .siwcAccountStatus(accountStatus())))
    let operation = try #require(model.controlSiwcAccounts(SiwcAccountControlData(method: .signOut, bindingId: "binding-a")))
    #expect(model.siwcAccountWaiting && model.outbox.isEmpty)
    await transport.yield(.event(YorozuEvent(id: "receipt", threadId: "", ts: 2, agentId: "main", payload: .receipt(ReceiptData(eventId: operation)))))
    model.applyEvent(YorozuEvent(id: "other", threadId: "", ts: 3, agentId: "main", payload: .siwcAccountStatus(
        accountStatus(SiwcAccountControlResult(operationId: "another-operation", status: .completed)))))
    #expect(model.siwcAccountWaiting && model.siwcAccountResult == nil)
    model.applyEvent(YorozuEvent(id: "ours", threadId: "", ts: 4, agentId: "main", payload: .siwcAccountStatus(
        accountStatus(SiwcAccountControlResult(operationId: operation, status: .unknown, reason: .unknown)))))
    #expect(model.siwcAccountResult?.status == .unknown && !model.siwcAccountWaiting)
    #expect(model.events[""]?.isEmpty != false && model.outbox.isEmpty)
    await transport.yield(.state(.closed)); await transport.yield(.state(.paired))
    try? await Task.sleep(for: .milliseconds(40))
    #expect(await transport.sent.filter { $0.payload.kind == .siwcAccountControl && $0.id == operation }.count == 1)
}

@MainActor @Test func siwcAccountFirstSignInDoesNotRequireActivatedStorageAndCancelTargetsOnlyItsAttempt() async throws {
    let transport = SiwcSettingsTransport()
    await transport.yield(.compatibility(.compatible(version: 1, capabilities: ["siwc-accounts-v1"])))
    await transport.yield(.state(.paired)); await transport.yield(.ownerOnline(true))
    let model = ChatModel(transport: transport); model.start(); defer { model.close() }
    #expect(await siwcEventually { model.canDeliver && model.supportsSiwcAccounts })
    model.applyEvent(YorozuEvent(id: "inactive", threadId: "", ts: 1, agentId: "main", payload: .siwcAccountStatus(
        SiwcAccountStatusData(nativeIntegration: .wiredUnverified, available: false, state: .unsupported))))
    #expect(model.controlSiwcAccounts(SiwcAccountControlData(method: .signIn)) == nil) // Remote Mac uses the same shared model.
    #if os(macOS)
    let operation = try #require(model.controlSiwcAccounts(SiwcAccountControlData(method: .signIn), localSignIn: true))
    model.applyEvent(YorozuEvent(id: "pending", threadId: "", ts: 2, agentId: "main", payload: .siwcAccountStatus(
        SiwcAccountStatusData(nativeIntegration: .wiredUnverified, available: false, state: .unsupported,
            lastControlResult: SiwcAccountControlResult(operationId: operation, status: .pending, attemptId: "attempt-a")))))
    #expect(model.controlSiwcAccounts(SiwcAccountControlData(method: .cancel, attemptId: "attempt-b")) == nil)
    let cancel = try #require(model.controlSiwcAccounts(SiwcAccountControlData(method: .cancel, attemptId: "attempt-a")))
    model.applyEvent(YorozuEvent(id: "cancelled", threadId: "", ts: 3, agentId: "main", payload: .siwcAccountStatus(
        SiwcAccountStatusData(nativeIntegration: .wiredUnverified, available: false, state: .unsupported,
            lastControlResult: SiwcAccountControlResult(operationId: cancel, status: .completed)))))
    #expect(model.pendingSiwcSignInAttemptId == nil)
    model.applyEvent(YorozuEvent(id: "late-pending", threadId: "", ts: 4, agentId: "main", payload: .siwcAccountStatus(
        SiwcAccountStatusData(nativeIntegration: .wiredUnverified, available: false, state: .unsupported,
            lastControlResult: SiwcAccountControlResult(operationId: operation, status: .pending, attemptId: "attempt-a")))))
    #expect(model.pendingSiwcSignInAttemptId == nil) // A cancelled attempt cannot resurrect through a late snapshot.
    #else
    #expect(model.controlSiwcAccounts(SiwcAccountControlData(method: .signIn), localSignIn: true) == nil)
    #endif
}
