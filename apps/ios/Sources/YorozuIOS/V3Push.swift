import AppIntents
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

    override init() {
        super.init()
        // The same model for Siri and Shortcuts (YorozuIntents.swift), before any intent can run.
        let model = model
        AppDependencyManager.shared.add(dependency: model)
    }

    fileprivate func launched() {
        UNUserNotificationCenter.current().delegate = self
        SpotlightIndexer.start(model: model)
        model.requestNotifications()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let (id, ref) = Self.names(notification)
        let content = notification.request.content
        let (title, body) = (content.title, content.body)
        return await MainActor.run {
            // The app is in front: no system banner, the in-app notice (a push sent before the plugin heard).
            guard model.active else { return [.banner, .list, .sound] }
            if let convId = model.conversation(convId: id, ref: ref) { model.showNotice(for: convId, title: title, body: body) }
            return []
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

    /// The relay's silent push: after a reply, or a conversation read on another device (`sync`). A short connection
    /// brings the read cursors, which clear what was read.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await model.backgroundWake()
        return .newData
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

    /// Delivery lags the reply's own time (plugin clock) by this much at most; a later alert is a newer reply.
    private static let deliverySlack: TimeInterval = 15

    /// The conversation's delivered notifications go: all of them when it is open, or (`readUpTo`, a read cursor's
    /// `ts` in epoch ms, read here or on another device) those delivered by the time of the reply it was read at.
    static func removeDelivered(convId: String, readUpTo: Int64? = nil) {
        let ref = YorozuCrypto.threadRef(convId)
        let cutoff = readUpTo.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000 + deliverySlack) }
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications()
                .filter { $0.request.content.threadIdentifier == ref || $0.request.content.userInfo["convId"] as? String == convId }
                .filter { note in cutoff.map { note.date <= $0 } ?? true }
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
