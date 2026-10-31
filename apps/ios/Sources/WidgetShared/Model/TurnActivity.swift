#if os(iOS)
import ActivityKit
import Foundation

/// A device-local Live Activity for a turn the owner left running. No message text and no tool
/// arguments: only that the agent is working and how many tool steps it took. Never pushed.
struct TurnActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var steps: Int
    }

    var convId: String
    var startedAt: Date

    static let timeout: TimeInterval = 15 * 60

    /// Ends every activity for `convId` (all of them when nil), from the app or the notification service.
    static func end(convId: String?) async {
        for activity in Activity<Self>.activities where convId == nil || activity.attributes.convId == convId {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
