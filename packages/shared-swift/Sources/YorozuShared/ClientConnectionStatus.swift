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

    /// What a status line says of `model`: the live status, except that a link which was up
    /// keeps saying Connected through an interruption shorter than
    /// ``ConnectionPresentation/grace`` — the failure every dropped socket reports included.
    /// Before the first connection there is nothing to keep, so it is the live status.
    @MainActor
    public init(_ model: ChatModel, failure: String?) {
        self = model.link.state == .connected ? .connected
            : ClientConnectionStatus(state: model.state, ownerOnline: model.ownerOnline, failure: failure)
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
