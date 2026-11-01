import Foundation
import Testing
@testable import YorozuWire

/// #532 step 4: the plugin's hints, which of them a race dials, and the Bonjour tag.
struct DirectCandidatesTests {
    let wifi = LocalInterface(name: "en0", address: "192.168.0.20", prefix: 24)
    let wifi6 = LocalInterface(name: "en0", address: "fd00:1::20", prefix: 64)
    let tailscale = LocalInterface(name: "utun4", address: "100.101.1.2", prefix: 32)

    func plan(_ hints: DirectHints?, _ interfaces: [LocalInterface], isMac: Bool = false, lanAllowed: Bool = true, lanDenied: Bool = false)
        -> (candidates: [String], skipped: [String]) {
        let plan = DirectCandidates.plan(hints: hints, interfaces: interfaces, isMac: isMac, lanAllowed: lanAllowed, lanDenied: lanDenied)
        return (plan.candidates.map(\.absoluteString), plan.skipped.map { "\($0.0) (\($0.1))" })
    }

    @Test func lanOnlyOnThisSubnet() {
        let hints = DirectHints(port: 9000, lan: [.init(address: "192.168.0.9", prefix: 24), .init(address: "10.77.0.5", prefix: 16)])
        #expect(plan(hints, [wifi]) == (["ws://192.168.0.9:9000"], ["10.77.0.5 (not on this subnet)"]))
        // An interface that is down, or a VPN's, is no LAN.
        let down = LocalInterface(name: "en0", address: "192.168.0.20", prefix: 24, up: false)
        let vpn = LocalInterface(name: "utun2", address: "192.168.0.20", prefix: 24)
        #expect(plan(hints, [down, vpn]).candidates.isEmpty)
    }

    @Test func lanOnIPv6IsBracketed() {
        let hints = DirectHints(port: 9000, lan: [.init(address: "fd00:1::9", prefix: 64), .init(address: "fd00:2::9", prefix: 64)])
        #expect(plan(hints, [wifi, wifi6]) == (["ws://[fd00:1::9]:9000"], ["fd00:2::9 (not on this subnet)"]))
    }

    @Test func lanWaitsForLocalNetwork() {
        let hints = DirectHints(port: 9000, lan: [.init(address: "192.168.0.9", prefix: 24)])
        #expect(plan(hints, [wifi], lanAllowed: false) == ([], ["192.168.0.9 (Local Network not allowed yet)"]))
        #expect(plan(hints, [wifi], lanDenied: true) == ([], ["192.168.0.9 (Local Network denied)"]))
    }

    @Test func tailscaleOnlyWithAnUpVPNInterfaceInRangeAndTheNameLast() {
        let hints = DirectHints(port: 9000, tailscale: [.init(address: "100.101.1.1"), .init(address: "fd7a:115c:a1e0::1")],
            magicDNS: "host.tail0.ts.net")
        #expect(plan(hints, [wifi, tailscale], lanAllowed: false).candidates
            == ["ws://100.101.1.1:9000", "ws://[fd7a:115c:a1e0::1]:9000", "ws://host.tail0.ts.net:9000"])
        let v6 = LocalInterface(name: "utun4", address: "fd7a:115c:a1e0::2", prefix: 128)
        #expect(plan(hints, [v6]).candidates.count == 3)
        let none = ["100.101.1.1 (no Tailscale interface up)", "fd7a:115c:a1e0::1 (no Tailscale interface up)",
            "the MagicDNS name (no Tailscale interface up)"]
        #expect(plan(hints, [wifi]) == ([], none))
        #expect(plan(hints, [LocalInterface(name: "utun4", address: "100.101.1.2", prefix: 32, up: false)]).skipped == none)
        #expect(plan(hints, [LocalInterface(name: "utun4", address: "10.8.0.2", prefix: 24)]).skipped == none)
        #expect(plan(hints, [LocalInterface(name: "en0", address: "100.101.1.2", prefix: 10)]).skipped == none)
    }

    @Test func loopbackOnlyOnTheMacAndFirst() {
        let hints = DirectHints(port: 9000, lan: [.init(address: "192.168.0.9", prefix: 24)])
        let hostInterface = LocalInterface(name: "en0", address: "192.168.0.9", prefix: 24)
        #expect(plan(hints, [hostInterface], isMac: true).candidates == ["ws://127.0.0.1:8738", "ws://[::1]:8738", "ws://192.168.0.9:9000"])
        #expect(plan(nil, [wifi], isMac: true).candidates == ["ws://127.0.0.1:8738", "ws://[::1]:8738"])
        #expect(plan(DirectHints(port: 9000), [wifi], isMac: true).candidates == ["ws://127.0.0.1:8738", "ws://[::1]:8738"])
        #expect(plan(nil, [wifi]).candidates.isEmpty)
    }

    @Test func loopbackIsSkippedWhenTheHostsAddressesAreNotLocal() {
        let hints = DirectHints(port: 9000, lan: [.init(address: "192.168.1.9", prefix: 24)],
            tailscale: [.init(address: "100.101.1.1")])
        #expect(plan(hints, [wifi], isMac: true) == ([], [
            "127.0.0.1 (host is on another machine)", "::1 (host is on another machine)",
            "192.168.1.9 (not on this subnet)", "100.101.1.1 (no Tailscale interface up)"
        ]))
    }

    @Test func aLocalHintMatchesAddressBytesEvenOnADownVPNInterface() {
        let hints = DirectHints(port: 9000, tailscale: [.init(address: "fd7a:115c:a1e0:0:0:0:0:1")])
        let local = LocalInterface(name: "utun4", address: "fd7a:115c:a1e0::1", prefix: 128, up: false)
        #expect(plan(hints, [local], isMac: true).candidates == ["ws://127.0.0.1:8738", "ws://[::1]:8738"])
    }

    @Test func bonjourResultsMustBeOnALocalSubnet() {
        #expect(DirectCandidates.onLAN("192.168.0.9", [wifi]))
        #expect(!DirectCandidates.onLAN("192.168.1.9", [wifi]))
        #expect(!DirectCandidates.onLAN("100.101.1.1", [tailscale]))
    }

    @Test func theSystemListsLoopback() {
        #expect(LocalInterface.current().contains { $0.address == "127.0.0.1" && $0.prefix == 8 && $0.up && !$0.isVPN })
    }

    @Test func theTagMatchesTheVector() {
        let key = Data(0...31)
        let date = Date(timeIntervalSince1970: 493000 * 3600)
        #expect(Direct.bonjourEpoch(date) == 493000)
        #expect(Direct.bonjourEpoch(date.addingTimeInterval(-0.1)) == 492999)
        #expect(Direct.bonjourEpoch(date.addingTimeInterval(3599.9)) == 493000)
        #expect(Direct.bonjourTag(hostKey: key, epoch: 493000) == "Iaz7DaMYBz9S")
        let tags = Direct.bonjourTags(hostKey: key, at: date)
        #expect(tags.count == 3)
        for epoch: Int64 in 492999...493001 {
            #expect(tags.contains(Direct.bonjourTag(hostKey: key, epoch: epoch)))
        }
        #expect(Direct.bonjourTags(hostKey: key, at: date.addingTimeInterval(3600)) != tags)
    }

    @Test func routesClassifyTheWinningURL() {
        #expect(DirectRoute.of(nil, network: "wired") == .relay)
        for host in ["127.0.0.1", "[::1]", "localhost"] {
            #expect(DirectRoute.of(URL(string: "ws://\(host):8738"), network: "wired") == .thisMac)
        }
        for host in ["100.64.0.1", "[fd7a:115c:a1e0::1]", "x.ts.net"] {
            #expect(DirectRoute.of(URL(string: "ws://\(host):8738"), network: "wired") == .tailscale)
        }
        for host in ["192.168.0.1", "host.local", "[fd00::1]", "100.128.0.1"] {
            #expect(DirectRoute.of(URL(string: "ws://\(host):8738"), network: "wifi") == .wifi)
            #expect(DirectRoute.of(URL(string: "ws://\(host):8738"), network: "wired") == .localNetwork)
            #expect(DirectRoute.of(URL(string: "ws://\(host):8738"), network: "other") == .localNetwork)
        }
    }

    func decode(_ json: String) throws -> WireEvent {
        try JSONDecoder().decode(WireEvent.self, from: Data(json.utf8))
    }

    @Test func hintsDecode() throws {
        let json = #"{"kind":"direct_hints","data":{"port":8738,"lan":[{"address":"192.168.0.9","prefix":24},{"address":"fd00::9","prefix":64}],"tailscale":[{"address":"100.101.1.1"}],"magicDNS":"host.tail0.ts.net","later":1}}"#
        let hints = DirectHints(port: 8738, lan: [.init(address: "192.168.0.9", prefix: 24), .init(address: "fd00::9", prefix: 64)],
            tailscale: [.init(address: "100.101.1.1")], magicDNS: "host.tail0.ts.net")
        #expect(try decode(json) == .directHints(hints))
        #expect(try JSONDecoder().decode(WireEvent.self, from: WireEvent.directHints(hints).encoded()) == .directHints(hints))
    }

    @Test func invalidHintsAreDropped() throws {
        let json = #"{"kind":"direct_hints","data":{"port":8738,"lan":[{"address":"nope","prefix":24},{"address":"10.0.0.1","prefix":33},{"address":"fe80::1%en0","prefix":64},{"address":"10.0.0.2"},{"address":"10.0.0.3","prefix":8}],"tailscale":[{"address":"host"},7,{"address":"100.64.0.1"}],"magicDNS":"bad/name"}}"#
        #expect(try decode(json) == .directHints(DirectHints(port: 8738, lan: [.init(address: "10.0.0.3", prefix: 8)],
            tailscale: [.init(address: "100.64.0.1")])))
        #expect(try decode(#"{"kind":"direct_hints","data":{"port":8738}}"#) == .directHints(DirectHints(port: 8738)))
        for bad in [#"{"port":0}"#, #"{"port":70000}"#, #"{"lan":[]}"#, #""x""#] {
            #expect(try decode(#"{"kind":"direct_hints","data":\#(bad)}"#).kind == "direct_hints")
            guard case .unknown = try decode(#"{"kind":"direct_hints","data":\#(bad)}"#) else {
                Issue.record("\(bad) decoded")
                continue
            }
        }
    }

    @Test func theStoreSavesLoadsAndForgets() {
        let store = DirectHintStore(suite: "yorozu.tests.\(UUID().uuidString)")
        let hints = DirectHints(port: 8738, lan: [.init(address: "192.168.0.9", prefix: 24)], magicDNS: "host.tail0.ts.net")
        #expect(store.load(room: "room") == nil)
        store.save(hints, room: "room")
        #expect(store.load(room: "room") == hints)
        #expect(store.load(room: "other") == nil)
        store.forget(room: "room")
        #expect(store.load(room: "room") == nil)
    }
}
