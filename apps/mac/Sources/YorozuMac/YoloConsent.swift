import AppKit
import YorozuShared

/// The Mac's say over YOLO. A paired phone may ask to run coding agents without approvals,
/// but it cannot grant that to itself: a lost or stolen phone must not be able to turn the
/// host into a machine that executes whatever it is told, unattended. So the runtime relays
/// the request here, the person at the keyboard answers, and only an Allow sends the real
/// command over the local socket. Deny sends nothing: the runtime never applied it.
@MainActor
enum YoloConsent {
    static func ask(_ request: ApprovalSettingsRequestData, model: ChatModel) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            "Allow \(displayName(request.device)) to run coding agents without approval for \(request.hours) hours?"
        alert.informativeText =
            "YOLO mode runs every tool request without asking, including commands, file edits, purchases, "
            + "messages, and deletes, until it expires."
        alert.addButton(withTitle: "Allow for \(request.hours) hours")
        alert.addButton(withTitle: "Deny")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.allowYolo(hours: request.hours, requestId: request.requestId)
        }
    }

    /// The requester is usually a base64url public key, too long to read: show its head.
    private static func displayName(_ device: String) -> String {
        device.count > 16 ? String(device.prefix(8)) + "…" : device
    }
}
