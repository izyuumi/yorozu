import SwiftUI

@main
struct YorozuApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            RootView(model: delegate.model)
        }
    }
}

/// The pairing screen until the relay has accepted this phone, then the chat.
struct RootView: View {
    let model: PhoneModel
    /// Settings' Repair: the pairing screen again, over a chat that keeps running until a new code is confirmed.
    @State private var repairing = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.linked && !repairing {
                ChatScreen(model: model) { repairing = true }
            } else {
                PairingFlowView(
                    onPair: { model.pair(with: $0) },
                    onCancel: repairing ? { repairing = false } : nil,
                    externalError: model.failure,
                    connecting: model.hasPairing && !model.linked && model.failure == nil
                )
            }
        }
        // A tapped `yorozu://pair?…` or the QR's `https://yorozu.yumi.to/pair#…` (the system Camera, via the
        // associated domain) takes the same road as a scan: the confirmation below. `QrPayload.decode` refuses anything else.
        .onOpenURL { _ = model.pair(with: $0.absoluteString) }
        .alert(
            model.pendingPairing?.repair == true ? String(localized: "Already connected") : String(localized: "Add host?"),
            isPresented: Binding(get: { model.pendingPairing != nil }, set: { if !$0 { model.pendingPairing = nil } }),
            presenting: model.pendingPairing
        ) { pending in
            Button(pending.repair ? String(localized: "Repair connection") : String(localized: "Add host")) {
                Task { await model.confirm(pending) }
                repairing = false
            }
            Button("Cancel", role: .cancel) { model.pendingPairing = nil }
        } message: { pending in
            Text(pending.repair
                ? String(localized: "This host is already paired. Repair replaces only its connection.\n\nRelay: \(pending.relayHost)\nHost key: \(pending.fingerprint)")
                : String(localized: "Add this host to Yorozu?\n\nRelay: \(pending.relayHost)\nHost key: \(pending.fingerprint)"))
        }
        // Once per pairing, after the first handshake with a newly added host.
        .sheet(isPresented: Binding(get: { model.onboardingDue && !repairing }, set: { if !$0 { model.onboardingShown() } })) {
            OnboardingView { model.onboardingShown() }
        }
        // iOS suspends the app and its socket with it. Hang up on the way out, so the relay does
        // not keep a frozen socket, and dial on the way back in rather than waiting out a backoff
        // that ran down while nothing was executing.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .background: model.enterBackground()
            case .active: model.resume()
            default: break
            }
        }
    }
}
