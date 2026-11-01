#if os(iOS)
import ActivityKit
import Foundation
import UIKit
import os

/// The app's one Live Activity (`YorozuActivityAttributes`) and its jobs, from any source:
///
/// - Turns follow `model.awaitingReply` with the tool step count. In the app the conversation shows a turn,
///   so turns alone start the activity only at `leaving()`, and `returned()` ends it.
/// - Recording and transcription (voice input, later): `upsert(YorozuJob(kind: .recording, startedAt:),
///   convId:)` when recording starts, `upsert` the same token as `.transcribing` when it stops, then
///   `finish(id:state: .done, alert: .transcriptReady)` with the transcript, `.recordingCap` when the length
///   limit stopped it, or `finish(id:state: .failed, alert: .localFailure)`. They start the activity in the
///   app and keep it on return; background audio keeps the app, and so the updates, alive while recording.
/// - The notification service marks turns done or failed and adds approvals (`YorozuJobs.pushed`).
///
/// ActivityKit starts an activity only while the app is in front; until then the jobs wait in memory.
/// Finished jobs linger `YorozuJobs.linger` as tap targets, then go; no jobs, no activity.
@MainActor
final class YorozuActivities {
    static let enabledKey = "turnLiveActivity"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private(set) static var shared: YorozuActivities?
    static func start(model: AppModel) {
        guard shared == nil else { return }
        let shared = YorozuActivities(model: model)
        Self.shared = shared
        shared.enqueue { await YorozuActivityAttributes.endAll() }
        shared.watcher = Task { await shared.watch() }
    }

    private let model: AppModel
    private var activity: Activity<YorozuActivityAttributes>?
    /// The jobs while no activity runs; with one, its content state is the truth (the notification service changes it too).
    private var jobs: [YorozuJob] = []
    /// Running turns by conversation, as last posted.
    private var turns: [String: YorozuJob] = [:]
    private var watcher: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var queue: Task<Void, Never>?
    private var leavingNow = false

    private init(model: AppModel) { self.model = model }

    private var available: Bool { Self.enabled && !model.isDemo && ActivityAuthorizationInfo().areActivitiesEnabled }
    private var inFront: Bool { UIApplication.shared.applicationState == .active }

    // MARK: Job sources

    /// Adds or replaces a job; `convId` is where its row opens, the title is stored only while previews are on.
    func upsert(_ job: YorozuJob, convId: String? = nil, title: String? = nil) {
        guard available else { return }
        ActivityLabelsStore.update { $0.upsert(token: job.token, convId: convId, kind: job.kind, title: title, previews: WidgetStore.previews) }
        apply(.upsert(job))
    }

    func finish(id token: String, state: YorozuJob.State, alert: JobEvent.Alert? = nil) {
        apply(.finish(token: token, state: state), alert: alert)
    }

    func remove(id token: String) { apply(.remove(token: token)) }

    // MARK: App lifecycle

    /// The app is leaving the foreground, the last moment ActivityKit lets it start an activity.
    func leaving() {
        syncTurns()
        leavingNow = true
        apply(nil)
        enqueue { [weak self] in self?.leavingNow = false }
    }

    /// Back in the app: the conversation shows turns and approvals, so only recording and transcription stay.
    func returned() {
        enqueue { [weak self] in
            guard let self else { return }
            let jobs = await current()
            guard !YorozuJobs.keepsActivityInApp(jobs) else { return }
            self.jobs = jobs.filter { !$0.finished && $0.kind != .needsYou }
            if let activity { await activity.end(nil, dismissalPolicy: .immediate) }
            activity = nil
            prune(self.jobs)
        }
    }

    /// Previews were turned off: drop the stored titles.
    func previewsChanged() { ActivityLabelsStore.update { _ in } }

    // MARK: Turns

    private func watch() async {
        while !Task.isCancelled {
            syncTurns()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let once = ResumeOnce(done)
                withObservationTracking { _ = model.conversations; _ = model.typing } onChange: { once.resume() }
                Task { try? await Task.sleep(for: .seconds(30)); once.resume() }
            }
        }
    }

    private func syncTurns() {
        guard available else { return }
        let awaiting = Set(model.awaitingReply)
        for convId in awaiting {
            let steps = steps(convId)
            if var job = turns[convId] {
                guard job.steps != steps else { continue }
                job.steps = steps
                turns[convId] = job
                apply(.upsert(job))
            } else {
                let job = YorozuJob(kind: .turn, steps: steps, startedAt: Date())
                turns[convId] = job
                upsert(job, convId: convId, title: model.conversations[convId]?.title)
            }
        }
        for (convId, job) in turns where !awaiting.contains(convId) {
            turns[convId] = nil
            switch outcome(convId) {
            case .done: finish(id: job.token, state: .done)
            case .failed(let alert): finish(id: job.token, state: .failed, alert: alert)
            case nil: remove(id: job.token)
            }
        }
    }

    private enum Outcome { case done, failed(JobEvent.Alert?) }

    /// How a turn ended: a reply, an error (the push alerts), a send the relay refused (only this device
    /// knows), or nothing within the window.
    private func outcome(_ convId: String) -> Outcome? {
        guard let last = model.conversations[convId]?.items.last(where: { $0.kind != .tools }) else { return nil }
        switch last.kind {
        case .agent: return .done
        case .error: return .failed(nil)
        case .user where last.rejected != nil: return .failed(JobEvent.localFailure.alert)
        default: return nil
        }
    }

    /// Tool calls since the owner's last message; a count only, never their names or arguments.
    private func steps(_ convId: String) -> Int {
        let items = model.conversations[convId]?.items ?? []
        let start = items.lastIndex { $0.kind == .user }.map { $0 + 1 } ?? items.startIndex
        return items[start...].filter { $0.kind == .tools }.reduce(0) { $0 + ($1.tools?.count ?? 0) }
    }

    // MARK: The activity

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { await previous?.value; await work() }
    }

    /// The jobs now: the activity's, which the notification service may have changed, else the ones in memory.
    private func current() async -> [YorozuJob] {
        if let activity, activity.activityState == .ended || activity.activityState == .dismissed { self.activity = nil }
        if activity == nil, let running = YorozuActivityAttributes.current { activity = running }
        return activity?.content.state.jobs ?? jobs
    }

    private func apply(_ change: JobChange?, alert: JobEvent.Alert? = nil) {
        guard available else { return }
        enqueue { [weak self] in
            guard let self else { return }
            let before = await current()
            let next = YorozuJobs.apply(before, change, now: Date())
            jobs = next
            prune(next)
            scheduleExpiry(next)
            if let activity {
                // Leaving with nothing running still ends it, so the system dismisses it after the linger.
                guard next != before || alert != nil || leavingNow else { return }
                if !(await YorozuActivityAttributes.show(next, on: activity, alert: alert.map(Self.configuration), endWhenIdle: !inFront)) {
                    self.activity = nil
                    jobs = []
                }
            } else if !YorozuJobs.shouldEnd(next), inFront || leavingNow, !inFront || YorozuJobs.keepsActivityInApp(next) {
                let content = ActivityContent(state: YorozuActivityState(jobs: next), staleDate: YorozuJobs.staleDate(next, now: Date()))
                activity = try? Activity.request(attributes: YorozuActivityAttributes(), content: content, pushType: nil)
            }
        }
    }

    private func prune(_ jobs: [YorozuJob]) {
        let tokens = Set(jobs.map(\.token))
        ActivityLabelsStore.update { $0.prune(keeping: tokens) }
    }

    /// Clears a finished row once it lingered, while the app still runs; `staleDate` covers the rest.
    private func scheduleExpiry(_ jobs: [YorozuJob]) {
        expiry?.cancel()
        guard let at = YorozuJobs.nextExpiry(jobs) else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow) + 0.5))
            guard !Task.isCancelled else { return }
            self?.apply(nil)
        }
    }

    nonisolated private static func configuration(_ alert: JobEvent.Alert) -> AlertConfiguration {
        switch alert {
        case .transcriptReady:
            AlertConfiguration(title: "Transcript Ready", body: "The text is in the message field for you to review.", sound: .default)
        case .recordingCap:
            AlertConfiguration(title: "Recording Stopped", body: "The recording reached its length limit.", sound: .default)
        case .localFailure:
            AlertConfiguration(title: "Something Went Wrong", body: "Open Yorozu to see what happened.", sound: .default)
        }
    }
}

/// A change or the periodic check, whichever comes first, wakes the watcher once.
private final class ResumeOnce: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = OSAllocatedUnfairLock(initialState: continuation) }
    func resume() { continuation.withLock { $0.take() }?.resume() }
}
#endif
