import Foundation
import Testing

final class MemoryPairingStorage: PairingStorage {
    var items: [String: Data] = [:]
    var failLoad = false
    var failLoadAccounts: Set<String> = []
    var failSave = false
    var failClear = false
    var failClearAccounts: Set<String> = []
    var crashAfterClearAccount: String?
    var crashed = false
    var savedOverride: Data?

    func load(_ account: String) throws -> Data? {
        if crashed || failLoad || failLoadAccounts.contains(account) { throw CocoaError(.fileReadUnknown) }
        return items[account]
    }
    func save(_ data: Data, account: String) throws {
        if crashed || failSave { throw CocoaError(.fileWriteUnknown) }
        items[account] = savedOverride ?? data
    }
    func clear(_ account: String) throws {
        if crashed || failClear || failClearAccounts.contains(account) { throw CocoaError(.fileWriteUnknown) }
        items[account] = nil
        if crashAfterClearAccount == account { crashed = true }
    }
}

struct PairingMigrationTests {
    private func value(paired: Bool = true) throws -> Pairing {
        let json = #"{"pairing":{"v":3,"relayUrl":"wss://relay.test","macPubkey":"key","token":"","roomId":"room"},"identity":{"signingPrivateKey":"","signingPublicKey":"","sessionPrivateKey":"","sessionPublicKey":""},"relayKnows":true,"paired":true}"#
        var value = try JSONDecoder().decode(Pairing.self, from: Data(json.utf8))
        value.paired = paired
        return value
    }

    @Test func newPairingSurvivesUnpairedMarkerClearFailure() throws {
        let storage = MemoryPairingStorage(), state = PairingMigration.State()
        storage.items["pairing-unpaired"] = Data([1])
        storage.failClearAccounts = ["pairing-unpaired"]
        let pairing = try value(paired: false)
        #expect(throws: Never.self) { try pairing.save(storage: storage) }
        #expect(storage.items["pairing-unpaired"] != nil)
        #expect(try Pairing.load(storage: storage, state: state) == pairing)
    }

    @Test func interruptedUnpairDoesNotRestoreLegacyOnNextLaunch() throws {
        let storage = MemoryPairingStorage()
        let data = try JSONEncoder().encode(value())
        storage.items = ["pairing": data, "pairing-v3": data]
        storage.crashAfterClearAccount = "pairing"
        try? Pairing.remove(storage: storage)
        #expect(storage.crashed)
        #expect(storage.items["pairing"] == nil)
        #expect(storage.items["pairing-v3"] == data)

        storage.crashAfterClearAccount = nil
        storage.crashed = false
        let nextLaunch = PairingMigration.State()
        PairingMigration.run(storage: storage, state: nextLaunch)
        #expect(try Pairing.load(storage: storage, state: nextLaunch) == nil)
    }

    @Test func undecodableCurrentPreservesDecodeErrorWhenMarkerLoadFails() throws {
        let storage = MemoryPairingStorage(), state = PairingMigration.State()
        storage.items = ["pairing": Data("undecodable".utf8),
                         "pairing-v3": try JSONEncoder().encode(value())]
        storage.failLoadAccounts = ["pairing-unpaired"]
        state.legacyFallback = true
        #expect(throws: DecodingError.self) { try Pairing.load(storage: storage, state: state) }
    }

    @Test(arguments: [true, false]) func unpairDoesNotMigrateLeftoverLegacy(valid: Bool) throws {
        let storage = MemoryPairingStorage()
        let old = valid ? try JSONEncoder().encode(value()) : Data("undecodable".utf8)
        storage.items = ["pairing": try JSONEncoder().encode(value()), "pairing-v3": old]
        storage.failClearAccounts = ["pairing-v3"]
        try? Pairing.remove(storage: storage)
        #expect(storage.items["pairing"] == nil)
        #expect(storage.items["pairing-v3"] == old)

        storage.failClearAccounts = []
        let nextLaunch = PairingMigration.State()
        PairingMigration.run(storage: storage, state: nextLaunch)
        #expect(try Pairing.load(storage: storage, state: nextLaunch) == nil)
        #expect(storage.items["pairing-v3"] == nil)
        #expect(!nextLaunch.legacyFallback)
    }

    @Test func unpairClearsLegacyEvenWhenCurrentClearFails() throws {
        let storage = MemoryPairingStorage()
        let data = try JSONEncoder().encode(value())
        storage.items = ["pairing": data, "pairing-v3": data]
        storage.failClearAccounts = ["pairing"]
        #expect(throws: (any Error).self) { try Pairing.remove(storage: storage) }
        #expect(storage.items["pairing-v3"] == nil)
        let state = PairingMigration.State()
        PairingMigration.run(storage: storage, state: state)
        #expect(try Pairing.load(storage: storage, state: state) == value())
    }

    @Test(arguments: [true, false]) func unpairedMarkerBlocksLegacyFallback(currentUndecodable: Bool) throws {
        let storage = MemoryPairingStorage(), state = PairingMigration.State()
        storage.items["pairing-v3"] = try JSONEncoder().encode(value())
        storage.failClearAccounts = ["pairing-v3"]
        try? Pairing.remove(storage: storage)
        if currentUndecodable { storage.items["pairing"] = Data("undecodable".utf8) }
        state.legacyFallback = true
        #expect((try? Pairing.load(storage: storage, state: state)) == nil)
        PairingMigration.run(storage: storage, state: state)
        #expect(!state.legacyFallback)
        #expect((try? Pairing.load(storage: storage, state: state)) == nil)
    }

    @Test func newPairingClearsUnpairedMarker() throws {
        let storage = MemoryPairingStorage()
        storage.items["pairing-unpaired"] = Data([1])
        let pairing = try value(paired: false)
        try pairing.save(storage: storage)
        #expect(storage.items["pairing-unpaired"] == nil)
        let nextLaunch = PairingMigration.State()
        PairingMigration.run(storage: storage, state: nextLaunch)
        #expect(try Pairing.load(storage: storage, state: nextLaunch) == pairing)
        // A later legitimate legacy-only pairing must be eligible for migration again.
        storage.items["pairing"] = nil
        storage.items["pairing-v3"] = try JSONEncoder().encode(pairing)
        PairingMigration.run(storage: storage, state: nextLaunch)
        #expect(try Pairing.load(storage: storage, state: nextLaunch) == pairing)
    }

    @Test func oldOnlyPairingMigratesAndReadsBack() throws {
        let storage = MemoryPairingStorage(), state = PairingMigration.State()
        let pairing = try value()
        storage.items["pairing-v3"] = try JSONEncoder().encode(pairing)
        #expect(PairingMigration.run(storage: storage, state: state) == .migrated)
        #expect(storage.items["pairing-v3"] == nil)
        #expect(try Pairing.load(storage: storage, state: state) == pairing)
        #expect(!state.legacyFallback)
        #expect(PairingMigration.run(storage: storage, state: state) == .nothingToDo)
    }

    @Test func failedSaveEnablesFallbackAndRetryRemovesIt() throws {
        let storage = MemoryPairingStorage(), state = PairingMigration.State()
        let pairing = try value(), old = try JSONEncoder().encode(pairing)
        storage.items["pairing-v3"] = old
        #expect(try Pairing.load(storage: storage, state: state) == nil)
        storage.failSave = true
        #expect(PairingMigration.run(storage: storage, state: state) == .kept)
        #expect(storage.items["pairing-v3"] == old)
        #expect(try Pairing.load(storage: storage, state: state) == pairing)
        storage.failSave = false
        #expect(PairingMigration.run(storage: storage, state: state) == .migrated)
        #expect(storage.items["pairing-v3"] == nil)
        #expect(!state.legacyFallback)
        // Even if a legacy item reappears, completed migration cannot read it this process.
        storage.items["pairing"] = nil
        storage.items["pairing-v3"] = old
        #expect(try Pairing.load(storage: storage, state: state) == nil)
    }

    @Test(arguments: [true, false]) func existingNewAlwaysWins(valid: Bool) throws {
        let storage = MemoryPairingStorage(), state = PairingMigration.State()
        let old = try JSONEncoder().encode(value())
        let new = valid ? try JSONEncoder().encode(value(paired: false)) : Data("undecodable".utf8)
        storage.items = ["pairing-v3": old, "pairing": new]
        #expect(PairingMigration.run(storage: storage, state: state) == (valid ? .migrated : .kept))
        #expect(storage.items["pairing"] == new)
        #expect(storage.items["pairing-v3"] == (valid ? nil : old))
        #expect(state.legacyFallback == !valid)
    }

    @Test(arguments: [true, false]) func readBackMismatchKeepsOld(decodable: Bool) throws {
        let storage = MemoryPairingStorage(), state = PairingMigration.State()
        let old = try JSONEncoder().encode(value())
        storage.items["pairing-v3"] = old
        storage.savedOverride = decodable ? try JSONEncoder().encode(value(paired: false)) : Data()
        #expect(PairingMigration.run(storage: storage, state: state) == .kept)
        #expect(storage.items["pairing-v3"] == old)
        #expect(state.legacyFallback)
    }

    @Test func invalidOldAndFailedClearKeepOld() throws {
        let storage = MemoryPairingStorage(), state = PairingMigration.State()
        storage.items["pairing-v3"] = Data()
        #expect(PairingMigration.run(storage: storage, state: state) == .kept)
        #expect(storage.items["pairing"] == nil)
        let old = try JSONEncoder().encode(value())
        storage.items["pairing-v3"] = old
        storage.failClear = true
        #expect(PairingMigration.run(storage: storage, state: state) == .kept)
        #expect(storage.items["pairing-v3"] == old)
        #expect(try Pairing.load(storage: storage, state: state) == value())
        storage.failClear = false
        #expect(PairingMigration.run(storage: storage, state: state) == .migrated)
        #expect(!state.legacyFallback)
    }
}
