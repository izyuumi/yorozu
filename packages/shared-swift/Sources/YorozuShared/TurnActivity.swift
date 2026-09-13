import Foundation

/// Where a turn has got to, as a Live Activity says it. Four states because four is what a
/// glance can tell apart on a lock screen: it is running, it is waiting on you, it finished, it
/// did not.
///
/// Outside the iOS-only guard below so the Mac compiles it too, and so the mapping from
/// events to states can be tested without an activity to put it on.
public enum TurnStatus: String, Codable, Hashable, Sendable {
    case working, needsApproval, done, failed

    /// How long a finished activity stays on the lock screen. Long enough to be seen by someone
    /// who felt the phone buzz, short enough not to be litter.
    public static let lingerAfterDone: TimeInterval = 30

    /// How long a running turn's state is worth believing without another update.
    ///
    /// Past it iOS draws the activity as stale rather than as fact, which is the honest thing
    /// to do about a push that never arrived: "Updating…" rather than a status that stopped
    /// being true minutes ago. Mirrors `ACTIVITY_STALE_MS` in apps/relay/src/protocol.ts.
    public static let staleAfter: TimeInterval = 120

    public var label: String {
        switch self {
        case .working: "Working"
        case .needsApproval: "Needs you"
        case .done: "Done"
        case .failed: "Stopped"
        }
    }

    /// SF Symbol. Each reads at Dynamic Island size, where it is the only thing on screen.
    public var symbol: String {
        switch self {
        case .working: "circle.dotted"
        case .needsApproval: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// Whether the turn is still going, which is what decides between a running clock and a
    /// settled time.
    public var isLive: Bool { self == .working || self == .needsApproval }
}

/// Reduces the events of a thread to the one thing a Live Activity shows. Pure and shared, so
/// what the glanceable summary says is decided in one place and checked in a test rather than
/// spread across the controller that drives ActivityKit.
public enum TurnProgress {
    /// The status after this event, or nil for an event that says nothing about the turn.
    ///
    /// `device` is what this client tags its own messages with: someone else's message in the
    /// same thread is their turn starting, which is worth showing too, but our own is the one we
    /// know started here.
    public static func status(after event: YorozuEvent, device: String) -> TurnStatus? {
        switch event.payload {
        // The last message of the *main* agent's turn ends it; a delegated agent finishing is
        // one step of it, and the turn is still running.
        case .message(let data):
            if data.role == .agent { return data.done == true && event.parentAgentId == nil ? .done : .working }
            return event.agentId == device ? .working : nil
        // A card is the turn parked on a person: nothing moves until it is answered.
        case .approvalCard, .questionCard: return .needsApproval
        // Answering one starts it again.
        case .approvalAnswer, .questionAnswer: return .working
        case .thought, .toolCall, .toolResult, .progressCard: return .working
        // Stop is a turn that ends deliberately and says nothing back, so nothing else will
        // arrive to end it.
        case .interrupt: return .failed
        default: return nil
        }
    }
}

/// The thread's name, for a Live Activity that was only ever told an opaque reference.
///
/// The app publishes the handful of thread titles the share sheet needs into the App Group
/// container already; this reads the same file and matches on the reference, so a widget
/// extension — which cannot open the encrypted thread cache — still has a name to draw.
///
/// A thread that is not in that list falls back to the app's own name. That is the honest
/// answer: better a Live Activity that says "Yorozu" than one that has to be told its title
/// by a relay that is not allowed to know it.
public enum TurnTitle {
    public static let fallback = "Yorozu"

    public static func resolve(_ threadRef: String, in directory: URL?) -> String {
        guard let directory else { return fallback }
        let match = ShareBox.threads(in: directory)
            .first { YorozuCrypto.threadRef($0.id) == threadRef }
        return match.map { $0.title.isEmpty ? fallback : $0.title } ?? fallback
    }

    public static func resolve(_ threadRef: String) -> String {
        resolve(threadRef, in: ShareBox.directory())
    }
}

#if os(iOS)
    import ActivityKit

    /// The Live Activity the phone raises when it goes into your pocket with a turn running.
    /// One per thread; the thread it is about is also where tapping it goes.
    ///
    /// Updates arrive two ways. While the app is running it moves the activity itself; once iOS
    /// has suspended it, the relay pushes the same content state over APNs, which is what keeps
    /// a lock screen honest about a turn nobody is watching.
    ///
    /// What it carries is deliberately only the opaque reference. A push that started or moved
    /// this activity travelled through a relay that must not learn the thread, so the title is
    /// never in the payload — it is looked up on the phone, which is the only end that can.
    public struct TurnAttributes: ActivityAttributes {
        public struct ContentState: Codable, Hashable, Sendable {
            public var status: TurnStatus
            /// When the turn began, epoch milliseconds — the same clock `YorozuEvent.ts` is on.
            ///
            /// A number rather than a `Date` because the relay writes this field too, into an
            /// APNs `content-state`, and epoch milliseconds is a thing both ends spell the same
            /// way. The views count up from it rather than being handed an elapsed time that
            /// would be stale the second after it arrived.
            public var startedAt: Double

            public init(status: TurnStatus, startedAt: Double) {
                self.status = status
                self.startedAt = startedAt
            }

            public init(status: TurnStatus, started: Date) {
                self.init(status: status, startedAt: started.timeIntervalSince1970 * 1000)
            }

            public var started: Date { Date(timeIntervalSince1970: startedAt / 1000) }
        }

        /// The opaque id the push side-channel names this thread by — see
        /// ``YorozuCrypto/threadRef(_:)``. The relay routes on it and cannot invert it.
        public var threadRef: String

        public init(threadRef: String) {
            self.threadRef = threadRef
        }

        public init(threadId: String) {
            self.init(threadRef: YorozuCrypto.threadRef(threadId))
        }

        /// Where tapping the activity goes. By reference rather than by thread id, because an
        /// activity started by a push knows only the reference — the app resolves it against
        /// the threads it holds, exactly as it does for a tapped notification.
        public var deepLink: URL? { URL(string: "yorozu://ref/\(threadRef)") }
    }
#endif
