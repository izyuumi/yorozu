#if os(iOS)
import ActivityKit
import Foundation

/// The app's one Live Activity. Nothing static; the state is opaque job tokens, kinds, states, step counts
/// and times (`YorozuActivityState`), labelled on the device from `ActivityLabels`.
struct YorozuActivityAttributes: ActivityAttributes {
    typealias ContentState = YorozuActivityState

    /// The running activity, if any.
    static var current: Activity<Self>? {
        Activity<Self>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    static func endAll() async {
        for activity in Activity<Self>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Shows `jobs` on `activity`: ends it when none are left and updates it otherwise. With `endWhenIdle`
    /// (nobody left to run a timer) and nothing running, it ends too and the system dismisses it once the
    /// last finished row lingered. False when the activity ended.
    @discardableResult
    static func show(_ jobs: [YorozuJob], on activity: Activity<Self>, alert: AlertConfiguration? = nil,
                     endWhenIdle: Bool, now: Date = Date()) async -> Bool {
        let content = ActivityContent(state: YorozuActivityState(jobs: jobs), staleDate: YorozuJobs.staleDate(jobs, now: now))
        if YorozuJobs.shouldEnd(jobs) {
            await activity.end(nil, dismissalPolicy: .immediate)
            return false
        }
        let until = endWhenIdle ? YorozuJobs.dismissal(jobs) : nil
        if until == nil || alert != nil { await activity.update(content, alertConfiguration: alert) }
        guard let until else { return true }
        await activity.end(content, dismissalPolicy: .after(until))
        return false
    }
}
#endif
