import Foundation

struct NotificationEffects: Equatable, Sendable {
    var updatesWidget: Bool

    static func of(_ cls: String) -> NotificationEffects {
        NotificationEffects(updatesWidget: cls == "reply")
    }
}
