import UserNotifications
import YorozuWire

/// Opens the sealed preview a relay alert carries (`mutable-content: 1`, `preview {n, c}`) and shows the message's words:
/// the title names what happened from this extension's own strings, the body is the Mac's excerpt. A push without a box,
/// one that does not open under the paired Mac's key, or one whose box names another message is delivered as it came,
/// with the relay's fixed localized text (docs/ios-relay-contract.md, "Sealed previews").
final class NotificationService: UNNotificationServiceExtension {
    /// The relay `loc-key` per class: the same catalog keys the fallback body uses, worded for v2.
    private static let titles = ["reply": "Yorozu replied.", "failed": "Yorozu needs attention.", "approval": "Yorozu needs your approval."]

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let userInfo = request.content.userInfo
        guard let key = PreviewKeychain.load(), let preview = PushPreview.open(userInfo: userInfo, key: key),
              preview.event == userInfo["event"] as? String, let title = Self.titles[preview.cls],
              let content = request.content.mutableCopy() as? UNMutableNotificationContent
        else { return contentHandler(request.content) }
        content.title = Bundle.main.localizedString(forKey: title, value: nil, table: nil)
        content.body = preview.body
        contentHandler(content)
    }

    // `didReceive` answers synchronously, so the deadline never finds it waiting; the system then shows the push as sent.
}
