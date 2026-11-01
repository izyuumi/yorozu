import ActivityKit
import UserNotifications
import WidgetKit
import YorozuWire

final class NotificationService: UNNotificationServiceExtension {
    private static let titles = ["reply": "Yorozu replied.", "failed": "Yorozu needs attention.", "approval": "Yorozu needs your approval."]

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let userInfo = request.content.userInfo
        guard let key = PreviewKeychain.load(), let preview = PushPreview.open(userInfo: userInfo, key: key),
              preview.event == userInfo["event"] as? String, let fallback = Self.titles[preview.cls],
              let content = request.content.mutableCopy() as? UNMutableNotificationContent
        else { return contentHandler(request.content) }
        content.title = preview.title.flatMap { $0.isEmpty ? nil : $0 }
            ?? Bundle.main.localizedString(forKey: fallback, value: nil, table: nil)
        content.body = preview.body
        if let convId = preview.convId { content.userInfo["convId"] = convId }
        guard let convId = preview.convId, WireEvent.isId(convId), let event = Self.events[preview.cls] else { return contentHandler(content) }
        if event == .reply, WidgetStore.update({
            $0.receive(convId: convId, title: preview.title, body: preview.body, event: preview.event, at: Date(), previews: WidgetStore.previews)
        }) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        let title = preview.title
        Task {
            await Self.updateActivity(event, convId: convId, title: title)
            contentHandler(content)
        }
    }

    private static let events: [String: JobEvent] = ["reply": .reply, "failed": .failurePushed, "approval": .approval]

    /// Updates the Live Activity silently: the notification itself alerts. It can't start one.
    private static func updateActivity(_ event: JobEvent, convId: String, title: String?) async {
        guard let activity = YorozuActivityAttributes.current else { return }
        let previews = WidgetStore.previews
        var labels = ActivityLabelsStore.read()
        let jobs = activity.content.state.jobs
        let next = YorozuJobs.pushed(event, convId: convId, title: title, previews: previews, jobs: jobs, labels: &labels, now: Date())
        ActivityLabelsStore.write(labels, previews: previews)
        guard next != jobs else { return }
        await YorozuActivityAttributes.show(next, on: activity, endWhenIdle: true)
    }
}
