import Foundation
import YorozuWire

/// The pure parts of the direct path's UI (#532): when the Local Network explainer shows, and when the route last switched.
enum ConnectionRoute {
    /// Once, after the first session that opens with a pairing; devices paired before the explainer see it after their next connect.
    static func explainerDue(paired: Bool, isDemo: Bool, explained: Bool, state: RelayConnection.State) -> Bool {
        paired && !isDemo && !explained && state == .ready
    }

    /// At scan time (#532 step 5): while pairing, once the relay couldn't be reached, if the code's hints name LAN
    /// addresses and Local Network was neither explained nor denied.
    static func pairingExplainerDue(pairing: Bool, relayUnreachable: Bool, lanHints: Bool, explained: Bool, denied: Bool) -> Bool {
        pairing && relayUnreachable && lanHints && !explained && !denied
    }

    /// The time the route switched: `now` when it differs from the previous one, else the time kept so far.
    static func switchedAt(previous: DirectRoute?, next: DirectRoute, since: Date?, now: Date) -> Date {
        previous == next ? since ?? now : now
    }
}

extension DirectRoute {
    /// Settings › Host › Connection.
    var label: String {
        switch self {
        case .wifi: String(localized: "Direct (Wi-Fi)")
        case .localNetwork: String(localized: "Direct (local network)")
        case .tailscale: String(localized: "Direct (Tailscale)")
        case .thisMac: String(localized: "Direct (this Mac)")
        case .relay: String(localized: "Relay")
        }
    }
}
