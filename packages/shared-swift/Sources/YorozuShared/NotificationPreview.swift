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

/// Local-only opening of the reply text APNs carries as an opaque ChaChaPoly box.
public enum NotificationPreview {
    private static let service = "to.yumi.yorozu.notification-preview"
    private static let account = "session-key"

    public static func decrypt(nonce: String, ciphertext: String, key: SymmetricKey) -> String? {
        guard let nonce = Data(base64URLEncoded: nonce), nonce.count == 12,
              let ciphertext = Data(base64URLEncoded: ciphertext), ciphertext.count >= 16,
              let plaintext = try? YorozuCrypto.open(key: key, nonce: nonce, ciphertext: ciphertext)
        else { return nil }
        return String(data: plaintext, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
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
