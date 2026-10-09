import UIKit
import UserNotifications

/// APNs (#320): the device token for the relay, the silent catch-up, foreground presentation and taps. It owns
/// the one `PhoneModel`, so a push reaches it with no scene on screen. A push carries a fixed title, a `loc-key`
/// body and two opaque refs, never content.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = PhoneModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Every launch: a restore or an OS update can change the token.
        application.registerForRemoteNotifications()
        // The phone cannot see the Mac's destination, so a paired phone is asked here as well as at #314's
        // first queued message; iOS shows the prompt only once.
        if model.linked { LocalNotices.requestPermission() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.registerPush(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        model.pushFailed(error.localizedDescription)
    }

    /// The relay's silent push (`content-available`): catch up in the background. In the foreground, inactive
    /// included, the link is already up.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard application.applicationState == .background else { return .noData }
        return await model.wake() ? .newData : .noData
    }

    /// No banner over the main timeline; one anywhere else. #314's local notices stay unshown in the foreground.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard notification.request.trigger is UNPushNotificationTrigger else { return [] }
        return await model.mainShown ? [] : [.banner, .list, .sound]
    }

    /// A tapped push opens the main timeline at its `event` message.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.trigger is UNPushNotificationTrigger else { return }
        let ref = response.notification.request.content.userInfo["event"] as? String
        await model.open(pushEvent: ref)
    }
}

@MainActor
enum PushNotices {
    /// The last update; each waits for the one before, so the latest badge wins.
    private static var last: Task<Void, Never>?

    /// Sets the badge, and removes the delivered pushes whose `event` ref is in `read`.
    static func update(badge: Int, read: Set<String>?) {
        let previous = last
        last = Task {
            await previous?.value
            let center = UNUserNotificationCenter.current()
            try? await center.setBadgeCount(badge)
            guard let read else { return }
            let ids = await center.deliveredNotifications()
                .filter { ($0.request.content.userInfo["event"] as? String).map(read.contains) == true }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// In the foreground the Mac is plainly back: its delivered back-online pushes (relay class `done`) go.
    static func removeBackOnline() {
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications()
                .filter { $0.request.content.userInfo["cls"] as? String == "done" }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }
}
