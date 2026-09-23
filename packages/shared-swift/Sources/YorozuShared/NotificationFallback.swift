import CryptoKit
import Foundation

/// What the notification service extension and the app agree on about a push whose preview
/// could not be opened. One place for both, because the two are separate targets that share
/// nothing but this package.
public enum NotificationFallback {
    /// The title every alert carries. The relay writes one too — `aps.alert.title` — and the
    /// preview never supplies one, so the extension overwrites it with this on both paths.
    public static let title = "Yorozu"

    /// Shown instead of whatever body the relay wrote when the preview box is missing or does
    /// not decrypt. Fixed text, so an unauthenticated push can put no words on the lock screen.
    public static let body = "New activity"

    /// Whether the words a notification was delivered with are the Mac's: the sealed preview it
    /// carries opens under this device's key to exactly the body on screen. That is the one
    /// test Allow and Deny may act on. A mark left in `userInfo` would not do — `userInfo` is
    /// the relay's to write, and a push sent without `mutable-content` never reaches the
    /// extension at all — so the app opens the box itself and compares. A relay that replays a
    /// real box under a sentence of its own fails it: it cannot know what the box says.
    public static func showsDecryptedPreview(
        body: String, userInfo: [AnyHashable: Any], key: SymmetricKey?
    ) -> Bool {
        guard let key,
              let preview = NotificationPreviewPayload(userInfo: userInfo),
              let plaintext = NotificationPreview.decrypt(
                  nonce: preview.nonce, ciphertext: preview.ciphertext, key: key
              )
        else { return false }
        return plaintext == body
    }
}
