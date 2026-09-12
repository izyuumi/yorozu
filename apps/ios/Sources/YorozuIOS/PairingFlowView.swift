import SwiftUI

/// The splash an unpaired phone opens on: the icon, the name, what the app is for, one button.
/// The icon is a copy of the 1024 app icon as its own image set — an `.appiconset` is not an
/// image asset, so `Image("AppIcon")` is not something to rely on.
struct SplashView: View {
    let onStart: () -> Void

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
            Spacer()
            Button("Get started", action: onStart)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }
}

/// The two ways a pairing gets in: the camera, or the string pasted out of the Mac. Both end
/// up in the same `QrPayload.decode`, so neither knows what a pairing code looks like.
struct PairView: View {
    /// Called with an untrusted pairing string; returns an error message when it is not one.
    let onPair: (String) -> String?

    @State private var code = ""
    @State private var error: String?
    @State private var scanning = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair with your Mac")
                .font(.title2.bold())
            Text("Open Yorozu in your Mac's menu bar.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Scan QR", systemImage: "qrcode.viewfinder") { scanning = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Text("or").font(.footnote).foregroundStyle(.secondary)

            TextField("Paste pairing code", text: $code, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Pair") { error = onPair(code) }
                .buttonStyle(.bordered)
                .disabled(code.isEmpty)

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding()
        .sheet(isPresented: $scanning) {
            ScannerView { text in
                let failure = onPair(text)
                if failure == nil { scanning = false }
                return failure
            }
        }
    }
}
