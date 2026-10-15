import UserNotifications
import YorozuWire

/// Opens the sealed preview a relay alert carries (`mutable-content: 1`, `preview {n, c}`) and shows the reply's words:
/// the conversation's title (else the class's alert text from this extension's own strings) and the reply's first line,
/// and copies the conversation id for the tap to open (#431). A push without a box, one that does not open under the
/// host's key, or one whose box names another message is delivered as it came, with the relay's fixed localized text
/// (docs/ios-relay-contract.md, "Push").
final class NotificationService: UNNotificationServiceExtension {
    /// The relay `loc-key` per class: the same catalog keys the fallback body uses.
    private static let titles = ["reply": "Yorozu replied.", "failed": "Yorozu needs attention.", "approval": "Yorozu needs your approval."]

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let userInfo = request.content.userInfo
        guard let key = PreviewKeychain.load(), let preview = PushPreview.open(userInfo: userInfo, key: key),
              preview.event == userInfo["event"] as? String, let fallback = Self.titles[preview.cls],
              let content = request.content.mutableCopy() as? UNMutableNotificationContent
        else { return contentHandler(request.content) }
        content.title = preview.title.flatMap { $0.isEmpty ? nil : $0 }
            ?? Bundle.main.localizedString(forKey: fallback, value: nil, table: nil)
        content.body = preview.body
        if let convId = preview.convId { content.userInfo["convId"] = convId }
        contentHandler(content)
    }

    // `didReceive` answers synchronously, so the deadline never finds it waiting; the system then shows the push as sent.
}
