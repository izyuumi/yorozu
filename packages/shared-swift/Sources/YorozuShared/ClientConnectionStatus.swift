import Foundation

/// Connection feedback for a paired client, including a host that is temporarily away.
/// A failed attempt must remain visible while the relay retries in the background.
public enum ClientConnectionStatus: Equatable, Sendable {
    case connected, connecting, hostOffline, offline, failed

    public init(state: TransportState, ownerOnline: Bool, failure: String?) {
        if failure != nil {
            self = .failed
            return
        }
        switch state {
        case .paired: self = ownerOnline ? .connected : .hostOffline
        case .joined: self = ownerOnline ? .connecting : .hostOffline
        case .connecting: self = .connecting
        case .closed: self = .offline
        }
    }

    public var label: String {
        switch self {
        case .connected: String(localized: "Connected")
        case .connecting: String(localized: "Connecting…")
        case .hostOffline: String(localized: "Host Mac offline")
        case .offline: String(localized: "Offline")
        case .failed: String(localized: "Couldn’t connect")
        }
    }
}
