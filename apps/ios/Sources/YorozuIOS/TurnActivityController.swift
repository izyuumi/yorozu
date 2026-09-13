import ActivityKit
import Foundation
import YorozuShared

/// Raises a Live Activity for a turn the phone is carrying in a pocket, and takes it down again.
///
/// The rule is the one the lock screen deserves: nothing appears while you are looking at the
/// chat, because the chat is already saying it. Only when the app leaves the foreground with a
/// turn still running does an activity go up — and only for the threads that actually have one.
///
/// Updates come from two places. While the app is running this moves the activity itself. Once
/// iOS has suspended it, the relay pushes the same content state over APNs, which is what keeps
/// a lock screen honest about a turn nobody is watching. The activity's own push token is
/// registered with the relay as soon as ActivityKit issues one, and taken back when it ends.
///
/// Every activity is marked stale ahead of the next expected update, so a push that never lands
/// shows "Updating…" instead of a status that quietly stopped being true.
@MainActor
final class TurnActivityController {
    /// The live turns, by thread, and when each began. Kept whether or not an activity is
    /// showing: this is what says whether there is anything to raise on the way out.
    private var started: [String: Date] = [:]
    private var status: [String: TurnStatus] = [:]
    /// The activities on screen, by thread.
    private var activities: [String: Activity<TurnAttributes>] = [:]
    /// The tasks following each activity's push token, cancelled with the activity.
    private var tokenWatchers: [String: Task<Void, Never>] = [:]
    /// The timers holding a finished activity on screen for its last thirty seconds, so a second
    /// `done` does not schedule a second dismissal.
    private var endings: [String: Task<Void, Never>] = [:]
    private weak var model: ChatModel?
    /// Where push tokens go. Nil on a build with no relay behind it — the Mac app's chat, and
    /// the screenshot harness — which is simply an activity that only ever updates locally.
    private let relay: (any PushRegistering)?
    private var foreground = true
    private var startTokens: Task<Void, Never>?

    init(model: ChatModel, relay: (any PushRegistering)? = nil) {
        self.model = model
        self.relay = relay
        guard let relay else { return }
        // Push-to-start, which is what lets a turn that begins while the phone is already in a
        // pocket put something on the lock screen at all. One token per install, reissued by
        // iOS whenever it feels like it, so this follows the stream for the app's lifetime.
        startTokens = Task {
            for await token in Activity<TurnAttributes>.pushToStartTokenUpdates {
                await relay.registerPushToStart(token: hex(token))
            }
        }
    }

    deinit {
        startTokens?.cancel()
    }

    /// Folds one event in. Called for every event the model keeps, after it has applied it.
    func handle(_ event: YorozuEvent) {
        guard let next = TurnProgress.status(after: event, device: "phone") else { return }
        let thread = event.threadId
        guard !thread.isEmpty else { return }

        switch next {
        case .working, .needsApproval:
            // A turn that was already finishing and speaks again is running again: the linger
            // timer is cancelled rather than left to dismiss a live activity out from under it.
            endings.removeValue(forKey: thread)?.cancel()
            if started[thread] == nil { started[thread] = Date() }
        case .done, .failed:
            // Nothing to finish: an event that ends a turn this device never saw start is a turn
            // that ran on another device, and is not ours to announce.
            guard started[thread] != nil else { return }
        }
        status[thread] = next
        update(thread)
        if next == .done || next == .failed { finish(thread) }
    }

    /// The app going into a pocket: the moment the activities are worth having. Only turns
    /// already running get one — an activity is a way to keep watching something, not a way to
    /// announce it.
    ///
    /// `.inactive` is deliberately not this. It is what a pulled-down Notification Centre or an
    /// app switcher glance looks like, and an activity that appeared and vanished with each of
    /// those would be a flicker rather than a notification.
    func backgrounded() {
        foreground = false
        for thread in started.keys { update(thread) }
    }

    /// Back in the app. Anything the model has already finished is settled first — a turn that
    /// ended while iOS had the app suspended has no event coming to end it here — and then every
    /// activity goes, because the chat on screen is saying all of this better.
    func foregrounded() {
        foreground = true
        for thread in started.keys where model?.generating.contains(thread) == false {
            guard status[thread]?.isLive == true else { continue }
            status[thread] = .done
            update(thread)
            finish(thread)
        }
        dismissAll()
    }

    /// Raises, moves or leaves alone the activity for one thread.
    private func update(_ thread: String) {
        guard let status = status[thread], let startedAt = started[thread] else { return }
        let content = ActivityContent(
            state: TurnAttributes.ContentState(status: status, started: startedAt),
            // A running turn is believed only until the next update is due, so a push that goes
            // missing leaves the lock screen saying "Updating…" rather than something untrue. A
            // finished one is stale as soon as it is drawn, so iOS may retire it on its own.
            staleDate: Date().addingTimeInterval(
                status.isLive ? TurnStatus.staleAfter : TurnStatus.lingerAfterDone
            )
        )
        if let activity = activities[thread] {
            Task { await activity.update(content) }
        } else {
            // Only on the way out, and only for a turn still going: an activity for something
            // already finished would appear and vanish in the same second.
            guard !foreground, status.isLive, ActivityAuthorizationInfo().areActivitiesEnabled
            else { return }
            let attributes = TurnAttributes(threadId: thread)
            guard
                let activity = try? Activity.request(
                    attributes: attributes,
                    content: content,
                    // Asking for a push token is what lets the relay move this activity once
                    // iOS has suspended us. It is issued asynchronously, hence the stream below.
                    pushType: .token
                )
            else { return }
            activities[thread] = activity
            watchToken(of: activity, thread: thread)
        }
    }

    /// Follows one activity's push token to the relay. ActivityKit reissues these, so it is a
    /// stream rather than a value, and it ends when the activity does.
    private func watchToken(of activity: Activity<TurnAttributes>, thread: String) {
        guard let relay else { return }
        let ref = YorozuCrypto.threadRef(thread)
        tokenWatchers[thread]?.cancel()
        tokenWatchers[thread] = Task {
            for await token in activity.pushTokenUpdates {
                await relay.registerActivity(threadRef: ref, token: hex(token))
            }
        }
    }

    /// Tells the relay there is nothing to push to for this thread any more, and stops watching.
    private func releaseToken(_ thread: String) {
        tokenWatchers.removeValue(forKey: thread)?.cancel()
        guard let relay else { return }
        let ref = YorozuCrypto.threadRef(thread)
        Task { await relay.registerActivity(threadRef: ref, token: nil) }
    }

    /// A finished turn: no longer running, but left on the lock screen for half a minute so it
    /// can be read by whoever the buzz brought back to the phone.
    ///
    /// The activity stays in ``activities`` while it lingers rather than being handed to the
    /// timer. Held only by a task, an activity that had its timer cancelled — by ``dismissAll``,
    /// or by the turn speaking again — would be left on the lock screen with nothing holding a
    /// reference to end it.
    private func finish(_ thread: String) {
        started[thread] = nil
        guard activities[thread] != nil else {
            status[thread] = nil
            return
        }
        endings[thread]?.cancel()
        endings[thread] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TurnStatus.lingerAfterDone))
            guard !Task.isCancelled, let self else { return }
            self.releaseToken(thread)
            await self.activities.removeValue(forKey: thread)?.end(nil, dismissalPolicy: .immediate)
            self.endings[thread] = nil
            self.status[thread] = nil
        }
    }

    /// Back in the app, where the chat itself is the status. Every activity goes, including the
    /// ones still counting down their last thirty seconds.
    private func dismissAll() {
        for task in endings.values { task.cancel() }
        endings.removeAll()
        for (thread, activity) in activities {
            // A turn still running keeps its status, so backgrounding again raises it afresh.
            status[thread] = status[thread]?.isLive == true ? status[thread] : nil
            releaseToken(thread)
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        activities.removeAll()
    }
}

/// APNs tokens are bytes; every API that takes one takes the hex of it.
private func hex(_ token: Data) -> String {
    token.map { String(format: "%02x", $0) }.joined()
}
