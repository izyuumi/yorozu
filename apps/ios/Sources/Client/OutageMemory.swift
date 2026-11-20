import YorozuWire

struct OutageMemory: Equatable {
    enum Link: Equatable { case running, stoppedByApp }

    private(set) var link: Link = .running
    private(set) var outage: RelayConnection.State?

    mutating func appStops() { link = .stoppedByApp }

    mutating func appRuns() { link = .running }

    mutating func apply(_ state: RelayConnection.State) {
        switch state {
        case .hostOffline: outage = state
        case .offline: if link == .running { outage = state }
        case .connecting, .handshaking: break
        default: outage = nil
        }
    }

    mutating func reset() { self = OutageMemory() }
}
