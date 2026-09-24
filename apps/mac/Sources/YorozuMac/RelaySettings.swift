import SwiftUI

/// Which relay the sidecar talks to. One environment variable (`YOROZU_RELAY_URL`) the
/// runtime already reads; the picker is a text field because a relay is just a URL.
///
/// The default is the hosted relay, a Cloudflare Worker at `relay.yumi.to`. A LAN or
/// Tailscale relay — say `ws://100.100.1.1:8787` from
/// `scripts/install-relay-launchagent.sh` — goes in the same field.
enum RelaySettings {
    static let key = "YOROZU_RELAY_URL"
    static let defaultUrl = "wss://relay.yumi.to"

    /// The configured URL, or the default when nothing has been stored yet.
    static var url: String {
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        return stored.isEmpty ? defaultUrl : stored
    }
}

struct RelayView: View {
    @AppStorage(RelaySettings.key) private var url = RelaySettings.defaultUrl

    var body: some View {
        Section {
            TextField("Relay", text: $url)
        } footer: {
            Group {
                Text("The blind relay your phone reaches this Mac through. Restart to apply.")
            }
            .leadingFooter()
        }
    }
}
