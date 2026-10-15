import SwiftUI
import UserNotifications
import YorozuWire

/// Notifications for finished replies (#431; docs/ios-relay-contract.md, "Push"). The app delegate owns the one
/// ``V3Model``, so a notification reaches it with no scene on screen. iPhone and iPad: the APNs token for the relay,
/// whose alert the notification service extension fills from the sealed preview. Mac: a local notice per reply while
/// the app runs (`V3Notices.reply`). Either way, none for the conversation on screen, and a tap opens its conversation.
@MainActor
final class V3AppDelegate: NSObject, UNUserNotificationCenterDelegate {
    let model = V3Model()

    fileprivate func launched() {
        UNUserNotificationCenter.current().delegate = self
        model.requestNotifications()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let (id, ref) = Self.names(notification)
        return await MainActor.run {
            let convId = model.conversation(convId: id, ref: ref)
            return convId != nil && convId == model.foreground ? [] : [.banner, .list, .sound]
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let (id, ref) = Self.names(response.notification)
        await MainActor.run {
            if let convId = model.conversation(convId: id, ref: ref) { model.requestedConversation = convId }
        }
    }

    /// The preview's `convId` and the relay's `ref`.
    private nonisolated static func names(_ notification: UNNotification) -> (String?, String?) {
        let userInfo = notification.request.content.userInfo
        return (userInfo["convId"] as? String, userInfo["ref"] as? String)
    }
}

#if os(iOS)
extension V3AppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        launched()
        // Every launch: a restore or an OS update can change the token.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.registerPush(deviceToken.map { String(format: "%02x", $0) }.joined())
    }
}
#else
extension V3AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { launched() }
}
#endif

@MainActor
enum V3Notices {
    /// Mac: a reply in a conversation not in front. One notice per conversation, replaced by its next reply, so a
    /// reply that came in several chunks alerts once; grouped like the relay's (`thread-id` is its `ref`).
    static func reply(convId: String, title: String, text: String) {
        let content = UNMutableNotificationContent()
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        content.title = title.isEmpty ? String(localized: "Yorozu replied.") : String(title.prefix(80))
        content.body = String((line ?? "").prefix(180))
        content.threadIdentifier = YorozuCrypto.threadRef(convId)
        content.userInfo = ["convId": convId]
        // Several chunks of one reply arrive together: only the first one sounds.
        if lastSound[convId].map({ $0.timeIntervalSinceNow < -10 }) ?? true {
            content.sound = .default
            lastSound[convId] = Date()
        }
        let request = UNNotificationRequest(identifier: "reply:\(convId)", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    private static var lastSound: [String: Date] = [:]

    /// The conversation is open: its delivered notifications go.
    static func removeDelivered(convId: String) {
        let ref = YorozuCrypto.threadRef(convId)
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications()
                .filter { $0.request.content.threadIdentifier == ref || $0.request.content.userInfo["convId"] as? String == convId }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }
}

extension View {
    /// Opens the conversation a tapped notification names.
    func opensRequestedConversation(_ model: V3Model, selection: Binding<String?>) -> some View {
        onChange(of: model.requestedConversation, initial: true) { _, convId in
            guard let convId else { return }
            selection.wrappedValue = convId
            model.requestedConversation = nil
        }
    }
}
