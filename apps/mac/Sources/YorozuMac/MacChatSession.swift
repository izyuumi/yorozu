import AppKit
import CryptoKit
import Foundation
import Security
import YorozuKeepalive
import YorozuShared

enum MacRole: String, CaseIterable, Identifiable { case host, client; var id: Self { self } }

@MainActor @Observable
final class MacChatSession {
    static let shared = MacChatSession()
    private static let roleKey = "macRole"
    private(set) var role: MacRole?
    private var local: ChatModel
    private(set) var hosts = MultiHostModel()
    private(set) var relays: [HostID: RelayClient] = [:]
    private(set) var failure: String?
    private(set) var hostFailures: [HostID: String] = [:]
    @ObservationIgnored private var retiringClients: Task<Void, Never>?
    @ObservationIgnored private var changingHosts: Set<HostID> = []
    @ObservationIgnored private let store: MacPairingStore
    @ObservationIgnored private let clientFactory: ((MacPairingStore.Stored) throws -> ChatModel)?

    // The host role still uses its local socket. Legacy single-model callers in onboarding
    // refer to the most recently chosen client host; thread actions use HostThreadID instead.
    var model: ChatModel { role == .client ? hosts.session(for: hosts.lastUsedHostID ?? "")?.model ?? hosts.sessions.first?.model ?? local : local }
    var relay: RelayClient? { relays[hosts.lastUsedHostID ?? ""] ?? relays.values.first }
    var pairedAt: Date? { hosts.session(for: hosts.lastUsedHostID ?? "")?.pairedAt }

    init(store: MacPairingStore = .shared, initialRole: MacRole? = nil,
         clientFactory: ((MacPairingStore.Stored) throws -> ChatModel)? = nil) {
        self.store = store
        self.clientFactory = clientFactory
        var initialRole = initialRole ?? MacRole(rawValue: UserDefaults.standard.string(forKey: Self.roleKey) ?? "")
        if initialRole == nil, UserDefaults.standard.bool(forKey: OnboardingWindow.completedKey) {
            initialRole = .host
            UserDefaults.standard.set(MacRole.host.rawValue, forKey: Self.roleKey)
        }
        role = initialRole
        local = initialRole == .host ? (try? Self.localModel()) ?? Self.idleModel() : Self.idleModel()
        hosts.lastUsedHostID = store.lastUsedHostID
    }

    func start() {
        switch role {
        case .host: startHost()
        case .client: startClients()
        case nil: break
        }
    }

    func select(_ role: MacRole) {
        guard role != self.role else { return }
        local.close(); hosts.suspend(); relays.removeAll(); failure = nil
        // The asynchronous client startup must not expose the former local host's paired
        // state to onboarding while it waits for saved remote connections to reopen.
        if role == .client { local = Self.idleModel() }
        let previous = hosts
        hosts = MultiHostModel(lastUsedHostID: store.lastUsedHostID)
        let previousRetirement = retiringClients
        let retirement = Task {
            await previousRetirement?.value
            for host in previous.sessions { await previous.remove(host.id) }
        }
        retiringClients = retirement
        self.role = role
        UserDefaults.standard.set(role.rawValue, forKey: Self.roleKey)
        if role == .host { startHost() }
        else {
            Sidecar.shared.stop()
            Task {
                await retirement.value
                guard self.role == .client else { return }
                startClients()
            }
        }
    }

    func clearRole() {
        local.close(); hosts.suspend(); relays.removeAll(); failure = nil
        Sidecar.shared.stop()
        role = nil
        local = Self.idleModel()
        UserDefaults.standard.removeObject(forKey: Self.roleKey)
    }

    enum PairingError: LocalizedError {
        case alreadyConnected, unknownHost, changingConnection
        var errorDescription: String? {
            switch self {
            case .alreadyConnected: "Already connected. Choose Repair connection to replace this host’s connection."
            case .unknownHost: "This host is no longer paired."
            case .changingConnection: "This host’s connection is already changing. Try again when it finishes."
            }
        }
    }

    func pairedHost(in code: String) throws -> HostID? {
        let payload = try QrPayload.decode(code)
        return try store.loadAll().first { $0.id == payload.hostID }?.id
    }

    /// Duplicate detection precedes identity creation and consuming the one-time code.
    func pair(with text: String) throws {
        do {
            let pairing = try QrPayload.decode(text)
            guard let hostID = pairing.hostID else { throw CocoaError(.fileReadCorruptFile) }
            guard !changingHosts.contains(hostID) else { throw PairingError.changingConnection }
            guard try store.loadAll().allSatisfy({ $0.id != pairing.hostID }) else { throw PairingError.alreadyConnected }
            let stored = MacPairingStore.Stored(pairing: pairing, identity: .generate())
            try store.save(stored)
            failure = nil
            hosts.lastUsedHostID = stored.id; store.lastUsedHostID = stored.id
            if role != .client { select(.client) } else { connect(stored) }
        } catch { failure = error.localizedDescription; throw error }
    }

    struct PendingPairing: Equatable {
        let code: String
        let relayHost: String
        let macKeyFingerprint: String
        let stopsHosting: Bool
        let repairsHost: HostID?
    }
    enum PairingLinkAction: Equatable { case pair(String), confirm(PendingPairing) }

    func pairingLinkAction(for url: URL) -> PairingLinkAction? {
        guard url.host()?.lowercased() == "pair", let payload = try? QrPayload.decode(url.absoluteString) else { return nil }
        let stored = (try? store.loadAll()) ?? []
        let hosting = role == .host
        guard hosting || !stored.isEmpty else { return .pair(url.absoluteString) }
        return .confirm(PendingPairing(code: url.absoluteString,
            relayHost: payload.relayUrl,
            macKeyFingerprint: payload.macKeyFingerprint ?? String(localized: "unreadable key"),
            stopsHosting: hosting, repairsHost: stored.first { $0.id == payload.hostID }?.id))
    }

    func handlePairingLink(_ url: URL) {
        switch pairingLinkAction(for: url) {
        case .pair(let code)?: do { try pair(with: code) } catch {}
        case .confirm(let pending)?:
            guard PairingConsent.ask(pending) else { return }
            Task {
                do {
                    if pending.repairsHost != nil { try await repair(with: pending.code) }
                    else { try pair(with: pending.code) }
                } catch { failure = error.localizedDescription }
            }
        case nil: break
        }
    }

    func repair(with text: String) async throws {
        do {
            let pairing = try QrPayload.decode(text)
            guard let old = try store.loadAll().first(where: { $0.id == pairing.hostID }) else { throw PairingError.unknownHost }
            guard changingHosts.insert(old.id).inserted else { throw PairingError.changingConnection }
            defer { changingHosts.remove(old.id) }
            let lastUsed = hosts.lastUsedHostID
            if let host = hosts.session(for: old.id) {
                if hostFailures[old.id] == nil { try host.model.saveForRestart() }
                await host.model.shutdown()
            }
            // Repair rotates only this connection's identity and counters. Its encrypted
            // history, draft, and queued work still belong to the same authenticated host.
            let original = old
            let stored = MacPairingStore.Stored(pairing: pairing, identity: .generate(),
                nickname: original.nickname, usesLegacyCache: original.usesLegacyCache)
            do { try store.save(stored) }
            catch {
                // A retired model cannot reconnect. Rebuild from the still-committed old
                // identity/counters after a failed write, retaining every cached draft.
                await hosts.remove(old.id); relays.removeValue(forKey: old.id)
                connect(original)
                hosts.lastUsedHostID = lastUsed
                throw error
            }
            await hosts.remove(old.id); relays.removeValue(forKey: old.id)
            if role != .client { select(.client) } else { connect(stored) }
            hosts.lastUsedHostID = lastUsed
            store.lastUsedHostID = lastUsed
            failure = nil
        } catch { failure = error.localizedDescription; throw error }
    }

    func removeHost(_ id: HostID) async {
        do {
            guard let stored = try store.loadAll().first(where: { $0.id == id }) else { return }
            guard changingHosts.insert(id).inserted else { throw PairingError.changingConnection }
            defer { changingHosts.remove(id) }
            let lastUsed = hosts.lastUsedHostID
            if let host = hosts.session(for: id) { await host.model.shutdown() }
            do {
                try store.clearCache(for: stored)
                try store.remove(id)
            } catch {
                // File/Keychain failures leave the pairing committed. Rebuild instead of
                // leaving Settings with a permanently retired model behind Retry.
                await hosts.remove(id); relays.removeValue(forKey: id)
                connect(stored)
                hosts.lastUsedHostID = lastUsed
                store.lastUsedHostID = lastUsed
                throw error
            }
            await hosts.remove(id); relays.removeValue(forKey: id)
            if hosts.lastUsedHostID == id { hosts.lastUsedHostID = hosts.sessions.first?.id }
            store.lastUsedHostID = hosts.lastUsedHostID
            hostFailures.removeValue(forKey: id)
            updateBadge()
            failure = nil
        } catch { failure = error.localizedDescription }
    }

    func nickname(_ name: String, for id: HostID) {
        do {
            let nickname = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            try store.update(id) { $0.nickname = nickname.isEmpty ? nil : nickname }
            hosts.session(for: id)?.nickname = nickname.isEmpty ? nil : nickname
        } catch { failure = error.localizedDescription }
    }

    func retryConnection(_ id: HostID) {
        if hostFailures[id] != nil {
            Task {
                guard changingHosts.insert(id).inserted else { return }
                defer { changingHosts.remove(id) }
                await hosts.remove(id)
                if let stored = try? store.loadAll().first(where: { $0.id == id }) { connect(stored) }
            }
        } else { hosts.session(for: id)?.model.reconnect() }
    }
    func rememberLastHost() { store.lastUsedHostID = hosts.lastUsedHostID }
    func saveForRestart() throws {
        if role == .client { for host in hosts.sessions { try host.model.saveForRestart() } }
        else { try local.saveForRestart() }
    }

    private func startClients() {
        do { for stored in try store.loadAll() where hosts.session(for: stored.id) == nil { connect(stored) } }
        catch { failure = error.localizedDescription }
    }

    private func startHost() {
        // A hard quit can leave the old Unix-socket pathname behind. Do not let the new
        // NWConnection race that dead endpoint while the sidecar replaces it: NWConnection
        // does not redial after that failure, leaving Settings with an empty device list.
        let path = LocalSocketTransport.defaultPath()
        try? FileManager.default.removeItem(atPath: path)
        Sidecar.shared.start()
        do { local = try Self.localModel() }
        catch {
            failure = "Could not open encrypted local cache: \(error.localizedDescription)"
            Log.write(failure!)
            local = Self.idleModel()
            return
        }
        configure(local)
        // Only the host answers a phone's request to turn approvals off: the runtime sends it
        // over the local socket alone, and the person at this keyboard is the one it is asking.
        // Never on the relay model — a hostile host could otherwise pop consent alerts on a
        // client Mac, and an Allow there would be sent back to the very host that asked.
        local.onApprovalSettingsRequest = { [weak model = local] request in
            guard let model else { return }
            YoloConsent.ask(request, model: model)
        }
        Task {
            var waited = 0
            while !FileManager.default.fileExists(atPath: path), waited < 100 {
                try? await Task.sleep(for: .milliseconds(100)); waited += 1
            }
            local.start()
        }
    }


    private func connect(_ stored: MacPairingStore.Stored) {
        do {
            let model: ChatModel
            if let clientFactory { model = try clientFactory(stored) }
            else {
                let store = store
                let relay = try RelayClient(pairing: stored.pairing, identity: stored.identity,
                    paired: stored.paired == true, counters: MacPairingCounterStorage(store: store, host: stored),
                    onPaired: { store.markPaired(stored) })
                relays[stored.id] = relay
                model = ChatModel(transport: relay, cache: try store.openCache(for: stored), device: "mac")
            }
            let host = HostSession(id: stored.id, model: model, relayURL: stored.pairing.relayUrl,
                nickname: stored.nickname, pairedAt: stored.pairedAt)
            model.onPaired = { [weak self, weak host] in
                guard let self else { return }
                host?.pairedAt = (try? self.store.loadAll())?.first { $0.id == stored.id }?.pairedAt
            }
            configure(model)
            hostFailures.removeValue(forKey: stored.id)
            hosts.add(host)
            model.start()
        } catch {
            hostFailures[stored.id] = error.localizedDescription
            relays.removeValue(forKey: stored.id)
            hosts.add(HostSession(id: stored.id, model: Self.idleModel(), relayURL: stored.pairing.relayUrl,
                nickname: stored.nickname, pairedAt: stored.pairedAt))
        }
    }

    private func updateBadge() {
        let count = role == .client ? hosts.unreadCount : local.unreadCount
        NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
    }
    private func configure(_ model: ChatModel) {
        model.onThreads = { [weak self] in self?.updateBadge() }
        model.onUpdateStatus = { [weak model] status in
            guard let model else { return }
            Updates.pending.receive(status, from: model)
        }
    }
    private static func localModel() throws -> ChatModel {
        ChatModel(transport: LocalSocketTransport(path: LocalSocketTransport.defaultPath()), cache: try MacCacheStore.openLocal(), device: "mac")
    }
    private static func idleModel() -> ChatModel { ChatModel(transport: IdleTransport(), device: "mac") }
}

private actor IdleTransport: ChatTransport {
    func connect() -> AsyncStream<TransportUpdate> { AsyncStream { $0.yield(.state(.closed)); $0.finish() } }
    func send(_ event: YorozuEvent) async throws {}
    func close() async {}
}

/// Updating in place matters: deleting then adding exposes a moment with surviving keys
/// but no sequence counters, and can lose the old value when Keychain rejects the new write.
struct MacClientKeychain: Sendable {
    let service: String
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    func load(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
    }
    func save(_ data: Data, account: String) throws {
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var query = query(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
    }
    func clear(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

/// One locked collection keeps counter updates from concurrent relay actors from losing
/// another host's changes. Production uses Keychain; the same repository accepts an isolated
/// backend in the executable integration harness without touching a person's pairings.
final class MacPairingStore: @unchecked Sendable {
    struct Stored: Codable, Sendable {
        var pairing: QrPayload
        var identity: PhoneIdentity
        var paired: Bool?
        var pairedAt: Date?
        var counters: ChannelCounter?
        var nickname: String?
        /// Migration retains the exact legacy cache/key, avoiding a copy or encryption reset.
        var usesLegacyCache: Bool?
        var id: HostID { pairing.hostID! }
    }
    static let shared = MacPairingStore()
    private let lock = NSRecursiveLock()
    private var cleanedLegacy = false
    private let directory: URL
    private let defaults: UserDefaults
    private let read: @Sendable (String) throws -> Data?
    private let write: @Sendable (Data, String) throws -> Void
    private let erase: @Sendable (String) throws -> Void

    init(directory: URL = .applicationSupportDirectory, defaults: UserDefaults = .standard,
         service: String = "to.yumi.yorozu.mac-client",
         read: (@Sendable (String) throws -> Data?)? = nil,
         write: (@Sendable (Data, String) throws -> Void)? = nil,
         erase: (@Sendable (String) throws -> Void)? = nil) {
        let keychain = MacClientKeychain(service: service)
        self.directory = directory
        self.defaults = defaults
        self.read = read ?? { try keychain.load($0) }
        self.write = write ?? { try keychain.save($0, account: $1) }
        self.erase = erase ?? { try keychain.clear($0) }
    }
    var lastUsedHostID: HostID? {
        get { defaults.string(forKey: "lastUsedClientHost") }
        set { defaults.set(newValue, forKey: "lastUsedClientHost") }
    }
    func loadAll() throws -> [Stored] {
        lock.lock(); defer { lock.unlock() }
        if let data = try read("pairings-v2") {
            let hosts = try JSONDecoder().decode([Stored].self, from: data)
            guard hosts.allSatisfy({ $0.pairing.hostID != nil }), Set(hosts.map(\.id)).count == hosts.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if !cleanedLegacy {
                // Retry interrupted migration cleanup after its collection was committed.
                try erase("pairing")
                for host in hosts where host.usesLegacyCache == true { legacyCounters(for: host)?.clear() }
                cleanedLegacy = true
            }
            return hosts
        }
        guard let data = try read("pairing") else { return [] }
        var legacy = try JSONDecoder().decode(Stored.self, from: data)
        guard legacy.pairing.hostID != nil else { throw CocoaError(.fileReadCorruptFile) }
        if legacy.counters == nil { legacy.counters = try legacyCounters(for: legacy)?.load() }
        legacy.usesLegacyCache = true
        // Commit keys and counters together before deleting anything from the old store.
        try write(JSONEncoder().encode([legacy]), "pairings-v2")
        try erase("pairing")
        legacyCounters(for: legacy)?.clear()
        cleanedLegacy = true
        return [legacy]
    }
    func save(_ value: Stored) throws {
        lock.lock(); defer { lock.unlock() }
        var hosts = try loadAll()
        if let index = hosts.firstIndex(where: { $0.id == value.id }) { hosts[index] = value }
        else { hosts.append(value) }
        try write(JSONEncoder().encode(hosts), "pairings-v2")
    }
    func update(_ id: HostID, identity: PhoneIdentity? = nil, _ mutation: (inout Stored) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var hosts = try loadAll()
        guard let index = hosts.firstIndex(where: { $0.id == id }), identity == nil || hosts[index].identity == identity else {
            throw MacPairingCounterStorage.NoPairing()
        }
        mutation(&hosts[index])
        try write(JSONEncoder().encode(hosts), "pairings-v2")
    }
    func remove(_ id: HostID) throws {
        lock.lock(); defer { lock.unlock() }
        let hosts = try loadAll()
        if let old = hosts.first(where: { $0.id == id }) { legacyCounters(for: old)?.clear() }
        try write(JSONEncoder().encode(hosts.filter { $0.id != id }), "pairings-v2")
    }
    func markPaired(_ host: Stored) {
        try? update(host.id, identity: host.identity) {
            if $0.paired != true { $0.paired = true; $0.pairedAt = Date(); $0.pairing.token = "" }
        }
    }
    func legacyCounters(for host: Stored) -> ChannelCounterStore? {
        guard let macPub = Data(base64URLEncoded: host.pairing.macPubkey) else { return nil }
        return ChannelCounterStore(defaults: defaults, ownPub: host.identity.sessionPublicKey, peerPub: macPub)
    }
    private func cacheLocation(for host: Stored) -> (URL, String) {
        host.usesLegacyCache == true
            ? (directory.appending(path: "client-threads"), "thread-cache-key")
            : (directory.appending(path: "client-hosts").appending(path: host.id), "thread-cache-key-" + host.id)
    }
    func openCache(for host: Stored) throws -> ThreadCache {
        lock.lock(); defer { lock.unlock() }
        let (location, account) = cacheLocation(for: host)
        let key: SymmetricKey
        if let data = try read(account) {
            guard data.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            key = SymmetricKey(data: data)
        } else {
            // Existing encrypted cache without its key is corruption, not a fresh cache.
            guard !FileManager.default.fileExists(atPath: location.path) else { throw CocoaError(.fileReadCorruptFile) }
            key = SymmetricKey(size: .bits256)
            try write(key.withUnsafeBytes { Data($0) }, account)
        }
        return ThreadCache(directory: location, key: key)
    }
    func clearCache(for host: Stored) throws {
        lock.lock(); defer { lock.unlock() }
        let (location, account) = cacheLocation(for: host)
        if FileManager.default.fileExists(atPath: location.path) { try FileManager.default.removeItem(at: location) }
        try erase(account)
    }
}

struct MacPairingCounterStorage: ChannelCounterStorage {
    struct NoPairing: Error {}
    let store: MacPairingStore
    let host: MacPairingStore.Stored
    func load() throws -> ChannelCounter? {
        guard let stored = try store.loadAll().first(where: { $0.id == host.id && $0.identity == host.identity }) else { throw NoPairing() }
        return try stored.counters ?? store.legacyCounters(for: stored)?.load()
    }
    func save(_ counter: ChannelCounter) throws {
        try store.update(host.id, identity: host.identity) { $0.counters = counter }
        store.legacyCounters(for: host)?.clear()
    }
    func clear() throws {
        try store.update(host.id, identity: host.identity) { $0.counters = nil }
        store.legacyCounters(for: host)?.clear()
    }
}

private enum MacCacheStore {
    static func openLocal() throws -> ThreadCache {
        let directory = URL(fileURLWithPath: LocalSocketTransport.defaultPath()).deletingLastPathComponent().appending(path: "host-client-cache")
        let keychain = MacClientKeychain(service: "to.yumi.yorozu.mac-client")
        let account = "host-thread-cache-key"
        let key: SymmetricKey
        if let data = try keychain.load(account) {
            guard data.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            key = SymmetricKey(data: data)
        } else {
            key = SymmetricKey(size: .bits256)
            try keychain.save(key.withUnsafeBytes { Data($0) }, account: account)
        }
        return ThreadCache(directory: directory, key: key)
    }
}
