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
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
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
        // Nothing paired: woken for a room this phone no longer belongs to.
        guard let model = await MainActor.run(body: { Session.shared.model }) else { return .noData }
        return await model.drain() ? .newData : .noData
    }

    /// A notification that arrives while the app is open has nothing to say: the socket is live,
    /// so the event itself is already in the chat. Shown as nothing rather than as a duplicate.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let ref = info["ref"] as? String else { return }
        let notificationClass = info["cls"] as? String
        let eventRef = info["event"] as? String
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
