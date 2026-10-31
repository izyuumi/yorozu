#if os(iOS)
import ActivityKit
import Foundation
import os

/// The device-local Live Activity: started when the owner leaves the app while a turn runs, updated
/// with the tool step count while the app still runs in the background, ended by the reply (here or in
/// the notification service), on return to the app, or after `TurnActivityAttributes.timeout`.
@MainActor
final class TurnActivities {
    static let enabledKey = "turnLiveActivity"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private(set) static var shared: TurnActivities?
    static func start(model: AppModel) {
        guard shared == nil else { return }
        shared = TurnActivities(model: model)
        Task { await TurnActivityAttributes.end(convId: nil) }
    }

    private let model: AppModel
    private var running: [String: Activity<TurnActivityAttributes>] = [:]
    private var watcher: Task<Void, Never>?

    private init(model: AppModel) { self.model = model }

    /// The app is leaving the foreground, the last moment ActivityKit lets it start an activity.
    func leaving() {
        guard Self.enabled, !model.isDemo, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for convId in model.awaitingReply where running[convId] == nil {
            let attributes = TurnActivityAttributes(convId: convId, startedAt: Date())
            let content = ActivityContent(state: TurnActivityAttributes.ContentState(steps: steps(convId)),
                staleDate: Date().addingTimeInterval(TurnActivityAttributes.timeout))
            guard let activity = try? Activity.request(attributes: attributes, content: content, pushType: nil) else { continue }
            running[convId] = activity
        }
        if !running.isEmpty, watcher == nil { watcher = Task { await watch() } }
    }

    /// Back in the app: the conversation itself shows the turn.
    func returned() {
        watcher?.cancel()
        watcher = nil
        running = [:]
        Task { await TurnActivityAttributes.end(convId: nil) }
    }

    private func watch() async {
        let deadline = Date().addingTimeInterval(TurnActivityAttributes.timeout)
        while !Task.isCancelled, !running.isEmpty {
            for (convId, activity) in running {
                if !model.awaitingReply.contains(convId) || Date() >= deadline {
                    running[convId] = nil
                    await activity.end(nil, dismissalPolicy: .immediate)
                } else {
                    let state = TurnActivityAttributes.ContentState(steps: steps(convId))
                    if state != activity.content.state { await activity.update(ActivityContent(state: state, staleDate: deadline)) }
                }
            }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let once = ResumeOnce(done)
                withObservationTracking { _ = model.conversations; _ = model.typing } onChange: { once.resume() }
                Task { try? await Task.sleep(for: .seconds(30)); once.resume() }
            }
        }
        watcher = nil
    }

    /// Tool calls since the owner's last message; a count only, never their names or arguments.
    private func steps(_ convId: String) -> Int {
        let items = model.conversations[convId]?.items ?? []
        let start = items.lastIndex { $0.kind == .user }.map { $0 + 1 } ?? items.startIndex
        return items[start...].filter { $0.kind == .tools }.reduce(0) { $0 + ($1.tools?.count ?? 0) }
    }
}
/// A change or the periodic check, whichever comes first, wakes the watcher once.
private final class ResumeOnce: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = OSAllocatedUnfairLock(initialState: continuation) }
    func resume() { continuation.withLock { $0.take() }?.resume() }
}
#endif
