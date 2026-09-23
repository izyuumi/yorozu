import AppKit
import CryptoKit
import Foundation
import Security
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
        model = initialRole == .host ? Self.localModel() : Self.idleModel()
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
        model = Self.localModel(); configure(model)
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
                paired: stored.paired == true, onPaired: MacPairingStore.markPaired)
            self.relay = relay; pairedAt = stored.pairedAt
            let model = ChatModel(transport: relay, cache: MacCacheStore.open(), device: "mac")
            model.onPaired = { [weak self] in
                Task { @MainActor in self?.pairedAt = MacPairingStore.load()?.pairedAt }
            }
            configure(model); self.model = model; model.start()
        } catch {
            failure = error.localizedDescription; model = Self.idleModel()
        }
    }

    private func configure(_ model: ChatModel) {
        model.onThreads = { NSApp.dockTile.badgeLabel = model.unreadCount == 0 ? nil : String(model.unreadCount) }
        model.onApprovalSettingsRequest = { request in YoloConsent.ask(request, model: model) }
    }
    private static func localModel() -> ChatModel {
        ChatModel(transport: LocalSocketTransport(path: LocalSocketTransport.defaultPath()), device: "mac")
    }
    private static func idleModel() -> ChatModel { ChatModel(transport: IdleTransport(), device: "mac") }
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
    static func save(_ data: Data, account: String) throws {
        clear(account); var q = query(account); q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func clear(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

private enum MacPairingStore {
    struct Stored: Codable { var pairing: QrPayload; var identity: PhoneIdentity; var paired: Bool?; var pairedAt: Date? }
    private static let account = "pairing"
    static func load() -> Stored? { MacClientKeychain.load(account).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } }
    static func save(_ value: Stored) throws { try MacClientKeychain.save(JSONEncoder().encode(value), account: account) }
    static func clear() { MacClientKeychain.clear(account) }
    static func markPaired() {
        guard var value = load(), value.paired != true else { return }
        value.paired = true; value.pairedAt = Date(); value.pairing.token = ""; try? save(value)
    }
}

private enum MacCacheStore {
    private static let account = "thread-cache-key"
    private static var directory: URL { URL.applicationSupportDirectory.appending(path: "client-threads") }
    static func open() -> ThreadCache { ThreadCache(directory: directory, key: key()) }
    static func clear() { try? FileManager.default.removeItem(at: directory); MacClientKeychain.clear(account) }
    private static func key() -> SymmetricKey {
        if let data = MacClientKeychain.load(account), data.count == 32 { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256); let data = key.withUnsafeBytes { Data($0) }
        try? MacClientKeychain.save(data, account: account); return key
    }
}
