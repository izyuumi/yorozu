#if os(iOS)
import ActivityKit
import Foundation
import UIKit
import YorozuWire
import os

@MainActor
final class YorozuActivities {
    static var enabled: Bool { LiveActivitySetting.enabled(.standard) }

    private(set) static var shared: YorozuActivities?
    static func start(model: AppModel) {
        LiveActivitySetting.dropLegacy(.standard)
        guard shared == nil else { return }
        let shared = YorozuActivities(model: model)
        Self.shared = shared
        shared.enqueue { await YorozuActivityAttributes.endAll() }
        shared.watcher = Task { await shared.watch() }
    }

    private let model: AppModel
    private var activity: Activity<YorozuActivityAttributes>?
    private var jobs: [YorozuJob] = []
    private var turns: [String: YorozuJob] = [:]
    private var watcher: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var queue: Task<Void, Never>?
    private var leavingNow = false
    private var pushToken: String?
    private var tokenWatch: Task<Void, Never>?
    private var awaitingToken = false
    private var reported: ActivityReport?
    private var hostKnows = true
    private var sessionsSeen = 0

    private init(model: AppModel) { self.model = model }

    private var available: Bool {
        var live = !model.isDemo
        #if DEBUG
        live = live || PreviewScene.current?.locked == true
        #endif
        return Self.enabled && live && ActivityAuthorizationInfo().areActivitiesEnabled
    }
    private var inFront: Bool { UIApplication.shared.applicationState == .active }

    func upsert(_ job: YorozuJob, convId: String? = nil, title: String? = nil) {
        guard available else { return }
        apply(.upsert(job), label: ActivityLabels.Entry(convId: convId, kind: job.kind, title: title))
    }

    func finish(id token: String, state: YorozuJob.State, alert: JobEvent.Alert? = nil) {
        apply(.finish(token: token, state: state), alert: alert)
    }

    func remove(id token: String) { apply(.remove(token: token)) }

    func leaving() {
        syncTurns()
        leavingNow = true
        apply(nil)
        enqueue { [weak self] in self?.leavingNow = false }
    }

    func returned() {
        enqueue { [weak self] in
            guard let self else { return }
            let jobs = await current()
            guard !YorozuJobs.keepsActivityInApp(jobs) else { return }
            self.jobs = jobs.filter { !$0.finished && $0.kind != .needsYou }
            if let activity { await activity.end(nil, dismissalPolicy: .immediate) }
            activity = nil
            await dropToken()
            prune(self.jobs)
        }
    }

    func waitUntilReported(limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        await queue?.value
        while awaitingToken, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func disable() {
        turns = [:]
        enqueue { [weak self] in
            guard let self else { return }
            expiry?.cancel()
            expiry = nil
            jobs = []
            await YorozuActivityAttributes.endAll()
            activity = nil
            await dropToken()
            prune([])
        }
    }

    func previewsChanged() { ActivityLabelsStore.update { _ in } }

    private func watch() async {
        while !Task.isCancelled {
            syncTurns()
            if model.sessionsOpened != sessionsSeen {
                sessionsSeen = model.sessionsOpened
                reportAgain()
            }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let once = ResumeOnce(done)
                withObservationTracking { _ = model.conversations; _ = model.typing; _ = model.sessionsOpened } onChange: { once.resume() }
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

    private func outcome(_ convId: String) -> Outcome? {
        guard let last = model.conversations[convId]?.items.last(where: { $0.kind != .tools }) else { return nil }
        switch last.kind {
        case .agent: return .done
        case .error: return .failed(nil)
        case .user where last.rejected != nil: return .failed(JobEvent.localFailure.alert)
        default: return nil
        }
    }

    private func steps(_ convId: String) -> Int {
        let items = model.conversations[convId]?.items ?? []
        let start = items.lastIndex { $0.kind == .user }.map { $0 + 1 } ?? items.startIndex
        return items[start...].filter { $0.kind == .tools }.reduce(0) { $0 + ($1.tools?.count ?? 0) }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { await previous?.value; await work() }
    }

    private func current() async -> [YorozuJob] {
        if let activity, activity.activityState == .ended || activity.activityState == .dismissed {
            self.activity = nil
            await dropToken()
        }
        if activity == nil, let running = YorozuActivityAttributes.current {
            activity = running
            watchToken(running)
        }
        return activity?.content.state.jobs ?? jobs
    }

    private func apply(_ change: JobChange?, label: ActivityLabels.Entry? = nil, alert: JobEvent.Alert? = nil) {
        guard available else { return }
        let step = YorozuJobs.queued(change, label: label)
        enqueue { [weak self] in
            guard let self else { return }
            let before = await current()
            let next = step(before, Date())
            jobs = next
            scheduleExpiry(next)
            if let activity {
                guard next != before || alert != nil || leavingNow else { return }
                if !(await YorozuActivityAttributes.show(next, on: activity, alert: alert.map(Self.configuration), endWhenIdle: !inFront)) {
                    self.activity = nil
                    jobs = []
                    return await dropToken()
                }
            } else if !YorozuJobs.shouldEnd(next), inFront || leavingNow, !inFront || YorozuJobs.keepsActivityInApp(next) {
                let now = Date()
                let content = ActivityContent(state: YorozuActivityState(jobs: next, updatedAt: now), staleDate: YorozuJobs.staleDate(next, now: now))
                let pushType: PushType? = model.liveActivityPushAvailable ? .token : nil
                activity = try? Activity.request(attributes: YorozuActivityAttributes(), content: content, pushType: pushType)
                if let activity, pushType != nil {
                    awaitingToken = true
                    watchToken(activity)
                }
            }
            await report(next)
        }
    }

    private var turnTokens: [String: String] {
        Dictionary(turns.map { ($0.value.token, $0.key) }, uniquingKeysWith: { first, _ in first })
    }

    private func watchToken(_ activity: Activity<YorozuActivityAttributes>) {
        tokenWatch?.cancel()
        tokenWatch = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                self?.enqueue { [weak self] in
                    guard let self, self.activity?.id == activity.id else { return }
                    pushToken = token
                    await report(await current())
                }
            }
        }
    }

    private func report(_ jobs: [YorozuJob]) async {
        guard let pushToken, activity != nil else { return }
        let report = ActivityReport(pushToken: pushToken, activity: jobs, turns: turnTokens)
        guard report != reported, await model.report(report) else { return }
        reported = report
        hostKnows = true
        awaitingToken = false
    }

    private func reportAgain() {
        enqueue { [weak self] in
            guard let self else { return }
            reported = nil
            let jobs = await current()
            if activity == nil { return await dropToken() }
            await report(jobs)
        }
    }

    private func dropToken() async {
        tokenWatch?.cancel()
        tokenWatch = nil
        pushToken = nil
        awaitingToken = false
        reported = nil
        guard hostKnows, await model.report(ActivityReport(pushToken: nil)) else { return }
        hostKnows = false
    }

    private func prune(_ jobs: [YorozuJob]) {
        let tokens = Set(jobs.map(\.token))
        ActivityLabelsStore.update { $0.prune(keeping: tokens) }
    }

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

private final class ResumeOnce: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = OSAllocatedUnfairLock(initialState: continuation) }
    func resume() { continuation.withLock { $0.take() }?.resume() }
}
#endif
