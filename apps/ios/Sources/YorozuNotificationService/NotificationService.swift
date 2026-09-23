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
        // The relay's own words and its buttons come off first, so that whatever is delivered
        // — here, or by the deadline in `serviceExtensionTimeWillExpire` — is either the
        // decrypted preview or a fixed line with nothing to press. Title and subtitle are the
        // relay's to write as much as the body is, and the preview never supplies them, so
        // they are fixed on both paths; the interruption level goes back to the default so a
        // push cannot make itself time-sensitive either. A push whose box is missing or will
        // not open was not written by the Mac, and gets no say on the lock screen.
        let category = content.categoryIdentifier
        content.title = NotificationFallback.title
        content.subtitle = ""
        content.body = NotificationFallback.body
        content.categoryIdentifier = ""
        content.interruptionLevel = .active
        bestAttemptContent = content
        if let preview = NotificationPreviewPayload(userInfo: content.userInfo),
           let key = NotificationPreview.loadKey(),
           let body = NotificationPreview.decrypt(
               nonce: preview.nonce,
               ciphertext: preview.ciphertext,
               key: key
           ) {
            content.body = body
            // The buttons come back only under the Mac's words. The app checks the same thing
            // again before an Allow counts — see `PushDelegate` and
            // `NotificationFallback.showsDecryptedPreview`.
            content.categoryIdentifier = category
        }
        deliver(content)
    }

    override func serviceExtensionTimeWillExpire() {
        // Out of time: what goes out is the neutralised copy, never the relay's original.
        if let bestAttemptContent { deliver(bestAttemptContent) }
    }

    /// Once: the handler is dropped after use, so the deadline firing after a normal delivery
    /// has nothing to call twice.
    private func deliver(_ content: UNNotificationContent) {
        contentHandler?(content)
        contentHandler = nil
    }
}
