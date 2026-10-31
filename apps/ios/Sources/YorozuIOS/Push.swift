import AppIntents
import SwiftUI
import UserNotifications
import YorozuWire

@MainActor
final class AppDelegate: NSObject, UNUserNotificationCenterDelegate {
    let model = AppModel()

    override init() {
        super.init()
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
            guard !model.isDemo else { return [] }
            guard model.active else { return [.banner, .list, .sound] }
            if let convId = model.conversation(convId: id, ref: ref) { model.showNotice(for: convId, title: title, body: body) }
            return []
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let (id, ref) = Self.names(response.notification)
        await MainActor.run {
            guard !model.isDemo else { return }
            if let convId = model.conversation(convId: id, ref: ref) { model.requestedConversation = convId }
        }
    }

    private nonisolated static func names(_ notification: UNNotification) -> (String?, String?) {
        let userInfo = notification.request.content.userInfo
        return (userInfo["convId"] as? String, userInfo["ref"] as? String)
    }
}

#if os(iOS)
extension AppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        launched()
        if !model.isDemo { application.registerForRemoteNotifications() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.registerPush(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await model.backgroundWake()
        return .newData
    }
}
#else
extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { launched() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasUnsent else { return .terminateNow }
        Task {
            _ = await model.waitUntilSent(limit: .seconds(10))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif

@MainActor
enum Notices {
    static func reply(convId: String, title: String, text: String) {
        let content = UNMutableNotificationContent()
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        content.title = String(title.prefix(80))
        content.body = String((line ?? "").prefix(180))
        content.threadIdentifier = YorozuCrypto.threadRef(convId)
        content.userInfo = ["convId": convId]
        if lastSound[convId].map({ $0.timeIntervalSinceNow < -10 }) ?? true {
            content.sound = .default
            lastSound[convId] = Date()
        }
        let request = UNNotificationRequest(identifier: "reply:\(convId)", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    private static var lastSound: [String: Date] = [:]

    private static let deliverySlack: TimeInterval = 15

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
    func opensRequestedConversation(_ model: AppModel, selection: Binding<String?>) -> some View {
        onChange(of: model.requestedConversation, initial: true) { _, convId in
            guard let convId else { return }
            selection.wrappedValue = convId
            model.requestedConversation = nil
        }
    }
}
