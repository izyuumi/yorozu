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
        case .connected: SecretaryUI.localized("Connected")
        case .connecting: SecretaryUI.localized("Connecting…")
        case .hostOffline: SecretaryUI.localized("Waiting for Mac")
        case .offline: SecretaryUI.localized("Offline")
        case .failed: SecretaryUI.localized("Couldn’t connect")
        }
    }
}

/// Only fixed status fields. Never copy transport errors, URLs, host IDs, messages or keys:
/// those may contain user content or credentials.
public enum ConnectionDiagnostics {
    @MainActor public static func snapshot(for model: ChatModel) -> String {
        let transport: String = switch model.state {
        case .paired: SecretaryUI.localized("paired")
        case .joined: SecretaryUI.localized("joined")
        case .connecting: SecretaryUI.localized("connecting")
        case .closed: SecretaryUI.localized("closed")
        }
        let compatibility: String = switch model.compatibility {
        case .legacy: SecretaryUI.localized("legacy")
        case .compatible(let version, _): SecretaryUI.localized("protocol \(version)")
        case .updateRequired: SecretaryUI.localized("update required")
        }
        let presence = model.ownerOnline ? SecretaryUI.localized("online") : SecretaryUI.localized("unavailable")
        let recentFailure = model.failure == nil ? SecretaryUI.localized("no") : SecretaryUI.localized("yes")
        return SecretaryUI.localized("""
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
