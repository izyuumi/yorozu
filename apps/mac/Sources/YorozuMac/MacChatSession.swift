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
    private(set) var model: ChatModel
    private(set) var relay: RelayClient?
    private(set) var pairedAt: Date?
    private(set) var failure: String?

    private init() {
        var initialRole = MacRole(rawValue: UserDefaults.standard.string(forKey: Self.roleKey) ?? "")
        // Build 139 and earlier had no explicit role preference and always hosted. Preserve
        // that choice for existing installs; a truly fresh install gets the role question.
        if initialRole == nil, UserDefaults.standard.bool(forKey: OnboardingWindow.completedKey) {
            initialRole = .host
            UserDefaults.standard.set(MacRole.host.rawValue, forKey: Self.roleKey)
        }
        role = initialRole
        model = initialRole == .host ? (try? Self.localModel()) ?? Self.idleModel() : Self.idleModel()
    }

    func start() {
        switch role {
        case .host: startHost()
        case .client:
            if let stored = MacPairingStore.load() { connect(stored) }
            else { model = Self.idleModel() }
        case nil: model = Self.idleModel()
        }
    }

    func select(_ role: MacRole) {
        guard role != self.role else { return }
        model.close(); relay = nil; failure = nil
        self.role = role
        UserDefaults.standard.set(role.rawValue, forKey: Self.roleKey)
        if role == .host { startHost() }
        else {
            Sidecar.shared.stop()
            if let stored = MacPairingStore.load() { connect(stored) }
            else { model = Self.idleModel() }
        }
    }

    func clearRole() {
        model.close(); relay = nil; failure = nil
        if role == .client {
            MacPairingStore.clear()
            MacCacheStore.clear()
        }
        Sidecar.shared.stop()
        role = nil
        model = Self.idleModel()
        UserDefaults.standard.removeObject(forKey: Self.roleKey)
    }

    func pair(with text: String) throws {
        do {
            let stored = MacPairingStore.Stored(pairing: try QrPayload.decode(text), identity: .generate())
            try MacPairingStore.save(stored)
            failure = nil
            if role != .client { select(.client) } else { connect(stored) }
        } catch {
            failure = error.localizedDescription
            throw error
        }
    }

    /// A pairing code that arrived as a link and would replace something this Mac has: its
    /// client pairing, or — when it is the host — the hosting itself, since pairing turns it
    /// into a client and stops the sidecar.
    struct PendingPairing: Equatable {
        /// The link itself, which is the pairing string.
        let code: String
        let relayHost: String
        let macKeyFingerprint: String
        /// Whether following it turns this host into a client, which the prompt has to say.
        let stopsHosting: Bool
    }

    /// What a `yorozu://` link may do right now, before anything is done.
    enum PairingLinkAction: Equatable {
        /// Nothing to replace: a Mac with no role and no pairing pairs on the spot.
        case pair(String)
        /// Something to replace, so ask first.
        case confirm(PendingPairing)
    }

    /// Decides without acting, so the rule is one function: only `pair` is a pairing link, only
    /// a code that parses counts, and a Mac that hosts or already holds a pairing is asked.
    func pairingLinkAction(for url: URL) -> PairingLinkAction? {
        guard url.host()?.lowercased() == "pair",
              let payload = try? QrPayload.decode(url.absoluteString)
        else { return nil }
        let code = url.absoluteString
        let hosting = role == .host
        guard hosting || MacPairingStore.load() != nil else { return .pair(code) }
        return .confirm(PendingPairing(
            code: code,
            relayHost: payload.relayHost ?? payload.relayUrl,
            macKeyFingerprint: payload.macKeyFingerprint ?? String(localized: "unreadable key"),
            stopsHosting: hosting
        ))
    }

    /// Where every `yorozu://pair` link lands, from Launch Services or a chat bubble. A link is
    /// a line of text anyone can send, and following it silently would hand this Mac's chat to
    /// whichever Mac minted the code — or, worse, quietly stop this one hosting the phones.
    func handlePairingLink(_ url: URL) {
        switch pairingLinkAction(for: url) {
        case .pair(let code)?:
            do { try pair(with: code) } catch {}
        case .confirm(let pending)?:
            if PairingConsent.ask(pending) { replacePairing(with: pending) }
        case nil:
            break
        }
    }

    /// The confirmed half of ``handlePairingLink(_:)``: the same clean-up Settings' Unpair
    /// does, then the new code, which also flips a host into a client and stops the sidecar.
    func replacePairing(with pending: PendingPairing) {
        unpair()
        do { try pair(with: pending.code) } catch {}
    }

    /// Drops the client pairing: keys, counters and cache together. The counters live in the
    /// same Keychain item as the keys, so clearing the record clears them; what an older build
    /// left in `UserDefaults` goes with it.
    func unpair() {
        model.close(); relay = nil; model = Self.idleModel()
        pairedAt = nil; failure = nil
        MacPairingStore.clear(); MacCacheStore.clear()
        NSApp.dockTile.badgeLabel = nil
    }

    private func startHost() {
        // A hard quit can leave the old Unix-socket pathname behind. Do not let the new
        // NWConnection race that dead endpoint while the sidecar replaces it: NWConnection
        // does not redial after that failure, leaving Settings with an empty device list.
        let path = LocalSocketTransport.defaultPath()
        try? FileManager.default.removeItem(atPath: path)
        Sidecar.shared.start()
        do { model = try Self.localModel() }
        catch {
            failure = "Could not open encrypted local cache: \(error.localizedDescription)"
            Log.write(failure!)
            model = Self.idleModel()
            return
        }
        configure(model)
        // Only the host answers a phone's request to turn approvals off: the runtime sends it
        // over the local socket alone, and the person at this keyboard is the one it is asking.
        // Never on the relay model — a hostile host could otherwise pop consent alerts on a
        // client Mac, and an Allow there would be sent back to the very host that asked.
        model.onApprovalSettingsRequest = { [weak model] request in
            guard let model else { return }
            YoloConsent.ask(request, model: model)
        }
        Task {
            var waited = 0
            while !FileManager.default.fileExists(atPath: path), waited < 100 {
                try? await Task.sleep(for: .milliseconds(100)); waited += 1
            }
            model.start()
        }
    }

    private func connect(_ stored: MacPairingStore.Stored) {
        do {
            model.close()
            let relay = try RelayClient(pairing: stored.pairing, identity: stored.identity,
                paired: stored.paired == true, counters: MacPairingCounterStorage(),
                onPaired: MacPairingStore.markPaired)
            self.relay = relay; pairedAt = stored.pairedAt
            let model = ChatModel(transport: relay, cache: try MacCacheStore.open(), device: "mac")
            model.onPaired = { [weak self] in
                Task { @MainActor in self?.pairedAt = MacPairingStore.load()?.pairedAt }
            }
            configure(model); self.model = model; model.start()
        } catch {
            failure = error.localizedDescription; model = Self.idleModel()
        }
    }

    /// What both roles share. The YOLO consent hook is deliberately not here: see `startHost`.
    private func configure(_ model: ChatModel) {
        model.onThreads = { NSApp.dockTile.badgeLabel = model.unreadCount == 0 ? nil : String(model.unreadCount) }
        model.onUpdateStatus = { [weak model] status in
            guard let model else { return }
            Updates.pending.receive(status, from: model)
        }
    }
    private static func localModel() throws -> ChatModel {
        ChatModel(transport: LocalSocketTransport(path: LocalSocketTransport.defaultPath()), cache: try MacCacheStore.openLocal(), device: "mac")
    }
    private static func idleModel() -> ChatModel { ChatModel(transport: IdleTransport(), cache: try? MacCacheStore.openLocal(), device: "mac") }
}

private actor IdleTransport: ChatTransport {
    func connect() -> AsyncStream<TransportUpdate> { AsyncStream { $0.yield(.state(.closed)); $0.finish() } }
    func send(_ event: YorozuEvent) async throws {}
    func close() async {}
}

private enum MacClientKeychain {
    private static let service = "to.yumi.yorozu.mac-client"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    static func load(_ account: String) -> Data? {
        var q = query(account); q[kSecReturnData as String] = true; var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
    }
    static func loadRequired(_ account: String) throws -> Data? {
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
    static func save(_ data: Data, account: String) throws {
        clear(account); var q = query(account); q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func clear(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

private enum MacPairingStore {
    /// `counters` is the live channel's sequence numbers, kept with the keys they count for
    /// rather than in `UserDefaults`, and optional so a record from before it existed decodes.
    struct Stored: Codable {
        var pairing: QrPayload; var identity: PhoneIdentity; var paired: Bool?; var pairedAt: Date?
        var counters: ChannelCounter?
    }
    private static let account = "pairing"
    static func load() -> Stored? { MacClientKeychain.load(account).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } }
    static func save(_ value: Stored) throws { try MacClientKeychain.save(JSONEncoder().encode(value), account: account) }
    /// The record and, with it, the counters; plus what an older build left in `UserDefaults`.
    static func clear() { try? MacPairingCounterStorage().clearLegacy(); MacClientKeychain.clear(account) }
    static func markPaired() {
        guard var value = load(), value.paired != true else { return }
        value.paired = true; value.pairedAt = Date(); value.pairing.token = ""; try? save(value)
    }
}

/// The client Mac's channel counters, kept in the pairing record in the Keychain: the same
/// arrangement as the phone's `PairingCounterStorage`, for the same reason. A record from a
/// build that kept them in `UserDefaults` is read from there once, so an upgrade does not
/// restart the sequence.
private struct MacPairingCounterStorage: ChannelCounterStorage {
    struct NoPairing: Error {}
    func load() throws -> ChannelCounter? {
        guard let stored = MacPairingStore.load() else { return nil }
        if let counters = stored.counters { return counters }
        return try legacyStore(for: stored)?.load()
    }
    func save(_ counter: ChannelCounter) throws {
        guard var stored = MacPairingStore.load() else { throw NoPairing() }
        stored.counters = counter; try MacPairingStore.save(stored)
        legacyStore(for: stored)?.clear()
    }
    func clear() throws {
        try clearLegacy()
        guard var stored = MacPairingStore.load() else { return }
        stored.counters = nil; try MacPairingStore.save(stored)
    }
    func clearLegacy() throws {
        guard let stored = MacPairingStore.load() else { return }
        legacyStore(for: stored)?.clear()
    }
    private func legacyStore(for stored: MacPairingStore.Stored) -> ChannelCounterStore? {
        guard let macPub = Data(base64URLEncoded: stored.pairing.macPubkey) else { return nil }
        return ChannelCounterStore(defaults: .standard, ownPub: stored.identity.sessionPublicKey, peerPub: macPub)
    }
}

private enum MacCacheStore {
    private static let account = "thread-cache-key"
    private static var directory: URL { URL.applicationSupportDirectory.appending(path: "client-threads") }
    static func open() throws -> ThreadCache { ThreadCache(directory: directory, key: try key()) }
    static func openLocal() throws -> ThreadCache {
        let directory = URL(fileURLWithPath: LocalSocketTransport.defaultPath()).deletingLastPathComponent().appending(path: "host-client-cache")
        return ThreadCache(directory: directory, key: try key(account: "host-thread-cache-key"))
    }
    static func clear() { try? FileManager.default.removeItem(at: directory); MacClientKeychain.clear(account) }
    private static func key(account: String = account) throws -> SymmetricKey {
        if let data = try MacClientKeychain.loadRequired(account) {
            guard data.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256); let data = key.withUnsafeBytes { Data($0) }
        try MacClientKeychain.save(data, account: account); return key
    }
}
