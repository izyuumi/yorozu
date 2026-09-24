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
        // not open was not written by the Mac, and gets no say on the lock screen. The
        // category `aps` named is never read back: which buttons a card gets is sealed inside
        // the preview by the Mac, not chosen by the relay.
        content.title = NotificationFallback.title
        content.subtitle = ""
        content.body = NotificationFallback.body
        content.categoryIdentifier = ""
        content.interruptionLevel = .active
        content.userInfo.removeValue(forKey: NotificationFallback.localHostKey)
        bestAttemptContent = content
        if let match = NotificationFallback.authenticatedPreview(
            userInfo: content.userInfo, keys: NotificationPreview.loadKeys()
        ) {
            let preview = match.preview
            content.userInfo[NotificationFallback.localHostKey] = match.hostID
            content.body = preview.body
            // Sealed by the Mac alongside the body, so it is as trustworthy as the words under it.
            if let title = preview.title { content.title = title }
            // Allow and Deny appear only when the Mac sealed `quick` into the preview and the
            // preview names the card this push is about. The app checks the same thing again
            // before an Allow counts — see `PushDelegate` and
            // `NotificationFallback.permitsLockScreenAnswer`.
            content.categoryIdentifier = NotificationFallback.category(
                for: preview, eventRef: content.userInfo["event"] as? String
            )
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
