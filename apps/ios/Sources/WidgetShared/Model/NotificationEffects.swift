import Foundation

/// What a decrypted notification should cause: a widget snapshot update, an activity write, a labels write.
struct NotificationEffects: Equatable, Sendable {
    var updatesWidget: Bool
    /// The jobs to show, or nil for no activity write.
    var activity: [YorozuJob]? = nil
    /// The labels to write, or nil for no labels write.
    var labels: ActivityLabels? = nil

    static func of(_ cls: String, convId: String, jobs: [YorozuJob] = [], labels: ActivityLabels = ActivityLabels())
        -> NotificationEffects {
        let event: JobEvent? = ["reply": .reply, "failed": .failurePushed, "approval": .approval][cls]
        guard let event else { return NotificationEffects(updatesWidget: false) }
        var labels = labels
        let next = YorozuJobs.pushed(event, convId: convId, title: nil, previews: false, jobs: jobs, labels: &labels, now: Date())
        return NotificationEffects(updatesWidget: cls == "reply", activity: next, labels: labels)
    }
}
