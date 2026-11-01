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
        // #532: once, after the first session with a pairing or, while pairing, when the relay can't be reached and the code
        // names LAN addresses; it stays up if the session drops, and a swipe away counts as Not Now.
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
            Text(String(localized: "Check that this host key matches the one `openclaw yorozu pair` printed, or the one your other device shows.\n\nHost key: \(payload.fingerprint)\nRelay: \(URL(string: payload.relayUrl)?.host() ?? payload.relayUrl)"))
        }
        .onChange(of: scenePhase) { previous, phase in
            switch phase {
            #if os(iOS)
            case .background:
                let task = UIApplication.shared.beginBackgroundTask(withName: "Sending messages")
                Task {
                    _ = await model.waitUntilSent(limit: .seconds(25))
                    await YorozuActivities.shared?.waitUntilReported(limit: .seconds(5))
                    model.suspend()
                    UIApplication.shared.endBackgroundTask(task)
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
                // Still in the foreground: the last moment a Live Activity can start.
                if previous == .active { YorozuActivities.shared?.leaving() }
                #endif
                // On the way back to the foreground: race before the scene is active.
                if previous == .background { model.prewarm() }
            default: break
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in model.setActive(phase == .active) }
        .yorozuTint()
        .yorozuAppearance()
    }
}

struct PairingView: View {
    @Bindable var model: AppModel

    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                if !model.connecting { deviceCode }
                #endif
                Section {
                    Text("Run `openclaw yorozu pair` on the computer that runs your OpenClaw Gateway. It prints a QR code and a pairing link, valid for 10 minutes.")
                } header: {
                    Text("Pair with your host")
                }
                if model.connecting {
                    Section {
                        LabeledContent(String(localized: "Host key"), value: model.fingerprint ?? "")
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
                    #if os(iOS)
                    Section {
                        Button(String(localized: "Scan QR Code"), systemImage: "qrcode.viewfinder") { scanning = true }
                    }
                    #endif
                    Section {
                        TextField(String(localized: "Pairing link"), text: $model.pairingEntry.text, axis: .vertical)
                            .textStyle(.footnote, monospaced: true)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .lineLimit(2...6)
                            .accessibilityIdentifier("pairing.code")
                        PasteButton(payloadType: String.self) { strings in
                            guard let text = strings.first else { return }
                            Task { @MainActor in
                                model.pairingEntry.text = text
                                model.pairingError = model.submit(text)
                            }
                        }
                        .accessibilityIdentifier("pairing.paste")
                        Button(String(localized: "Pair")) { model.pairingError = model.submit(model.pairingEntry.text) }
                            .disabled(model.pairingEntry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("pairing.submit")
                    } footer: {
                        Text("Paste the `yorozu://pair…` link, or the https link the QR code opens.")
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
        .sheet(isPresented: $scanning) {
            ScannerView(prompt: "Scan the QR code `openclaw yorozu pair` printed on your host.", onScan: { text in
                let failure = model.submit(text)
                if failure == nil { scanning = false }
                return failure
            }, onManualEntry: { scanning = false })
            .yorozuTint()
        }
        #endif
    }

    #if os(macOS)
    private var deviceCode: some View {
        Section {
            if let code = model.deviceCode {
                QRCode(text: code.link)
                    .frame(maxWidth: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Pair with your iPhone or iPad")
        } footer: {
            Text("On an iPhone or iPad that already uses Yorozu, open Settings › Add a Device › Scan a Mac’s Code, or point its Camera at this code. A new code appears every 10 minutes.")
        }
        .task { await model.showDeviceCodes() }
    }
    #endif
}
