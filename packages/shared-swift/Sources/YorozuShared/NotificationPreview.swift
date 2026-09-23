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
              let ciphertext = preview["c"] as? String else { return nil }
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

    public init(body: String, event: String?, quick: Bool) {
        self.body = body
        self.event = event
        self.quick = quick
    }

    /// Nil for an empty body, which is no preview at all.
    public init?(plaintext: String) {
        let parsed = try? JSONSerialization.jsonObject(with: Data(plaintext.utf8), options: [.fragmentsAllowed])
        guard let object = parsed as? [String: Any], object["v"] != nil else {
            if plaintext.isEmpty { return nil }
            self.init(body: plaintext, event: nil, quick: false)
            return
        }
        guard let body = object["body"] as? String, !body.isEmpty else { return nil }
        let event = (object["event"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // A JSON `true` only: NSNumber bridges numbers to Bool too, so the type is checked.
        let quick: Bool
        if let number = object["quick"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            quick = number.boolValue
        } else {
            quick = false
        }
        self.init(body: body, event: event, quick: quick)
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

    /// Shares only the derived symmetric key with the notification extension. Pairing private
    /// keys stay in the app's original, unshared Keychain group.
    public static func save(key: SymmetricKey) {
        guard let query else { return }
        let data = key.withUnsafeBytes { Data($0) }
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public static func loadKey() -> SymmetricKey? {
        guard let query else { return nil }
        var lookup = query
        lookup[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    public static func clearKey() {
        guard let query else { return }
        SecItemDelete(query as CFDictionary)
    }

    private static var query: [String: Any]? {
        guard let accessGroup = Bundle.main.object(
            forInfoDictionaryKey: "YorozuNotificationKeychainAccessGroup"
        ) as? String else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }
}
