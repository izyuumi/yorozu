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
        VStack(spacing: 12) {
            Spacer()
            Image("AppIconImage")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHidden(true)
            Text("Yorozu").font(.largeTitle.weight(.semibold))
            Text("Your Mac's agent, in your pocket.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("On your host Mac, open Yorozu, then choose Settings › Devices › Pair Another Device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
                .frame(maxWidth: 320)
            Spacer()
            Button("Scan pairing code", systemImage: "qrcode.viewfinder") { scanning = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            Button("Enter code manually") { enteringCode = true }
                .frame(minHeight: 44)
            if connecting { ProgressView("Connecting…") }
            if let error = error ?? externalError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste pairing code", text: $code, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...6)
                } footer: {
                    Text("Paste the code shown in Yorozu on your host Mac.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.circle") }
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Pair with your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { error = onPair(code) }
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
