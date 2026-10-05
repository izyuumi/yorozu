import SwiftUI

/// Shared safe account controls. Initial authorization is offered only on the host Mac.
public struct AccountSettingsView: View {
    public let model: ChatModel
    private let canSignInOnThisMac: Bool
    public init(model: ChatModel, canSignInOnThisMac: Bool = false) {
        self.model = model; self.canSignInOnThisMac = canSignInOnThisMac
    }
    private var localSignIn: Bool {
        #if os(macOS)
        canSignInOnThisMac
        #else
        false
        #endif
    }
    private var canAct: Bool { model.canDeliver && model.supportsSiwcAccounts && !model.siwcAccountWaiting }
    private var signInAvailable: Bool {
        canAct && localSignIn && model.siwcAccounts?.nativeIntegration == .wiredUnverified && model.pendingSiwcSignInAttemptId == nil
    }

    public var body: some View {
        Form {
            Section {
                Button(localSignIn ? "Continue with ChatGPT" : "Sign in on your Mac") {
                    _ = model.controlSiwcAccounts(SiwcAccountControlData(method: .signIn), localSignIn: localSignIn)
                }
                .disabled(!signInAvailable)
                .accessibilityIdentifier("siwc-continue")
                if !model.supportsSiwcAccounts || model.siwcAccounts?.nativeIntegration == .unwired {
                    Text("ChatGPT sign-in is unavailable on this Mac.").foregroundStyle(.secondary)
                } else if !localSignIn {
                    Text("Add accounts on your host Mac. Saved accounts can be managed here.").foregroundStyle(.secondary)
                }
            } header: { Text("ChatGPT") }

            if let attempt = model.pendingSiwcSignInAttemptId {
                Section {
                    Text("Finish signing in on your Mac.").foregroundStyle(.secondary)
                    Button("Cancel sign-in", role: .cancel) {
                        _ = model.controlSiwcAccounts(SiwcAccountControlData(method: .cancel, attemptId: attempt))
                    }
                    .disabled(!model.canDeliver || !model.supportsSiwcAccounts)
                    .accessibilityIdentifier("siwc-cancel")
                }
            }

            if let accounts = model.siwcAccounts?.accounts, !accounts.isEmpty {
                Section("Saved accounts") {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        AccountSettingsRow(model: model, account: account, ordinal: index + 1,
                            canAct: canAct, canSignIn: signInAvailable, localSignIn: localSignIn)
                    }
                }
            }

            Section {
                Button("Check account status") { model.requestSiwcAccountStatus() }
                    .disabled(!model.canDeliver || !model.supportsSiwcAccounts)
                    .accessibilityIdentifier("siwc-status")
                AccountSettingsFeedback(model: model)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #else
        .paperList()
        #endif
        .navigationTitle(SecretaryUI.localized("ChatGPT accounts"))
        .onAppear { model.requestSiwcAccountStatus() }
        .yorozuTint()
    }
}

private struct AccountSettingsRow: View {
    let model: ChatModel
    let account: SiwcAccountSummary
    let ordinal: Int
    let canAct: Bool
    let canSignIn: Bool
    let localSignIn: Bool
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Account \(ordinal)")
                if account.active { Label("Selected", systemImage: "checkmark").foregroundStyle(.secondary) }
            }
            Text(status).font(.subheadline).foregroundStyle(.secondary)
            if account.phase == .ready && account.planUse && !account.active {
                Button("Use this account") {
                    _ = model.controlSiwcAccounts(SiwcAccountControlData(method: .select, bindingId: account.id))
                }.disabled(!canAct)
            }
            if account.phase == .unknown {
                Button("Verify pending sign-in") {
                    _ = model.controlSiwcAccounts(SiwcAccountControlData(method: .verifyPending, bindingId: account.id))
                }.disabled(!canAct)
            }
            if account.phase == .signedOut {
                Button("Sign in again") {
                    _ = model.controlSiwcAccounts(SiwcAccountControlData(method: .signIn,
                        bindingId: account.id, returning: true), localSignIn: localSignIn)
                }.disabled(!canSignIn)
                if account.remoteRevocation == .unconfirmed {
                    Text("Signed out on your Mac. Remote revocation is unconfirmed.").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Button("Sign out", role: .destructive) {
                    _ = model.controlSiwcAccounts(SiwcAccountControlData(method: .signOut, bindingId: account.id))
                }.disabled(!canAct)
            }
        }
        .accessibilityElement(children: .contain)
    }
    private var status: String {
        switch account.phase {
        case .ready: account.planUse ? SecretaryUI.localized("ChatGPT plan available") : SecretaryUI.localized("ChatGPT plan unavailable")
        case .signedOut: SecretaryUI.localized("Signed out")
        case .unknown: SecretaryUI.localized("Account status is unconfirmed")
        }
    }
}

private struct AccountSettingsFeedback: View {
    let model: ChatModel
    var body: some View {
        if model.siwcAccountWaiting {
            Label("Waiting for your Mac…", systemImage: "clock").foregroundStyle(.secondary)
        } else if let result = model.siwcAccountResult {
            switch result.status {
            case .pending:
                if result.attemptId == nil { Text("Your Mac is processing this request.").foregroundStyle(.secondary) }
            case .completed: Label("Updated", systemImage: "checkmark").foregroundStyle(.secondary)
            case .rejected: Text(refusal(result.reason)).foregroundStyle(.secondary)
            case .unknown: Text("The outcome is unconfirmed. Check account status before trying again.").foregroundStyle(.secondary)
            }
        }
    }
    private func refusal(_ reason: SiwcAccountControlResult.Reason?) -> String {
        switch reason {
        case .unsupported: SecretaryUI.localized("ChatGPT sign-in is unavailable on this Mac.")
        case .localSignInRequired: SecretaryUI.localized("Sign in on your host Mac.")
        case .permission: SecretaryUI.localized("Sign-in was not authorized.")
        case .conflict, .busy: SecretaryUI.localized("Another account change is in progress. Check account status.")
        default: SecretaryUI.localized("Your Mac could not complete this account change.")
        }
    }
}
