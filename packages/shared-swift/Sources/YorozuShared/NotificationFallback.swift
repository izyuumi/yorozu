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

    /// The categories an approval push may carry, and the buttons each draws. Fixed vocabulary
    /// shared by the app, which registers them, and the extension, which sets them.
    /// `approval-quick` draws Allow and Deny; `approval-review` only opens the card.
    public static let quickCategory = "approval-quick"
    public static let reviewCategory = "approval-review"

    /// The preview in a push, opened under this device's key. Nil when there is no key, no box,
    /// or the box will not open: the push was not written by the Mac.
    public static func decryptedPreview(
        userInfo: [AnyHashable: Any], key: SymmetricKey?
    ) -> NotificationPreviewContent? {
        guard let key, let preview = NotificationPreviewPayload(userInfo: userInfo) else { return nil }
        return NotificationPreview.decrypt(nonce: preview.nonce, ciphertext: preview.ciphertext, key: key)
    }

    /// The category a delivered push gets. Allow and Deny are drawn only when the Mac sealed
    /// `quick` into the preview *and* the preview names the card the push is about — the
    /// `event` reference the app will answer. `aps.category` is the relay's and is never read;
    /// everything else is delivered with no buttons at all.
    public static func category(for preview: NotificationPreviewContent?, eventRef: String?) -> String {
        guard let preview, preview.quick, let event = preview.event, let eventRef, event == eventRef
        else { return "" }
        return quickCategory
    }

    /// The preview a notification was delivered under, if the words on screen are the Mac's:
    /// the sealed preview it carries opens under this device's key to exactly the body shown.
    /// That is the one test Allow and Deny may act on. A mark left in `userInfo` would not do —
    /// `userInfo` is the relay's to write, and a push sent without `mutable-content` never
    /// reaches the extension at all — so the app opens the box itself and compares. A relay
    /// that replays a real box under a sentence of its own fails it: it cannot know what the
    /// box says.
    public static func showsDecryptedPreview(
        body: String, userInfo: [AnyHashable: Any], key: SymmetricKey?
    ) -> NotificationPreviewContent? {
        guard let preview = decryptedPreview(userInfo: userInfo, key: key), preview.body == body
        else { return nil }
        return preview
    }

    /// Whether a lock-screen Allow or Deny may answer the card `eventRef` names: the preview
    /// re-opens to the body on screen, the Mac judged the card quick, and the preview is about
    /// this very card. The buttons the relay drew are not consulted.
    public static func permitsLockScreenAnswer(
        body: String, userInfo: [AnyHashable: Any], key: SymmetricKey?, eventRef: String?
    ) -> Bool {
        guard let preview = showsDecryptedPreview(body: body, userInfo: userInfo, key: key),
              preview.quick, let event = preview.event, let eventRef
        else { return false }
        return event == eventRef
    }
}
