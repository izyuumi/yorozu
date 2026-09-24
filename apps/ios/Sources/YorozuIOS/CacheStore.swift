import CryptoKit
import Foundation
import YorozuShared

/// Each host owns a distinct encrypted cache/outbox and Keychain key.
enum CacheStore {
    private static let legacyAccount = "thread-cache-key"
    private static let lock = NSLock()

    private static var legacyDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "threads")
    }

    private static func account(_ hostID: HostID) -> String { "thread-cache-key.\(hostID)" }

    private static func directory(_ hostID: HostID) -> URL {
        // Host IDs are canonical base64url public keys. Hash also keeps damaged legacy values
        // from becoming path components outside this host's directory.
        let name = Data(SHA256.hash(data: Data(hostID.utf8))).base64URLEncodedString()
        return URL.applicationSupportDirectory.appending(path: "hosts/\(name)/threads")
    }

    static func open(hostID: HostID) throws -> ThreadCache {
        lock.lock()
        defer { lock.unlock() }
        return ThreadCache(directory: directory(hostID), key: try key(hostID))
    }

    /// Called after disconnecting that host; another host's encrypted state remains untouched.
    static func clear(hostID: HostID) throws {
        lock.lock()
        defer { lock.unlock() }
        let directory = directory(hostID)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try Keychain.clearRequired(account(hostID))
    }

    /// Preserve the encryption key before moving its ciphertext. A failed step retains enough
    /// old state to retry; an existing destination is never replaced with stale legacy files.
    static func migrateLegacy(to hostID: HostID) throws {
        lock.lock()
        defer { lock.unlock() }
        let oldKey = try Keychain.loadRequired(legacyAccount)
        let hasFiles = FileManager.default.fileExists(atPath: legacyDirectory.path)
        guard oldKey != nil || hasFiles else { return }
        guard let oldKey, oldKey.count == 32 else {
            throw YorozuCrypto.CryptoError.malformed("legacy thread cache key is unavailable")
        }
        if let current = try Keychain.loadRequired(account(hostID)) {
            guard current == oldKey else {
                throw YorozuCrypto.CryptoError.malformed("legacy thread cache key conflicts with host")
            }
        } else {
            try Keychain.save(oldKey, account: account(hostID))
        }
        try ThreadCache.migrateLegacyDirectory(from: legacyDirectory, to: directory(hostID))
        if hasFiles { try FileManager.default.removeItem(at: legacyDirectory) }
        try Keychain.clearRequired(legacyAccount)
    }

    private static func key(_ hostID: HostID) throws -> SymmetricKey {
        if let stored = try Keychain.loadRequired(account(hostID)) {
            guard stored.count == 32 else {
                throw YorozuCrypto.CryptoError.malformed("thread cache key is invalid")
            }
            return SymmetricKey(data: stored)
        }
        let key = SymmetricKey(size: .bits256)
        try Keychain.save(key.withUnsafeBytes { Data($0) }, account: account(hostID))
        return key
    }
}
