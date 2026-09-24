import SwiftUI
import YorozuShared

/// Settings keeps its own warning tint while sharing the connection-state mapping and labels used
/// by the thread list. Amber rather than the system orange: it has to be read as text on paper.
private extension ConnectionState {
    var tint: Color {
        switch self {
        case .connected: YorozuPalette.sage
        case .offline: YorozuPalette.warning
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
                    Section("Your Mac") {
                        LabeledContent("Status") {
                            // A dot and a word, so the state is never told by colour alone.
                            HStack(spacing: 7) {
                                Circle().fill(status.tint).frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                                Text(status.label)
                            }
                            .foregroundStyle(status.tint)
                        }
                        // A relay URL is something you may need to read back in full or paste
                        // elsewhere: its own line, wrapping, never truncated.
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Relay")
                            Text(relayUrl)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        if let pairedAt {
                            LabeledContent("Paired since", value: pairedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .listRowBackground(YorozuPalette.paper)
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
                        approvalsFooter
                    }
                    .listRowBackground(YorozuPalette.paper)
                }
                if !isDemo { TerminalAccessSettings(model: model) }
                Section("App") {
                    LabeledContent("Version", value: Self.version)
                    Link("Source on GitHub", destination: Self.repo)
                }
                .listRowBackground(YorozuPalette.paper)
                Section("Provider marks") {
                    Text(ProviderMarkAttribution.notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(YorozuPalette.paper)
                Section {
                    if isDemo {
                        Button("Exit demo") {
                            dismiss()
                            onExitDemo()
                        }
                    } else {
                        Button("Unpair", role: .destructive) { confirmingUnpair = true }
                    }
                } footer: {
                    if !isDemo {
                        Text("Forgets this phone’s keys and cached threads. Pair again by scanning a new code on your Mac.")
                    }
                }
                .listRowBackground(YorozuPalette.paper)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(YorozuPalette.canvas)
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
        .yorozuTint()
    }

    /// Three states that must never be confused: the bypass is off, the phone has asked and the
    /// Mac has not yet answered, or the Mac has granted it. Only the last one is a bypass.
    @ViewBuilder private var approvalsFooter: some View {
        if model.yoloMode {
            Label {
                Text("Every tool request runs without asking, including purchases, messages, commands, and deletes.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if let until = model.yoloUntil {
                Text("Until \(Date(timeIntervalSince1970: Double(until) / 1000).formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
        } else {
            if model.yoloPending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Waiting for the Mac to allow it")
                }
                .accessibilityElement(children: .combine)
            }
            Text("Uses each agent’s approval settings. Turning this on requests permission from your host Mac.")
        }
    }
}
