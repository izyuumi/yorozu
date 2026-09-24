#!/usr/bin/env bash
# macOS + Xcode Swift toolchain. Compile the actual stores, then execute them with only
# Keychain I/O fault-injected and Application Support redirected to a disposable directory.
# No production Keychain items or app caches are read or changed.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/yorozu-ios-host-persistence.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
python3 - "$repo_root" "$fixture_dir" <<'PYFIXTURE'
import json
import sys
from pathlib import Path
repo, fixture = map(Path, sys.argv[1:])
source = fixture / "Sources/Check"
source.mkdir(parents=True)
(fixture / "Package.swift").write_text(
    '// swift-tools-version: 6.0\nimport PackageDescription\n'
    'let package = Package(name: "PersistenceCheck", platforms: [.macOS(.v15)], '
    'dependencies: [.package(path: ' + json.dumps(str(repo / 'packages/shared-swift')) + ')], '
    'targets: [.executableTarget(name: "Check", dependencies: '
    '[.product(name: "YorozuShared", package: "shared-swift")])])\n')
pairing = (repo / 'apps/ios/Sources/YorozuIOS/PairingStore.swift').read_text()
start = pairing.index('enum Keychain {')
end = pairing.index('/// All pairing records')
stub = r'''enum Keychain {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var items: [String: Data] = [:]
    nonisolated(unsafe) static var failAccount: String?
    struct Injected: Error {}
    static func load(_ account: String) -> Data? { try? loadRequired(account) }
    static func loadRequired(_ account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }; return items[account]
    }
    static func save(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failAccount == account { failAccount = nil; throw Injected() }
        items[account] = data
    }
    static func clear(_ account: String) { try? clearRequired(account) }
    static func clearRequired(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }; items.removeValue(forKey: account)
    }
}

'''
(source / 'PairingStore.swift').write_text(pairing[:start] + stub + pairing[end:])
cache = (repo / 'apps/ios/Sources/YorozuIOS/CacheStore.swift').read_text().replace(
    'URL.applicationSupportDirectory',
    'URL(fileURLWithPath: ProcessInfo.processInfo.environment["PERSISTENCE_CHECK_ROOT"]!)')
(source / 'CacheStore.swift').write_text(cache)
(source / 'Main.swift').write_text(r'''import CryptoKit
import Foundation
import YorozuShared

@main struct Check {
    static func main() throws {
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "") throws {
            let result = try condition(); precondition(result, message)
        }
        func expectFailure(_ work: () throws -> Void) {
            do { try work(); fatalError("Expected failure") } catch {}
        }
        func pairing(_ value: UInt8) -> QrPayload {
            QrPayload(relayUrl: "wss://example.test", macPubkey: Data(repeating: value, count: 32).base64URLEncodedString(), token: "unused", roomId: "room-\(value)")
        }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PERSISTENCE_CHECK_ROOT"]!)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = PhoneIdentity.generate()
        let a = PairingStore.Stored(pairing: pairing(1), identity: identity, paired: true, counters: ChannelCounter(send: 47, recv: 81))
        let b = PairingStore.Stored(pairing: pairing(2), identity: .generate())
        let legacyKey = SymmetricKey(size: .bits256)
        try Keychain.save(legacyKey.withUnsafeBytes { Data($0) }, account: "thread-cache-key")
        let legacyCache = ThreadCache(directory: root.appending(path: "threads"), key: legacyKey)
        let thread = ThreadSummary(id: "collision", title: "Old private chat", archived: false, lastActivity: 123)
        legacyCache.save(threads: [thread])
        let ciphertext = try Data(contentsOf: legacyCache.directory.appending(path: "threads.bin"))
        try Keychain.save(JSONEncoder().encode(a), account: "pairing")
        Keychain.failAccount = "pairings"
        expectFailure { try PairingStore.save(b) }
        try check(Keychain.load("pairing") != nil, "Failed migration must retain original identity")
        try check(PairingStore.legacyHostID == a.hostID)
        let cacheA = try CacheStore.open(hostID: a.hostID)
        try check(cacheA.threads() == [thread], "Ciphertext and original key must survive failed pairing commit")
        try check(try Data(contentsOf: cacheA.directory.appending(path: "threads.bin")) == ciphertext)
        try check(try PairingStore.migrateLegacy() == a.hostID)
        try check(Keychain.load("pairing") == nil)
        let counterA = PairingCounterStorage(hostID: a.hostID)
        try check(try counterA.load() == a.counters)
        try PairingStore.save(b)
        let counterB = PairingCounterStorage(hostID: b.hostID)
        DispatchQueue.concurrentPerform(iterations: 2) { host in
            for value in 1...200 {
                do {
                    if host == 0 {
                        try counterA.save(ChannelCounter(send: 47 + value, recv: 81 + value))
                    } else {
                        try counterB.save(ChannelCounter(send: value, recv: value * 2))
                        try PairingStore.updateNickname("Work", hostID: b.hostID)
                    }
                } catch { fatalError("Concurrent store failed: \(error)") }
            }
        }
        try check(try counterA.load() == ChannelCounter(send: 247, recv: 281))
        try check(try counterB.load() == ChannelCounter(send: 200, recv: 400))
        try check(PairingStore.load(hostID: b.hostID)?.nickname == "Work")
        let cacheB = try CacheStore.open(hostID: b.hostID)
        cacheB.save(threads: [ThreadSummary(id: "collision", title: "Host B", archived: false, lastActivity: 456)])
        try check(cacheA.threads() == [thread])
        try check(cacheB.threads().first?.title == "Host B")
        let repaired = PairingStore.Stored(pairing: pairing(1), identity: .generate())
        try PairingStore.save(repaired)
        expectFailure { try counterA.save(ChannelCounter(send: 999, recv: 999)) }
        PairingStore.markPaired(hostID: a.hostID, expectedIdentity: identity.sessionPublicKey)
        try check(PairingStore.load(hostID: a.hostID)?.paired != true, "Old callback must not burn repair token")
        try check(PairingStore.load(hostID: a.hostID)?.pairing.token == "unused")
        try PairingStore.remove(hostID: a.hostID)
        try CacheStore.clear(hostID: a.hostID)
        try check(PairingStore.loadAll().count == 1)
        try check(try counterB.load() == ChannelCounter(send: 200, recv: 400))
        try check(cacheB.threads().first?.title == "Host B")
        try check(!FileManager.default.fileExists(atPath: cacheA.directory.path))
        // Pre-Keychain counters also migrate before the legacy defaults disappear.
        let c = PairingStore.Stored(pairing: pairing(3), identity: .generate())
        let oldCounters = ChannelCounterStore(defaults: .standard,
            ownPub: c.identity.sessionPublicKey, peerPub: Data(repeating: 3, count: 32))
        defer { oldCounters.clear() }
        try oldCounters.save(ChannelCounter(send: 55, recv: 89))
        try Keychain.save(JSONEncoder().encode(c), account: "pairing")
        try check(try PairingStore.migrateLegacy() == c.hostID)
        try check(try PairingCounterStorage(hostID: c.hostID).load() == ChannelCounter(send: 55, recv: 89))
        try check(try oldCounters.load() == nil)
        print("PASS: encrypted migration/retry, legacy counters, concurrent two-host writes, per-host cache/removal, stale repair callbacks")
    }
}
''')
PYFIXTURE
PERSISTENCE_CHECK_ROOT="$fixture_dir/cache" swift run --package-path "$fixture_dir" Check
bin_path="$(swift build --package-path "$fixture_dir" --show-bin-path)"
xcrun swiftc -typecheck -swift-version 6 -target "$(uname -m)-apple-macosx15.0" \
  -I "$bin_path" -I "$bin_path/Modules" \
  "$repo_root/apps/ios/Sources/YorozuIOS/PairingStore.swift" \
  "$repo_root/apps/ios/Sources/YorozuIOS/CacheStore.swift"
