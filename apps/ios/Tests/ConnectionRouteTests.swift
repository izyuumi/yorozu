import Foundation
import Testing
import YorozuWire

@Suite struct ConnectionRouteTests {
    @Test func explainerShowsOnceTheFirstSessionIsReady() {
        #expect(ConnectionRoute.explainerDue(paired: true, isDemo: false, explained: false, state: .ready))
    }

    @Test func explainerWaitsForAReadySession() {
        for state in [RelayConnection.State.offline, .connecting, .handshaking, .hostOffline] {
            #expect(!ConnectionRoute.explainerDue(paired: true, isDemo: false, explained: false, state: state))
        }
    }

    @Test func explainerSkipsUnpairedDemoAndExplained() {
        #expect(!ConnectionRoute.explainerDue(paired: false, isDemo: false, explained: false, state: .ready))
        #expect(!ConnectionRoute.explainerDue(paired: true, isDemo: true, explained: false, state: .ready))
        #expect(!ConnectionRoute.explainerDue(paired: true, isDemo: false, explained: true, state: .ready))
    }

    @Test func scanTimeExplainerShowsWhilePairingWithoutTheRelay() {
        #expect(ConnectionRoute.pairingExplainerDue(pairing: true, relayUnreachable: true, lanHints: true, explained: false, denied: false))
    }

    @Test func scanTimeExplainerNeedsEveryCondition() {
        #expect(!ConnectionRoute.pairingExplainerDue(pairing: false, relayUnreachable: true, lanHints: true, explained: false, denied: false))
        #expect(!ConnectionRoute.pairingExplainerDue(pairing: true, relayUnreachable: false, lanHints: true, explained: false, denied: false))
        #expect(!ConnectionRoute.pairingExplainerDue(pairing: true, relayUnreachable: true, lanHints: false, explained: false, denied: false))
        #expect(!ConnectionRoute.pairingExplainerDue(pairing: true, relayUnreachable: true, lanHints: true, explained: true, denied: false))
        #expect(!ConnectionRoute.pairingExplainerDue(pairing: true, relayUnreachable: true, lanHints: true, explained: false, denied: true))
    }

    @Test func routeLabels() {
        #expect(DirectRoute.wifi.label == "Direct (Wi-Fi)")
        #expect(DirectRoute.tailscale.label == "Direct (Tailscale)")
        #expect(DirectRoute.thisMac.label == "Direct (this Mac)")
        #expect(DirectRoute.relay.label == "Relay")
    }

    @Test func sameRouteKeepsItsTime() {
        let since = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 2_000)
        #expect(ConnectionRoute.switchedAt(previous: .wifi, next: .wifi, since: since, now: now) == since)
    }

    @Test func newRouteTakesNow() {
        let since = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 2_000)
        #expect(ConnectionRoute.switchedAt(previous: .relay, next: .wifi, since: since, now: now) == now)
        #expect(ConnectionRoute.switchedAt(previous: nil, next: .relay, since: nil, now: now) == now)
    }
}
