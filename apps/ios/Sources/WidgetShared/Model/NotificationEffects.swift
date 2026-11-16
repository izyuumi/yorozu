import Foundation

/// What a push the notification service decrypted causes. A reply updates the widget snapshot; the Live
/// Activity and its labels are left to the host and the app, whatever the activity's jobs and labels are.
struct NotificationEffects: Equatable, Sendable {
    var updatesWidget: Bool
    /// The jobs to show, or nil for no activity write.
    var activity: [YorozuJob]? = nil
    /// The labels to write, or nil for no labels write.
    var labels: ActivityLabels? = nil

    static func of(_ cls: String, convId: String, jobs: [YorozuJob] = [], labels: ActivityLabels = ActivityLabels())
        -> NotificationEffects {
        NotificationEffects(updatesWidget: cls == "reply")
    }
}
