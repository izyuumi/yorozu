import YorozuWire

/// The relay outage the banner shows, and whether the transport is down because the app stopped it (never an outage).
struct OutageMemory: Equatable {
    enum Link: Equatable { case running, stoppedByApp }

    private(set) var link: Link = .running
    /// The last outage (`.offline` or `.hostOffline`), kept while reconnecting until the state is `.ready` again.
    private(set) var outage: RelayConnection.State?

    /// The app is about to stop its transport (suspend, end of a background wake); an earlier outage stays.
    mutating func appStops() { link = .stoppedByApp }

    /// The app (re)starts or reconnects its transport.
    mutating func appRuns() { link = .running }

    /// `.hostOffline` is an outage; `.offline` is one unless the app stopped the transport;
    /// `.connecting`/`.handshaking` keep the last outage; anything else clears it.
    mutating func apply(_ state: RelayConnection.State) {
        switch state {
        case .hostOffline: outage = state
        case .offline: if link == .running { outage = state }
        case .connecting, .handshaking: break
        default: outage = nil
        }
    }

    /// A new pairing, unpair or demo: no outage, running.
    mutating func reset() { self = OutageMemory() }
}
