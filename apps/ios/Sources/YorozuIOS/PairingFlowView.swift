import SwiftUI
import YorozuShared

/// The splash an unpaired phone opens on: the icon, the name, what the app is for, one button.
/// The icon is a flat 1024 render of AppIcon.icon as its own image set — an app icon is not
/// an image asset, so `Image("AppIcon")` is not something to rely on. scripts/icon-render.sh
/// regenerates it from the same artwork.
struct PairingFlowView: View {
    let onPair: (String) -> String?
    let onDemo: () -> Void
    var externalError: String?
    var connecting = false
    var addingHost = false

    private enum Destination: String, Identifiable {
        case scanner, manual
        var id: String { rawValue }
    }
    @State private var destination: Destination?
    @State private var error: String?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    Spacer()
                    Image("AppIconImage")
                        .resizable()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Yorozu").font(.largeTitle.weight(.semibold))
                    Text(addingHost ? "Connect another Mac." : "Your Mac's agent, in your pocket.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    guide.padding(.top, 8)
                    Spacer()
                    Button { destination = .scanner } label: {
                        Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(connecting)
                    Button("Enter code manually") { destination = .manual }
                        .frame(minHeight: 44)
                        .disabled(connecting)
                    if !addingHost {
                        Button("Try the demo", action: onDemo)
                            .buttonStyle(.bordered)
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                    }
                    if connecting { ProgressView("Connecting…") }
                    if let error = error ?? externalError {
                        // Red carries the icon, not the words: red footnote text is under 4.5:1.
                        Label { Text(error) } icon: {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        }
                        .font(.footnote)
                        .multilineTextAlignment(.leading)
                    }
                }
                // Phone-width content, centred: an iPad or a landscape phone is wider than a
                // column of buttons should ever be.
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 40))
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .background(YorozuPalette.canvas.ignoresSafeArea())
        .yorozuTint()
        .sheet(item: $destination) { shown in
            switch shown {
            case .scanner:
                ScannerView(onScan: { text in
                    let failure = submit(text)
                    if failure == nil { destination = nil }
                    return failure
                }, onManualEntry: { destination = .manual })
                .yorozuTint()
            case .manual:
                PairView(onPair: submit)
                    .yorozuTint()
            }
        }
    }

    /// The three things to do on the Mac, and where to get the Mac app if there is none yet.
    private var guide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pair with your Mac").font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                guideStep(1, "Open Yorozu on your Mac")
                guideStep(2, "Settings › Devices › Pair Another Device")
                guideStep(3, "Scan the code, or paste it here")
            }
            Link("Don’t have the Mac app yet? Get it", destination: URL(string: "https://yorozu.yumi.to/mac")!)
                .font(.subheadline)
                .frame(minHeight: 44, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .yorozuPaperCard()
    }

    private func guideStep(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit()
            Text(text)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func submit(_ text: String) -> String? {
        let failure = onPair(text)
        error = failure
        return failure
    }
}

/// Manual fallback when camera pairing is unavailable.
struct PairView: View {
    /// Called with an untrusted pairing string; returns an error message when it is not one.
    let onPair: (String) -> String?

    @State private var code = ""
    @State private var error: String?
    @State private var submitted = false
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
                    Section {
                        Label { Text(error) } icon: {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Pair with your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        guard !submitted else { return }
                        submitted = true
                        error = onPair(code)
                        if error == nil {
                            // Progress and network failures belong to the presenting flow.
                            dismiss()
                        } else {
                            submitted = false
                        }
                    }
                    .disabled(submitted || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
