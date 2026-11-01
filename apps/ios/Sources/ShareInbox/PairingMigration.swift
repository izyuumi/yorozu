import Foundation
import OSLog

protocol PairingStorage {
    func load(_ account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func clear(_ account: String) throws
}

struct KeychainPairingStorage: PairingStorage {
    func load(_ account: String) throws -> Data? { try Keychain.loadRequired(account) }
    func save(_ data: Data, account: String) throws { try Keychain.save(data, account: account) }
    func clear(_ account: String) throws { try Keychain.clearRequired(account) }
}

enum PairingMigration {
    enum Outcome { case nothingToDo, migrated, kept }

    /// Process-local: an unsuccessful migration permits reads of the retained old item until retry.
    final class State: @unchecked Sendable {
        static let shared = State()
        private let lock = NSLock()
        private var fallback = false
        var legacyFallback: Bool {
            get { lock.withLock { fallback } }
            set { lock.withLock { fallback = newValue } }
        }
    }

    @discardableResult
    static func run(storage: any PairingStorage = KeychainPairingStorage(), state: State = .shared) -> Outcome {
        let logger = Logger(subsystem: "to.yumi.yorozu", category: "Migration")
        var step = "read failed"
        do {
            guard let old = try storage.load("pairing-v3") else {
                state.legacyFallback = false
                logger.info("pairing: nothing to do")
                return .nothingToDo
            }
            if let new = try storage.load("pairing") {
                guard (try? JSONDecoder().decode(Pairing.self, from: new)) != nil else {
                    state.legacyFallback = true
                    logger.info("pairing: kept old (new undecodable)")
                    return .kept
                }
            } else {
                step = "old undecodable"
                let pairing = try JSONDecoder().decode(Pairing.self, from: old)
                step = "save failed"
                try storage.save(old, account: "pairing")
                step = "read-back failed"
                guard let saved = try storage.load("pairing"),
                      let decoded = try? JSONDecoder().decode(Pairing.self, from: saved), decoded == pairing else {
                    state.legacyFallback = true
                    logger.info("pairing: kept old (read-back mismatch)")
                    return .kept
                }
            }
            step = "clear failed"
            try storage.clear("pairing-v3")
            state.legacyFallback = false
            logger.info("pairing: migrated")
            return .migrated
        } catch {
            state.legacyFallback = true
            logger.info("pairing: kept old (\(step, privacy: .public))")
            return .kept
        }
    }
}
