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

/// The phone's whole Settings screen: what it is connected to, when it paired, which build this
/// is, and the two things it can do about any of that — unpair, or go read the source.
///
/// Everything here is read-only but the Unpair button, so it holds no state of its own beyond the
/// confirmation alert's flag.
struct SettingsView: View {
    let status: ConnectionState
    let relayUrl: String
    let pairedAt: Date?
    let onUnpair: () -> Void
    /// The chat model, for the one screen behind here that talks to the Mac: the rules list.
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
                Section("Mac") {
                    LabeledContent("Status") {
                        Text(status.label).foregroundStyle(status.tint)
                    }
                    LabeledContent("Relay", value: relayUrl)
                    if let pairedAt {
                        LabeledContent("Paired since", value: pairedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section {
                    Toggle(
                        "YOLO mode",
                        isOn: Binding(
                            get: { model.yoloMode },
                            set: { model.setYoloMode($0) }
                        )
                    )
                    NavigationLink {
                        RulesListView(model: model)
                    } label: {
                        LabeledContent("Rules") {
                            Text(model.rules.isEmpty ? String(localized: "None") : "\(model.rules.count)")
                        }
                    }
                } header: {
                    Text("Approvals")
                } footer: {
                    if model.yoloMode {
                        Label {
                            Text("Every tool request runs without asking, including purchases, messages, commands, and deletes.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
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
                    Button("Unpair", role: .destructive) { confirmingUnpair = true }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .onAppear { model.requestApprovalSettings() }
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


/// The rules the Mac is acting on, as the phone shows them: what each covers and what it has
/// been doing, and the one thing the phone can do about one — revoke it. Editing a rule is the
/// Mac's job, because widening a scope is the decision that wants a keyboard and a wide screen.
///
/// Read over the wire rather than from a file, unlike the Mac's own Rules tab: rules live on
/// the Mac, and `rule_list` is how the phone learns about them.
struct RulesListView: View {
    let model: ChatModel
    @State private var confirmingDelete: ApprovalRule?

    var body: some View {
        List {
            if model.rules.isEmpty {
                ContentUnavailableView(
                    "No rules yet",
                    systemImage: "checkmark.seal",
                    description: Text("Choose “Always allow” on an approval card to make one.")
                )
            } else {
                Section {
                    ForEach(model.rules) { rule in
                        RuleRowView(rule: rule)
                            .swipeActions(edge: .trailing) {
                                Button("Revoke", role: .destructive) { confirmingDelete = rule }
                            }
                    }
                } footer: {
                    Text("Rules apply to every agent and last until you revoke them. Edit one on the Mac.")
                }
            }
        }
        .navigationTitle("Rules")
        .navigationBarTitleDisplayMode(.inline)
        // The Mac pushes a fresh list after any change, so this is only about opening the screen.
        .onAppear { model.requestRules() }
        .refreshable { model.requestRules() }
        .confirmationDialog(
            "Revoke this rule?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            presenting: confirmingDelete
        ) { rule in
            Button("Revoke", role: .destructive) {
                model.deleteRule(rule.id)
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: { rule in
            Text("Yorozu will ask again before it does \(rule.summary).")
        }
    }
}
