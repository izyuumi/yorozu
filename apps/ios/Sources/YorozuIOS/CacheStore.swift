import CryptoKit
import Foundation
import YorozuShared

/// Wires ``ThreadCache`` to this device: the files go in Application Support, the key that
/// seals them in the Keychain. Losing the key is not a failure — the cache reads back empty
/// and the next `sync_delta` refills it.
enum CacheStore {
    private static let account = "thread-cache-key"

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "threads")
    }

    static func open() -> ThreadCache {
        ThreadCache(directory: directory, key: key())
    }

    /// Unpairing leaves nothing readable behind: both the files and their key go.
    static func clear() {
        try? FileManager.default.removeItem(at: directory)
        Keychain.clear(account)
    }

    private static func key() -> SymmetricKey {
        if let stored = Keychain.load(account), stored.count == 32 {
            return SymmetricKey(data: stored)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        // A key that will not store means a cache that cannot be read back after a restart —
        // still correct, just not persistent, so there is nothing to fail the app over.
        try? Keychain.save(raw, account: account)
        return key
    }
}
