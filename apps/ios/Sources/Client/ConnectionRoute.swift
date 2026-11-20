import Foundation
import YorozuWire

enum ConnectionRoute {
    static func explainerDue(paired: Bool, isDemo: Bool, explained: Bool, state: RelayConnection.State) -> Bool {
        paired && !isDemo && !explained && state == .ready
    }

    static func pairingExplainerDue(pairing: Bool, relayUnreachable: Bool, lanHints: Bool, explained: Bool, denied: Bool) -> Bool {
        pairing && relayUnreachable && lanHints && !explained && !denied
    }

    static func switchedAt(previous: DirectRoute?, next: DirectRoute, since: Date?, now: Date) -> Date {
        previous == next ? since ?? now : now
    }
}

extension DirectRoute {
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
