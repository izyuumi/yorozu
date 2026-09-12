import SwiftUI
import YorozuShared

/// What the phone can say about its link to the Mac, which is two separate facts rolled into the
/// one line a person actually wants: is this phone on the relay at all, and is the Mac on it too.
///
/// Pure, so a test can check the mapping without a socket.
enum MacStatus: String {
    case connected = "Connected"
    case offline = "Mac offline"
    case reconnecting = "Reconnecting"

    init(state: TransportState, ownerOnline: Bool) {
        switch state {
        // Joined or paired both mean the relay has us; the Mac's own presence is the other half.
        case .joined, .paired: self = ownerOnline ? .connected : .offline
        case .connecting, .closed: self = .reconnecting
        }
    }

    var tint: Color {
        switch self {
        case .connected: .green
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
    let status: MacStatus
    let relayUrl: String
    let pairedAt: Date?
    let onUnpair: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false

    /// The repository the app is built from, linked rather than described.
    private static let repo = URL(string: "https://github.com/izyuumi/yorozu")!

    /// Read from the bundle rather than hardcoded: `scripts/build-ios.sh` passes the version and
    /// the build number on the xcodebuild command line, so the bundle is the only thing that knows.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Mac") {
                    LabeledContent("Status") {
                        Text(status.rawValue).foregroundStyle(status.tint)
                    }
                    LabeledContent("Relay", value: relayUrl)
                    if let pairedAt {
                        LabeledContent("Paired since", value: pairedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section("App") {
                    LabeledContent("Version", value: Self.version)
                    Link("Source on GitHub", destination: Self.repo)
                }
                Section {
                    Button("Unpair", role: .destructive) { confirmingUnpair = true }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
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
