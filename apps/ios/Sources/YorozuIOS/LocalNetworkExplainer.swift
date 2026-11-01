import SwiftUI

/// Asks once, after pairing, before the system's Local Network prompt (#532): direct LAN paths and Bonjour wait for it.
struct LocalNetworkExplainer: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: LayoutMetrics.section) {
                Image(systemName: "wifi")
                    .textStyle(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(spacing: LayoutMetrics.stack) {
                    Text("Connect directly on Wi-Fi?")
                        .textStyle(.title2, weight: .bold)
                        .accessibilityAddTraits(.isHeader)
                    Text("When this device and your host are on the same network, Yorozu can talk to the host directly. It’s faster, and keeps working when the relay is slow. Messages stay end-to-end encrypted either way.")
                    Text(Self.prompt)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                VStack(spacing: LayoutMetrics.stack) {
                    Button {
                        dismiss()
                        Task { await model.allowLocalNetwork() }
                    } label: {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("localNetwork.continue")
                    Button(String(localized: "Not Now")) {
                        model.explainLocalNetwork()
                        dismiss()
                    }
                    .accessibilityIdentifier("localNetwork.notNow")
                }
            }
            .padding(LayoutMetrics.gutter)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: LayoutMetrics.settingsWidth)
        #endif
    }

    #if os(iOS)
    private static var prompt: String { String(localized: "iOS asks for Local Network access next.") }
    #else
    private static var prompt: String { String(localized: "macOS may ask for Local Network access next.") }
    #endif
}
