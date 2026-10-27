import UserNotifications
import YorozuWire

final class NotificationService: UNNotificationServiceExtension {
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
}
