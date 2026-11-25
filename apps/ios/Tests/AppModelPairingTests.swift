import Foundation
import Testing
import YorozuWire

@MainActor
@Suite struct AppModelPairingTests {
    private let harness: ModelHarness

    init() throws {
        harness = try ModelHarness()
    }

    private var storage: MemoryPairingStorage { harness.storage }
    private var migration: PairingMigration.State { harness.migration }
    private var transports: ModelHarness.Transports { harness.transports }
    private var cache: ConversationCache { harness.cache }
    private var convId: String { harness.convId }

    private func store(paired: Bool) throws -> Pairing { try harness.store(paired: paired) }
    private func makeModel() -> AppModel { harness.makeModel() }
    private func settled(_ condition: () -> Bool) async -> Bool { await harness.settled(condition) }
    private func openFirstSession() async throws -> AppModel { try await harness.openFirstSession() }
    private func stored() -> Pairing? { harness.stored() }

    private func macAddCode(box: UInt8 = 1) -> DeviceCode {
        let key = Data(repeating: 7, count: 32).base64URLEncodedString()
        return DeviceCode(relayUrl: "wss://relay.example/ws",
            box: Data(repeating: box, count: 16).base64URLEncodedString(), key: key, name: "Mac")
    }

    private func hostLink() -> String {
        let key = Data(repeating: 7, count: 32).base64URLEncodedString()
        return "yorozu://pair?v=3&relay=wss://relay.example/ws&key=\(key)&token=tok&room=room&secret=sec"
    }

    @Test func aPendingHostPairingHidesTheDeviceCode() {
        let model = makeModel()
        let code = macAddCode()
        model.deviceCode = code

        #expect(model.submit(hostLink()) == nil)
        #expect(model.pendingPairing != nil)
        #expect(model.deviceCode == code)
        #expect(!model.showsDeviceCode)
    }

    @Test func cancellingAPastedHostPairingShowsTheDeviceCodeAgain() {
        let model = makeModel()
        let code = macAddCode()
        model.deviceCode = code

        #expect(model.submit(hostLink()) == nil)
        #expect(model.pendingPairing != nil)
        #expect(model.deviceCode == code)
        #expect(!model.showsDeviceCode)
        model.dismissPendingPairing()
        #expect(model.pendingPairing == nil)
        #expect(model.deviceCode == code)
        #expect(model.showsDeviceCode)
    }

    @Test func aDroppedMailboxLetterMintsAFreshCodeOncePendingClears() {
        let original = macAddCode(box: 1)
        var offer = DeviceCodeOffer(code: original)
        #expect(offer.isVisible(pendingHostPairing: false, connecting: false))
        #expect(!offer.isVisible(pendingHostPairing: true, connecting: false))
        #expect(offer.code == original)
        #expect(!offer.shouldMint(pendingHostPairing: true, connecting: false))

        offer.letterDropped()
        #expect(!offer.shouldMint(pendingHostPairing: true, connecting: false))
        #expect(!offer.isVisible(pendingHostPairing: true, connecting: false))
        #expect(offer.shouldMint(pendingHostPairing: false, connecting: false))

        let fresh = macAddCode(box: 2)
        offer.code = fresh
        offer.spent = false
        #expect(offer.code != original)
        #expect(offer.isVisible(pendingHostPairing: false, connecting: false))
        #expect(!offer.shouldMint(pendingHostPairing: false, connecting: false))
    }

    @Test func anAcceptedMailboxLetterMintsAFreshCodeOncePendingClears() {
        let original = macAddCode(box: 1)
        var offer = DeviceCodeOffer(code: original)
        offer.letterReceived(accepted: true)
        #expect(offer.spent)
        #expect(!offer.isVisible(pendingHostPairing: true, connecting: false))
        #expect(!offer.shouldMint(pendingHostPairing: true, connecting: false))
        #expect(offer.shouldMint(pendingHostPairing: false, connecting: false))

        let fresh = macAddCode(box: 2)
        offer.code = fresh
        offer.spent = false
        #expect(offer.code != original)
        #expect(offer.isVisible(pendingHostPairing: false, connecting: false))
        #expect(!offer.shouldMint(pendingHostPairing: false, connecting: false))
    }

    @Test func aDeviceCodeWithoutAKeyIsMintedAgain() {
        let leftover = macAddCode()
        let offer = DeviceCodeOffer(code: leftover)
        #expect(!offer.shouldMint(pendingHostPairing: false, connecting: false, hasKey: true))
        #expect(offer.shouldMint(pendingHostPairing: false, connecting: false, hasKey: false))
        #expect(!offer.shouldMint(pendingHostPairing: true, connecting: false, hasKey: false))
    }

    private var stillConnecting: String { AppModel.stillConnecting }
    private var unpairedScan: String { String(localized: "Scan this code with Yorozu on an iPhone or iPad that is already paired.") }

    private func invites(_ transport: ScriptedTransport) async -> [PairInvite] {
        let sent = await transport.sent
        return sent.compactMap { event -> PairInvite? in
            guard case .pairInvite(let invite) = event else { return nil }
            return invite
        }
    }

    @Test func aPairedPhoneAddsAMacByItsCodeAndTheMacCanStartOver() async throws {
        _ = try store(paired: true)
        let phone = try await harness.openFirstSession(capabilities: [Invite.capability])
        let transport = try #require(harness.scripted)
        let (macCode, macKey) = DeviceCode.make(name: "Mac")

        #expect(phone.submit(macCode.link) == nil)
        #expect(phone.pendingDevice == macCode)
        phone.addDevice(macCode)
        #expect(phone.deviceAdding == .asking(macCode))
        var asked: [PairInvite] = []
        for _ in 0..<100 where asked.isEmpty {
            asked = await invites(transport)
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(asked == [PairInvite()])

        let macHarness = try ModelHarness()
        let mac = macHarness.makeModel()
        mac.deviceCode = macCode
        #expect(mac.offersDeviceCode)
        #expect(mac.showsDeviceCode)
        let letter = try macCode.seal(hostLink())
        #expect(try mac.submit(DeviceCode.open(letter, privateKey: macKey)) == nil)
        mac.deviceCodeSpent = true
        #expect(mac.pendingPairing != nil)
        #expect(!mac.offersDeviceCode)
        #expect(!mac.showsDeviceCode)

        mac.dismissPendingPairing()
        #expect(mac.pendingPairing == nil)
        #expect(mac.offersDeviceCode)
        #expect(DeviceCodeOffer(code: mac.deviceCode, spent: mac.deviceCodeSpent).shouldMint(pendingHostPairing: false, connecting: false))
    }

    @Test func aPairedPhoneWithoutAHostSessionSaysItIsStillConnecting() async throws {
        _ = try store(paired: true)
        let transport = ScriptedTransport()
        await transport.emit(.state(.ready))
        transports.fails = false
        transports.scripted = transport
        let model = makeModel()
        try #require(await settled { model.state == .ready })
        #expect(model.hostInfo == nil)

        let code = macAddCode()
        #expect(model.submit(code.link) == stillConnecting)
        model.addDevice(code)
        #expect(model.deviceAdding == .failed(stillConnecting))
        #expect(await invites(transport).isEmpty)
    }

    @Test func aDisconnectedPhoneSaysItIsStillConnecting() async throws {
        _ = try store(paired: true)
        let model = try await harness.openFirstSession(capabilities: [Invite.capability])
        let transport = try #require(harness.scripted)
        await transport.emit(.state(.offline))
        try #require(await settled { model.state == .offline })
        #expect(model.hostInfo != nil)

        let code = macAddCode()
        #expect(model.submit(code.link) == stillConnecting)
        model.addDevice(code)
        #expect(model.deviceAdding == .failed(stillConnecting))
        #expect(await invites(transport).isEmpty)
    }

    @Test func anUnpairedDeviceAsksForAPairedPhone() {
        let model = makeModel()
        #expect(model.submit(macAddCode().link) == unpairedScan)
    }

    @Test func aBrowserCodeNamesAHostWithoutBrowserPairing() async throws {
        _ = try store(paired: true)
        let model = try await harness.openFirstSession(capabilities: [Invite.capability])
        var browser = macAddCode()
        browser.relayUrl = "wss://relay.test"
        browser.name = "Yorozu Web"
        browser.target = .browser
        #expect(model.submit(browser.link) == String(localized: "Your host’s Yorozu plugin is older than this browser, or browser pairing is off. Update the plugin and set YOROZU_BROWSER_EPHEMERAL=1 on the host."))
        #expect(model.pendingDevice == nil)
    }

    @Test(arguments: [true, false]) func aFailedConnectKeepsTheStoredPairing(paired: Bool) throws {
        let pairing = try store(paired: paired)
        let model = makeModel()
        #expect(transports.asked == 1)
        #expect(try Pairing.load(storage: storage, state: migration) == pairing)
        #expect(model.pairing == pairing)
        #expect(model.conversations[convId] != nil)
        #expect(cache.loadAll().map(\.id) == [convId])
        #expect(model.pairingError != nil)

        model.resume()
        #expect(transports.asked == 2)
        #expect(try Pairing.load(storage: storage, state: migration) == pairing)

        transports.fails = false
        model.resume()
        #expect(transports.asked == 3)
        #expect(model.pairingError == nil)
    }

    @Test func anUnreadablePairingIsReadAgainOnResume() throws {
        let pairing = try store(paired: true)
        transports.fails = false
        storage.failLoad = true
        let model = makeModel()
        #expect(model.pairing == nil)
        #expect(model.pairingError != nil)

        model.resume()
        #expect(model.pairing == nil)
        #expect(model.pairingError != nil)
        #expect(transports.asked == 0)

        storage.failLoad = false
        model.resume()
        #expect(model.pairing == pairing)
        #expect(model.pairingError == nil)
        #expect(model.conversations[convId] != nil)
        #expect(transports.asked == 1)
    }

    @Test func aFailedPairedSaveIsSurfacedAndRetried() async throws {
        let pairing = try store(paired: false)
        storage.failSave = true
        let model = try await openFirstSession()
        #expect(model.pairing?.paired == true)
        #expect(try Pairing.load(storage: storage, state: migration) == pairing)
        #expect(model.pairingError != nil)

        storage.failSave = false
        model.resume()
        let retried = await settled { stored()?.paired == true }
        #expect(retried)
        #expect(stored() == model.pairing)
        #expect(model.pairingError == nil)
    }

    @Test(arguments: [RelayConnection.State.unpaired, .pairingFailed("refused")])
    func aHostRefusalAfterARetriedPairedSaveKeepsThePairing(refusal: RelayConnection.State) async throws {
        _ = try store(paired: false)
        storage.failSave = true
        let first = try await openFirstSession()
        storage.failSave = false
        first.resume()
        _ = await settled { stored()?.paired == true }

        let transport = ScriptedTransport()
        await transport.emit(.state(refusal))
        transports.scripted = transport
        let relaunched = makeModel()
        _ = await settled { relaunched.state == refusal || relaunched.pairing == nil }
        #expect(relaunched.state == refusal)
        #expect(relaunched.pairing?.paired == true)
        #expect(stored()?.paired == true)
        #expect(cache.loadAll().map(\.id) == [convId])
    }
}
