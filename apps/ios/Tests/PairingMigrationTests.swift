import Foundation
import Testing

private final class MemoryPairingStorage: PairingStorage {
    var items: [String: Data] = [:]
    var failSave = false
    var failClear = false
    var savedOverride: Data?

    func load(_ account: String) throws -> Data? { items[account] }
    func save(_ data: Data, account: String) throws {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        items[account] = savedOverride ?? data
    }
    func clear(_ account: String) throws {
        if failClear { throw CocoaError(.fileWriteUnknown) }
        items[account] = nil
    }
}

struct PairingMigrationTests {
    private func value(paired: Bool = true) throws -> Pairing {
        let json = #"{"pairing":{"v":3,"relayUrl":"wss://relay.test","macPubkey":"key","token":"","roomId":"room"},"identity":{"signingPrivateKey":"","signingPublicKey":"","sessionPrivateKey":"","sessionPublicKey":""},"relayKnows":true,"paired":true}"#
        var value = try JSONDecoder().decode(Pairing.self, from: Data(json.utf8))
        value.paired = paired
        return value
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
