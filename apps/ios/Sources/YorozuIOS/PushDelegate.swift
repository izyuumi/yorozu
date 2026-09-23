import UIKit
import UserNotifications
import YorozuShared

/// The app's end of APNs: hands the device token to the session, and turns a tapped
/// notification into the thread it was about.
///
/// A notification carries an opaque reference and a class, never the thread id and never a word
/// of the conversation — so opening the right chat is a lookup this phone does against the
/// threads it already holds. See ``Session/open(threadRef:)``.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// The categories an approval push names, and the buttons each draws. `approval-quick` is
    /// what the Mac sends when the action is below every floor and commits nothing external;
    /// everything else gets `approval-review`, whose only button opens the card.
    static let quickCategory = "approval-quick"
    static let reviewCategory = "approval-review"
    static let allowAction = "approval.allow"
    static let denyAction = "approval.deny"
    static let reviewAction = "approval.review"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(
            identifier: Self.allowAction,
            title: String(localized: "Allow"),
            options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: Self.denyAction,
            title: String(localized: "Don't allow"),
            options: [.authenticationRequired, .destructive]
        )
        let review = UNNotificationAction(
            identifier: Self.reviewAction,
            title: String(localized: "Review"),
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.quickCategory, actions: [allow, deny, review], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.reviewCategory, actions: [review], intentIdentifiers: []),
        ])
        // Every launch, as Apple asks: the token can change with a restore or an OS update, and
        // a token the relay was never told is a phone it cannot wake. Permission is a separate
        // question — ``Session/requestNotifications()`` — and the silent catch-up needs none.
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in Session.shared.registerPush(deviceToken: hex) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Nothing to do but carry on unwoken: the app works, it just will not buzz. Registering
        // is retried on the next launch, which is when this most often fixes itself.
        Task { @MainActor in Session.shared.pushFailure = error.localizedDescription }
    }

    /// The relay's silent push: something landed that this phone is behind on, and the app is
    /// suspended. It carries nothing to read — the catching up is done over the socket, where
    /// the events are sealed — so this only sends the model to ask, and hangs up after.
    ///
    /// See ``ChatModel/drain(timeout:)``, which is where the waiting and the hanging up live.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        // On screen, the socket is already open and being read: a drain here would hang it up
        // and leave the app sitting disconnected until the next foreground.
        guard application.applicationState != .active else { return .noData }
        // Nothing paired: woken for a room this phone no longer belongs to.
        guard let model = await MainActor.run(body: { Session.shared.model }) else { return .noData }
        return await model.drain() ? .newData : .noData
    }

    /// Suppress only a notification for the chat visibly being read. A live socket does not mean
    /// somebody watching another chat, the thread list, or Settings saw what arrived.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let ref = notification.request.content.userInfo["ref"] as? String
        let reading = await MainActor.run {
            ref.map { Session.shared.model?.isReading(threadRef: $0) == true } ?? false
        }
        return reading ? [] : [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let ref = info["ref"] as? String else { return }
        let notificationClass = info["cls"] as? String
        let eventRef = info["event"] as? String

        // A button, not a tap: answer the card without bringing the app forward. The phone
        // was just unlocked to press it, and the answer is the same `approval_answer` the card
        // would send. A card that cannot be found is left for the app to show.
        //
        // Only when the words the buttons were pressed under are the Mac's, though: the sealed
        // preview in this push opens, under this phone's key, to exactly the body that was on
        // screen. Anything else — a relay's own sentence, a box that will not open, no box —
        // is no approval of anything, and the tap just opens the card instead. Checked here
        // rather than trusted from `userInfo`, which the relay writes.
        let answer: ApprovalAnswerData.Answer? = switch response.actionIdentifier {
        case Self.allowAction: .yes
        case Self.denyAction: .no
        default: nil
        }
        let content = response.notification.request.content
        if let answer, let eventRef,
           NotificationFallback.showsDecryptedPreview(
               body: content.body, userInfo: info, key: NotificationPreview.loadKey()
           ) {
            guard let model = await MainActor.run(body: { Session.shared.model }) else { return }
            if await model.answerFromNotification(eventRef: eventRef, answer) { return }
        }
        let model = await MainActor.run { () -> ChatModel? in
            let session = Session.shared
            session.open(threadRef: ref, notificationClass: notificationClass, eventRef: eventRef)
            return session.model
        }
        // Opened from a lock screen, so what this phone holds of that thread is whatever it had
        // before the push. Ask for the rest now rather than leaving the chat to be pulled down.
        await model?.refresh()
    }
}
