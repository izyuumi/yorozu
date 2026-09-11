import SwiftUI

/// Which relay the sidecar talks to. One environment variable (`YOROZU_RELAY_URL`) the
/// runtime already reads; the picker is a text field because a relay is just a URL.
///
/// The default is Yumi's Mac mini over Tailscale, hosted by
/// `scripts/install-relay-launchagent.sh`. It is replaced by the hosted relay later, at
/// which point only this constant moves.
enum RelaySettings {
    static let key = "YOROZU_RELAY_URL"
    static let defaultUrl = "ws://100.100.1.1:8787"

    /// The configured URL, or the default when nothing has been stored yet.
    static var url: String {
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        return stored.isEmpty ? defaultUrl : stored
    }
}

struct RelayView: View {
    @AppStorage(RelaySettings.key) private var url = RelaySettings.defaultUrl

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Relay").font(.headline)
            TextField("Relay URL", text: $url)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            Text("The blind relay your phone reaches this Mac through. Restart to apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
