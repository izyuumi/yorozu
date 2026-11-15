import YorozuWire

/// The relay outage the banner shows, and whether the transport is down because the app stopped it (never an outage).
struct OutageMemory: Equatable {
    enum Link: Equatable { case running, stoppedByApp }

    private(set) var link: Link = .running
    /// The last outage (`.offline` or `.hostOffline`), kept while reconnecting until the state is `.ready` again.
    private(set) var outage: RelayConnection.State?
    /// Consumes the trailing `.offline` from the app's own stop, even if it arrives after `appRuns()`.
    private var absorbStop = false

    /// The app is about to stop its transport (suspend, end of a background wake); an earlier outage stays.
    mutating func appStops() {
        link = .stoppedByApp
        absorbStop = true
    }

    /// The app (re)starts or reconnects its transport.
    mutating func appRuns() { link = .running }

    /// `.hostOffline` is an outage only while the transport is running (a late one after the app's
    /// own stop is not); `.offline` is one unless the app stopped the transport, including a late
    /// `.offline` after `appRuns()` that still belongs to that stop; `.connecting`/`.handshaking`
    /// keep the last outage; anything else clears it and drops the absorb token.
    mutating func apply(_ state: RelayConnection.State) {
        switch state {
        case .hostOffline:
            if link == .running { outage = state }
        case .offline:
            if absorbStop { absorbStop = false }
            else if link == .running { outage = state }
        case .connecting, .handshaking: break
        default:
            outage = nil
            absorbStop = false
        }
    }

    /// A new pairing, unpair or demo: no outage, running.
    mutating func reset() { self = OutageMemory() }
}
