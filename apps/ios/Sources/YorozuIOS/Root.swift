import SwiftUI
import YorozuWire

/// The v3 app (#425): the pairing screen until the plugin has answered this device once, then the conversations.
struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.paired {
                HomeView(model: model)
                    .id(model.isDemo)
            } else {
                PairingView(model: model)
            }
        }
        // A tapped `yorozu://pair?…`, or the QR's web link opened by the system Camera, takes the same road as a scan;
        // so does a Mac's code (`/add`) on a paired device.
        .onOpenURL { url in
            if let failure = model.submit(url.absoluteString) { model.pairingError = failure }
        }
        .deviceAddingAlerts(model)
        .alert(String(localized: "Pair with this host?"),
            isPresented: Binding(get: { model.pendingPairing != nil }, set: { if !$0 { model.pendingPairing = nil } }),
            presenting: model.pendingPairing) { payload in
            Button(String(localized: "Pair")) { model.confirm(payload) }
            Button(String(localized: "Cancel"), role: .cancel) { model.pendingPairing = nil }
        } message: { payload in
            Text(String(localized: "Check that this host key matches the one `openclaw yorozu pair` printed, or the one your other device shows.\n\nHost key: \(payload.fingerprint)\nRelay: \(URL(string: payload.relayUrl)?.host() ?? payload.relayUrl)"))
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            // iOS suspends a background app and its socket with it; a Mac app keeps running and keeps its link.
            #if os(iOS)
            case .background:
                // A message just sent goes out before the socket closes: iOS lends a background app about 30 s.
                let task = UIApplication.shared.beginBackgroundTask(withName: "Sending messages")
                Task {
                    _ = await model.waitUntilSent(limit: .seconds(25))
                    model.suspend()
                    UIApplication.shared.endBackgroundTask(task)
                }
            #endif
            case .active: model.resume()
            default: break
            }
        }
        // Only an active app has a conversation in the foreground (#431).
        .onChange(of: scenePhase, initial: true) { _, phase in model.setActive(phase == .active) }
        .yorozuTint()
        .yorozuAppearance()
    }
}

/// Scan (iPhone, iPad) or paste (every platform) the code `openclaw yorozu pair` prints, then compare the host key.
struct PairingView: View {
    let model: AppModel

    @State private var code = ""
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
                        Button(String(localized: "Cancel"), role: .cancel) { model.unpair() }
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
                        TextField(String(localized: "Pairing link"), text: $code, axis: .vertical)
                            .font(.system(.footnote, design: .monospaced))
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .lineLimit(2...6)
                            .accessibilityIdentifier("pairing.code")
                        // The system's paste control: no paste prompt, and the link is checked before anything else.
                        PasteButton(payloadType: String.self) { strings in
                            guard let text = strings.first else { return }
                            Task { @MainActor in
                                code = text
                                model.pairingError = model.submit(text)
                            }
                        }
                        .accessibilityIdentifier("pairing.paste")
                        Button(String(localized: "Pair")) { model.pairingError = model.submit(code) }
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    /// A Mac has no camera: it shows a code for a paired iPhone or iPad to scan (owner, 2026-10-27).
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
