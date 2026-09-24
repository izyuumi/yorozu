import CryptoKit
import Foundation
import Security

/// Typed boundary for the compact encrypted-preview object carried in APNs `userInfo`.
public struct NotificationPreviewPayload: Equatable, Sendable {
    public let nonce: String
    public let ciphertext: String

    public init?(userInfo: [AnyHashable: Any]) {
        guard let preview = userInfo["preview"] as? [String: Any],
              let nonce = preview["n"] as? String,
              let ciphertext = preview["c"] as? String,
              nonce.utf8.count <= 32, ciphertext.utf8.count <= 16_384 else { return nil }
        self.nonce = nonce
        self.ciphertext = ciphertext
    }
}

/// What a sealed preview says once opened: the words for the lock screen, the reference of
/// the card they are about, and whether the Mac judged that card answerable from a button.
/// Mirrors `NotificationPreviewContent` in packages/shared/src/notify.ts.
///
/// The plaintext is `{"v":1,"body":"<text>","event":"<threadRef or null>","quick":<bool>}`.
/// A plaintext that is not a JSON object, or has no `v`, is a preview from before the object
/// existed: its whole text is the body, it names no card, and it permits no button.
public struct NotificationPreviewContent: Equatable, Sendable {
    public static let version = 1

    /// The reply's text, or the card's one-line summary.
    public let body: String
    /// `threadRef` of the card or message this preview is about; nil when unknown.
    public let event: String?
    /// Whether the Mac judged this card answerable from the lock screen. Never true for a reply.
    public let quick: Bool
    /// The thread's title, shown as the notification's title; nil when the Mac sent none.
    public let title: String?

    public init(body: String, event: String?, quick: Bool, title: String? = nil) {
        self.body = body
        self.event = event
        self.quick = quick
        self.title = title
    }

    /// Nil for an empty body, which is no preview at all.
    public init?(plaintext: String) {
        let parsed = try? JSONSerialization.jsonObject(with: Data(plaintext.utf8), options: [.fragmentsAllowed])
        guard let object = parsed as? [String: Any], object["v"] != nil else {
            if plaintext.isEmpty || plaintext.utf8.count > 8_192 { return nil }
            self.init(body: plaintext, event: nil, quick: false)
            return
        }
        guard let version = object["v"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == NSNumber(value: Self.version),
              let body = object["body"] as? String, !body.isEmpty, body.utf8.count <= 8_192
        else { return nil }
        let event = (object["event"] as? String).flatMap {
            $0.isEmpty || $0.utf8.count > 128 ? nil : $0
        }
        // A JSON `true` only: NSNumber bridges numbers to Bool too, so the type is checked.
        let quick: Bool
        if let number = object["quick"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            quick = number.boolValue
        } else {
            quick = false
        }
        let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(body: body, event: event, quick: quick, title: title)
    }
}

/// Local-only opening of the preview APNs carries as an opaque ChaChaPoly box.
public enum NotificationPreview {
    private static let service = "to.yumi.yorozu.notification-preview"
    private static let account = "session-key"

    /// The preview a box holds, or nil when it does not open under `key`, is not UTF-8, or
    /// says nothing.
    public static func decrypt(nonce: String, ciphertext: String, key: SymmetricKey) -> NotificationPreviewContent? {
        guard let nonce = Data(base64URLEncoded: nonce), nonce.count == 12,
              let ciphertext = Data(base64URLEncoded: ciphertext), ciphertext.count >= 16,
              let plaintext = try? YorozuCrypto.open(key: key, nonce: nonce, ciphertext: ciphertext),
              let text = String(data: plaintext, encoding: .utf8)
        else { return nil }
        return NotificationPreviewContent(plaintext: text)
    }

    /// Shares only derived preview keys. Each host has a separate Keychain item; the
    /// notification extension never receives the app's pairing private keys.
    @discardableResult
    public static func save(key: SymmetricKey, hostID: HostID) -> Bool {
        guard !hostID.isEmpty else { return false }
        return save(key: key, account: "host:\(hostID)")
    }

    public static func loadKeys() -> [HostID: SymmetricKey] {
        guard var lookup = baseQuery else { return [:] }
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [:] }
        var keys: [HostID: SymmetricKey] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("host:"), account.count > 5,
                  let data = item[kSecValueData as String] as? Data, data.count == 32
            else { continue }
            keys[String(account.dropFirst(5))] = SymmetricKey(data: data)
        }
        return keys
    }

    public static func clearKey(hostID: HostID) {
        guard let query = query(account: "host:\(hostID)") else { return }
        SecItemDelete(query as CFDictionary)
    }

    /// Call only while migrating the known single legacy pairing, before adding other hosts.
    /// Never infer this ownership from a notification, thread reference, or last-used host.
    public static func migrateLegacyKey(to hostID: HostID) {
        guard let key = loadKey(), save(key: key, hostID: hostID) else { return }
        clearKey()
    }

    // Legacy access exists solely to migrate installations created before per-host storage.
    public static func save(key: SymmetricKey) {
        _ = save(key: key, account: account)
    }

    public static func loadKey() -> SymmetricKey? {
        guard var lookup = query(account: account) else { return nil }
        lookup[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    public static func clearKey() {
        guard let query = query(account: account) else { return }
        SecItemDelete(query as CFDictionary)
    }

    private static func save(key: SymmetricKey, account: String) -> Bool {
        guard let query = query(account: account) else { return false }
        let data = key.withUnsafeBytes { Data($0) }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func query(account: String) -> [String: Any]? {
        guard var query = baseQuery else { return nil }
        query[kSecAttrAccount as String] = account
        return query
    }

    private static var baseQuery: [String: Any]? {
        guard let accessGroup = Bundle.main.object(
            forInfoDictionaryKey: "YorozuNotificationKeychainAccessGroup"
        ) as? String else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }
}
