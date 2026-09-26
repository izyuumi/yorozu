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
    /// what the extension sets when the Mac sealed its quick judgement into the preview — the
    /// action is below every floor and commits nothing external; everything else gets
    /// `approval-review`, whose only button opens the card, or no category at all.
    static let quickCategory = NotificationFallback.quickCategory
    static let reviewCategory = NotificationFallback.reviewCategory
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
        let models = await MainActor.run { Session.shared.hosts.sessions.map(\.model) }
        return await withTaskGroup(of: Bool.self) { group in
            for model in models { group.addTask { await model.drain() } }
            var changed = false
            for await result in group { changed = changed || result }
            return changed ? .newData : .noData
        }
    }

    /// Suppress only a notification for the chat visibly being read. A live socket does not mean
    /// somebody watching another chat, the thread list, or Settings saw what arrived.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        let (reading, waitForLegacy) = await MainActor.run {
            let session = Session.shared
            if let destination = session.authenticatedNotificationDestination(userInfo: info) {
                return (session.hosts.session(for: destination.hostID)?.model.isReading(threadRef: destination.threadRef) == true, false)
            }
            // An older host sealed the event but not its thread. The relay's `ref` may only
            // decide whether to wait for that event's sync; it never decides suppression.
            guard let match = NotificationFallback.authenticatedPreview(userInfo: info, keys: session.notificationKeys),
                  match.preview.thread == nil, match.preview.event != nil,
                  let hint = info["ref"] as? String,
                  session.hosts.session(for: match.hostID)?.model.isReading(threadRef: hint) == true
            else { return (false, false) }
            return (false, true)
        }
        if reading { return [] }
        if waitForLegacy {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                let resolved = await MainActor.run { () -> Bool? in
                    let session = Session.shared
                    guard let destination = session.authenticatedNotificationDestination(userInfo: info) else { return nil }
                    return session.hosts.session(for: destination.hostID)?.model.isReading(threadRef: destination.threadRef) == true
                }
                if let resolved { return resolved ? [] : [.banner, .list, .sound] }
            }
        }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let rawEventRef = info["event"] as? String

        // A button, not a tap: answer the card without bringing the app forward. The phone
        // was just unlocked to press it, and the answer is the same `approval_answer` the card
        // would send. A card that cannot be found is left for the app to show.
        //
        // Only when the words the buttons were pressed under are the Mac's, though: the sealed
        // preview in this push opens, under this phone's key, to exactly the body that was on
        // screen, names this very card, and carries the Mac's own judgement that the card may
        // be answered from a button. Anything else — a relay's own sentence, a box that will
        // not open, no box, a box about another card, a card the Mac sent for review — is no
        // approval of anything, and the tap just opens the card instead. Checked here rather
        // than trusted from `userInfo` or the category, which the relay writes.
        let answer: ApprovalAnswerData.Answer? = switch response.actionIdentifier {
        case Self.allowAction: .yes
        case Self.denyAction: .no
        default: nil
        }
        let content = response.notification.request.content
        let (destination, legacy, actionModel) = await MainActor.run {
            () -> (AuthenticatedNotificationDestination?, (HostID, String)?, ChatModel?) in
            // Initialize migration, verify the current key and capture its model without an
            // actor hop between them: a concurrent repair cannot switch the approved session.
            let session = Session.shared
            let keys = session.notificationKeys
            let preview = NotificationFallback.authenticatedPreview(userInfo: info, keys: keys)
            let destination = session.authenticatedNotificationDestination(userInfo: info)
            let legacy = destination == nil ? preview.flatMap { match in
                match.preview.event.map { (match.hostID, $0) }
            } : nil
            let permittedHostID = answer == nil ? nil : NotificationFallback.permittedLockScreenHost(
                body: content.body, userInfo: info, keys: keys, eventRef: rawEventRef
            )
            return (destination, legacy, permittedHostID.flatMap { session.hosts.session(for: $0)?.model })
        }
        if let answer, let rawEventRef, let actionModel,
           await actionModel.answerFromNotification(eventRef: rawEventRef, answer) { return }
        let models = await MainActor.run { () -> [ChatModel] in
            let session = Session.shared
            if let destination {
                session.open(threadRef: destination.threadRef, hostID: destination.hostID,
                    notificationClass: destination.notificationClass, eventRef: destination.eventRef)
                return session.hosts.session(for: destination.hostID).map { [$0.model] } ?? []
            }
            if let (hostID, eventRef) = legacy {
                session.openLegacyNotification(hostID: hostID, eventRef: eventRef)
                return session.hosts.session(for: hostID).map { [$0.model] } ?? []
            }
            // Old or unauthenticated pushes may wake a refresh, but cannot choose a chat.
            return session.hosts.sessions.map(\.model)
        }
        await withTaskGroup(of: Void.self) { group in
            for model in models { group.addTask { await model.refresh() } }
        }
    }
}
