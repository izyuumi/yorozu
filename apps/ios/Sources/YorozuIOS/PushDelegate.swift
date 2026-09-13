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
        await MainActor.run { Session.shared.open(threadRef: ref) }
    }
}
