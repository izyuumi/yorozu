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

#if os(iOS)
    import ActivityKit

    /// The Live Activity the phone raises when it goes into your pocket with a turn running.
    /// One per thread; the thread it is about is also where tapping it goes.
    ///
    /// Local only: every update comes from the app while it is still running, and there is no
    /// push token here to hand anyone. A turn that finishes after iOS has suspended the app is
    /// caught the next time the app runs, which is the honest limit of not using APNs.
    public struct TurnAttributes: ActivityAttributes {
        public struct ContentState: Codable, Hashable, Sendable {
            public var status: TurnStatus
            /// When the turn began, which the views count up from rather than being told an
            /// elapsed time that would be stale the second after it arrived.
            public var startedAt: Date

            public init(status: TurnStatus, startedAt: Date) {
                self.status = status
                self.startedAt = startedAt
            }
        }

        public var threadId: String
        /// The thread's title as the list draws it, frozen when the activity started: a thread
        /// auto-titled mid-turn is not worth restarting an activity over.
        public var title: String

        public init(threadId: String, title: String) {
            self.threadId = threadId
            self.title = title
        }

        /// Where tapping the activity goes, which is the same link the share extension and a
        /// pasted URL use.
        public var deepLink: URL? { URL(string: "yorozu://thread/\(threadId)") }
    }
#endif
