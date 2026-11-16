import Foundation

/// Whether a decrypted push should update the widget snapshot. A reply does; the Live Activity
/// and its labels are left to the host and the app.
struct NotificationEffects: Equatable, Sendable {
    var updatesWidget: Bool

    static func of(_ cls: String) -> NotificationEffects {
        NotificationEffects(updatesWidget: cls == "reply")
    }
}
