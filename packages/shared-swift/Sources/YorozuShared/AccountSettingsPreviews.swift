import SwiftUI

private actor AccountSettingsPreviewTransport: ChatTransport {
    let status: SiwcAccountStatusData
    init(status: SiwcAccountStatusData) { self.status = status }
    func connect() -> AsyncStream<TransportUpdate> {
        AsyncStream { continuation in
            continuation.yield(.compatibility(.compatible(version: 1, capabilities: ["siwc-accounts-v1"])))
            continuation.yield(.state(.paired))
            continuation.yield(.ownerOnline(true))
            continuation.yield(.event(YorozuEvent(id: "preview-account-status", threadId: "", ts: 1,
                agentId: "main", payload: .siwcAccountStatus(status))))
        }
    }
    func send(_ event: YorozuEvent) {}
    func close() {}
}

private struct AccountSettingsPreview: View {
    @State private var model: ChatModel
    let local: Bool
    init(status: SiwcAccountStatusData, local: Bool) {
        _model = State(initialValue: ChatModel(transport: AccountSettingsPreviewTransport(status: status)))
        self.local = local
    }
    var body: some View {
        NavigationStack { AccountSettingsView(model: model, canSignInOnThisMac: local) }
            .task { model.start() }
    }
}

#Preview("ChatGPT sign-in on Mac") {
    AccountSettingsPreview(status: SiwcAccountStatusData(nativeIntegration: .wiredUnverified,
        available: false, state: .unsupported), local: true)
}

#Preview("Saved ChatGPT accounts on paired device") {
    AccountSettingsPreview(status: SiwcAccountStatusData(nativeIntegration: .wiredUnverified, available: true,
        state: .available, revision: 2, activeAccountBindingId: "preview-a", accounts: [
            SiwcAccountSummary(accountBindingId: "preview-a", phase: .ready, planUse: true, active: true),
            SiwcAccountSummary(accountBindingId: "preview-b", phase: .unknown, planUse: false, active: false),
        ]), local: false)
}
