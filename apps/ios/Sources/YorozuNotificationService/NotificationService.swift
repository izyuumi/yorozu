import UserNotifications
import YorozuShared

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return contentHandler(request.content)
        }
        bestAttemptContent = content
        if let preview = content.userInfo["preview"] as? [String: Any],
           let nonce = preview["n"] as? String,
           let ciphertext = preview["c"] as? String,
           let key = NotificationPreview.loadKey(),
           let body = NotificationPreview.decrypt(nonce: nonce, ciphertext: ciphertext, key: key) {
            content.body = body
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent { contentHandler(bestAttemptContent) }
    }
}
