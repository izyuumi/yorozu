import SwiftUI
import YorozuShared

/// Settings keeps its warning tint while sharing the connection-state mapping and labels used by
/// the thread list.
private extension ConnectionState {
    var tint: Color {
        switch self {
        case .connected: YorozuPalette.sage
        case .offline: .orange
        case .reconnecting: .secondary
        }
    }
}

/// Connection details, app information, and the host's shared approval setting.
struct SettingsView: View {
    let status: ConnectionState
    let relayUrl: String
    let pairedAt: Date?
    let onUnpair: () -> Void
    let isDemo: Bool
    let onExitDemo: () -> Void
    /// The chat model supplies the paired approval setting.
    let model: ChatModel

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false

    /// The repository the app is built from, linked rather than described.
    private static let repo = URL(string: "https://github.com/izyuumi/yorozu")!

    /// Read from the bundle rather than hardcoded: `scripts/build-ios.sh` passes the version and
    /// the build number on the xcodebuild command line, so the bundle is the only thing that knows.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["YorozuVersionLabel"] as? String
            ?? info?["CFBundleShortVersionString"] as? String
            ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                if !isDemo {
                    Section("Mac") {
                        LabeledContent("Status") {
                            Text(status.label).foregroundStyle(status.tint)
                        }
                        LabeledContent("Relay", value: relayUrl)
                        if let pairedAt {
                            LabeledContent("Paired since", value: pairedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                if !isDemo {
                    Section {
                        Toggle(
                            "Skip approvals for all agents",
                            isOn: Binding(
                                get: { model.yoloMode },
                                set: { model.setYoloMode($0) }
                            )
                        )
                    } header: {
                        Text("Approvals")
                    } footer: {
                        Text("Applies to all agents and conversations on the host Mac and its paired devices. Tool requests can run without asking, including purchases, messages, commands, and deletes.")
                            .foregroundStyle(model.yoloMode ? Color.red : Color.secondary)
                    }
                }
                Section("App") {
                    LabeledContent("Version", value: Self.version)
                    Link("Source on GitHub", destination: Self.repo)
                }
                Section("Provider marks") {
                    Text(ProviderMarkAttribution.notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    if isDemo {
                        Button("Exit demo") {
                            dismiss()
                            onExitDemo()
                        }
                    } else {
                        Button("Unpair", role: .destructive) { confirmingUnpair = true }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .onAppear { if !isDemo { model.requestApprovalSettings() } }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Unpairing throws away the keys in the Keychain and the cached threads with them,
            // and only a fresh QR from the Mac undoes it, so it is asked about first.
            .alert("Unpair this phone?", isPresented: $confirmingUnpair) {
                Button("Unpair", role: .destructive) {
                    dismiss()
                    onUnpair()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Yorozu will forget its keys and cached threads. You will need to scan a new pairing code from your Mac.")
            }
        }
    }
}
