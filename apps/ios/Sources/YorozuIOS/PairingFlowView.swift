import SwiftUI

/// The splash an unpaired phone opens on: the icon, the name, what the app is for, one button.
/// The icon is a flat 1024 render of AppIcon.icon as its own image set — an app icon is not
/// an image asset, so `Image("AppIcon")` is not something to rely on. scripts/icon-render.sh
/// regenerates it from the same artwork.
struct PairingFlowView: View {
    let onPair: (String) -> String?
    var externalError: String?
    var connecting = false

    @State private var scanning = false
    @State private var enteringCode = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("AppIconImage")
                .resizable()
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .accessibilityHidden(true)
            Text("Yorozu").font(.largeTitle.bold())
            Text("Your Mac's agent, in your pocket.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("On your host Mac, open Yorozu, then choose Settings › Devices › Pair Another Device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer()
            Button("Scan pairing code", systemImage: "qrcode.viewfinder") { scanning = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Enter code manually") { enteringCode = true }
                .buttonStyle(.bordered)
            if connecting { ProgressView("Connecting…") }
            if let error = error ?? externalError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(32)
        .sheet(isPresented: $scanning) {
            ScannerView { text in
                let failure = onPair(text)
                error = failure
                if failure == nil { scanning = false }
                return failure
            }
        }
        .sheet(isPresented: $enteringCode) {
            PairView(onPair: onPair)
        }
    }
}

/// Manual fallback when camera pairing is unavailable.
struct PairView: View {
    /// Called with an untrusted pairing string; returns an error message when it is not one.
    let onPair: (String) -> String?

    @State private var code = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair with your Mac")
                .font(.title2.bold())
            Text("Paste the code shown by Yorozu on your host Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Paste pairing code", text: $code, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Connect") { error = onPair(code) }
                .buttonStyle(.borderedProminent)
                .disabled(code.isEmpty)

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding()
    }
}
