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

/// Only fixed status fields. Never copy transport errors, URLs, host IDs, messages or keys:
/// those may contain user content or credentials.
public enum ConnectionDiagnostics {
    @MainActor public static func snapshot(for model: ChatModel) -> String {
        let transport: String = switch model.state {
        case .paired: String(localized: "paired")
        case .joined: String(localized: "joined")
        case .connecting: String(localized: "connecting")
        case .closed: String(localized: "closed")
        }
        let compatibility: String = switch model.compatibility {
        case .legacy: String(localized: "legacy")
        case .compatible(let version, _): String(localized: "protocol \(version)")
        case .updateRequired: String(localized: "update required")
        }
        let presence = model.ownerOnline ? String(localized: "online") : String(localized: "unavailable")
        let recentFailure = model.failure == nil ? String(localized: "no") : String(localized: "yes")
        return String(localized: """
        Yorozu connection diagnostics
        Connection: \(model.link.state.label)
        Transport: \(transport)
        Host presence: \(presence)
        Compatibility: \(compatibility)
        Recent failure: \(recentFailure)
        Pending sends: \(model.outbox.count)
        """)
    }
}
