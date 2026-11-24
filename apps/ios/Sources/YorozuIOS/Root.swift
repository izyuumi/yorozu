import SwiftUI
import YorozuWire

struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var explainingLocalNetwork = false

    var body: some View {
        Group {
            if model.paired {
                HomeView(model: model)
                    .id(model.isDemo)
            } else {
                PairingView(model: model)
            }
        }
        .onOpenURL { url in
            if let link = WidgetLink(url: url) { return model.open(link) }
            if let failure = model.submit(url.absoluteString) { model.pairingError = failure }
        }
        .deviceAddingAlerts(model)
        .onChange(of: model.showLocalNetworkExplainer, initial: true) { _, due in if due { explainingLocalNetwork = true } }
        .sheet(isPresented: $explainingLocalNetwork, onDismiss: { model.explainLocalNetwork() }) {
            LocalNetworkExplainer(model: model).yorozuTint()
        }
        .alert(String(localized: "Pair with this host?"),
            isPresented: Binding(get: { model.pendingPairing != nil }, set: { if !$0 && model.pendingPairing != nil { model.dismissPendingPairing() } }),
            presenting: model.pendingPairing) { payload in
            Button(String(localized: "Pair")) { model.confirm(payload) }
            Button(String(localized: "Cancel"), role: .cancel) { model.dismissPendingPairing() }
        } message: { payload in
            Text(String(localized: "Compare this fingerprint with the one shown by your host or the device that sent the invite.\n\nHost fingerprint: \(payload.fingerprint)\nRelay: \(URL(string: payload.relayUrl)?.host() ?? payload.relayUrl)"))
        }
        .onChange(of: scenePhase) { previous, phase in
            switch phase {
            #if os(iOS)
            case .background:
                let visit = model.enterBackground()
                let task = UIApplication.shared.beginBackgroundTask(withName: "Sending messages")
                Task {
                    defer { UIApplication.shared.endBackgroundTask(task) }
                    _ = await model.waitUntilSent(limit: .seconds(25))
                    await YorozuActivities.shared?.waitUntilReported(limit: .seconds(5))
                    model.suspend(visit: visit)
                }
            #endif
            case .active:
                model.resume()
                Task { await model.recheckLocalNetwork() }
                #if os(iOS)
                YorozuActivities.shared?.returned()
                #endif
            case .inactive:
                #if os(iOS)
                if previous == .active { YorozuActivities.shared?.leaving() }
                #endif
                if previous == .background { model.prewarm() }
            default: break
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: model.setActive(true)
            case .inactive: model.setActive(false)
            #if !os(iOS)
            case .background: model.setActive(false)
            #endif
            default: break
            }
        }
        .yorozuTint()
        .yorozuAppearance()
    }
}

struct PairingView: View {
    @Bindable var model: AppModel

    @State private var scanning = false
    @State private var findingHost = false
    @State private var showingCode = false
    @FocusState private var inviteFocused: Bool
    @State private var focusInviteAfterScan = false

    var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                if !model.connecting {
                    thisMac
                }
                #endif
                if model.connecting {
                    Section {
                        LabeledContent(String(localized: "Host Fingerprint"), value: model.fingerprint ?? "")
                            .monospacedDigit()
                        HStack {
                            ProgressView()
                            Text("Pairing…")
                        }
                        Button(String(localized: "Cancel"), role: .cancel) { model.cancelPairing() }
                    } footer: {
                        Text(model.state.label)
                    }
                } else {
                    Section {
                        #if os(iOS)
                        Button(String(localized: "Scan QR Code"), systemImage: "qrcode.viewfinder") {
                            showingCode = false
                            scanning = true
                        }
                        .accessibilityIdentifier("pairing.scan")
                        #endif
                        DisclosureGroup(isExpanded: $showingCode) {
                            if showingCode && model.pendingPairing == nil { deviceCode }
                        } label: {
                            Label("Show QR Code", systemImage: "qrcode")
                        }
                        .accessibilityIdentifier("pairing.show")
                    } header: {
                        Text("Pair with your host")
                    }
                    Section {
                        TextField(String(localized: "Invite link"), text: $model.pairingEntry.text, axis: .vertical)
                            .textStyle(.footnote, monospaced: true)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .lineLimit(2...6)
                            .focused($inviteFocused)
                            .accessibilityIdentifier("pairing.code")
                        PasteButton(payloadType: String.self) { strings in
                            guard let text = strings.first else { return }
                            Task { @MainActor in
                                model.pairingEntry.text = text
                                model.pairingError = model.submit(text)
                            }
                        }
                        .accessibilityIdentifier("pairing.paste")
                        Button(String(localized: "Continue")) { model.pairingError = model.submit(model.pairingEntry.text) }
                            .disabled(model.pairingEntry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("pairing.submit")
                    } header: {
                        Text("Paste Invite Link")
                    } footer: {
                        Text("Paste the link from your host or another paired device.")
                    }
                    Section {
                        DisclosureGroup("Need an invite?") {
                            Text("On your host, run `openclaw yorozu pair` to create a QR code and invite link.")
                        }
                    }
                }
                if let error = model.pairingError {
                    Section {
                        Label { Text(error) } icon: {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Yorozu")
        }
        #if os(iOS)
        .sheet(isPresented: $scanning, onDismiss: {
            if focusInviteAfterScan {
                focusInviteAfterScan = false
                inviteFocused = true
            }
        }) {
            ScannerView(prompt: "Scan the pairing QR code from your host or another paired device.", manualLabel: "Paste Invite Link", onScan: { text in
                let failure = model.submit(text)
                if failure == nil { scanning = false }
                return failure
            }, onManualEntry: {
                focusInviteAfterScan = true
                scanning = false
            })
            .yorozuTint()
        }
        #endif
    }

    #if os(macOS)
    private var thisMac: some View {
        Section {
            Button {
                findingHost = true
                Task {
                    model.pairingError = await model.pairWithThisMac()
                    findingHost = false
                }
            } label: {
                if findingHost {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Finding the Gateway…")
                    }
                } else {
                    Label(String(localized: "Pair with the Gateway on this Mac"), systemImage: "desktopcomputer")
                }
            }
            .disabled(findingHost)
            .accessibilityIdentifier("pairing.thisMac")
        } footer: {
            Text("If your OpenClaw Gateway runs on this Mac, Yorozu pairs with it directly, without a code.")
        }
    }
    #endif

    private var deviceCode: some View {
        VStack(spacing: LayoutMetrics.stack) {
            if let code = model.deviceCode {
                QRCode(text: code.link)
                    .accessibilityLabel(Text("Pairing QR code"))
            } else {
                ProgressView("Getting a QR code…")
            }
            Text("In Yorozu on a paired iPhone or iPad, open Settings › Devices › Add a Device and scan this code.")
                .textStyle(.footnote)
                .foregroundStyle(.secondary)
            Text("A new code appears every 10 minutes.")
                .textStyle(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .task { await model.showDeviceCodes() }
    }
}
