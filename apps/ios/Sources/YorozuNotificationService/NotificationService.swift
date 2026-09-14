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
        if let preview = NotificationPreviewPayload(userInfo: content.userInfo),
           let key = NotificationPreview.loadKey(),
           let body = NotificationPreview.decrypt(
               nonce: preview.nonce,
               ciphertext: preview.ciphertext,
               key: key
           ) {
            content.body = body
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent { contentHandler(bestAttemptContent) }
    }
}
