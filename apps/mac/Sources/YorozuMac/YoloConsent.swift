import AppKit
import YorozuShared

/// The Mac's say over YOLO. A paired phone may ask to run coding agents without approvals,
/// but it cannot grant that to itself: a lost or stolen phone must not be able to turn the
/// host into a machine that executes whatever it is told, unattended. So the runtime relays
/// the request here, the person at the keyboard answers, and only an Allow sends the real
/// command over the local socket. Deny sends nothing: the runtime never applied it.
///
/// Installed on the host's local-socket model only — see `MacChatSession.startHost` — so a
/// host cannot pop this on a client Mac over the relay.
@MainActor
enum YoloConsent {
    /// The most a phone can be granted from here, whatever it asked for. The runtime caps it
    /// too; this is so the alert never promises more than will be given.
    static let maxHours = 24

    /// True while an alert is up. A second request in the meantime — a phone retrying, or a
    /// stream of them meant to stack alerts until one is clicked through — is dropped, not
    /// queued: the person answers one question at a time, and a request that mattered will be
    /// asked again.
    private(set) static var isAsking = false

    static func ask(_ request: ApprovalSettingsRequestData, model: ChatModel) {
        guard !isAsking else { return }
        isAsking = true
        defer { isAsking = false }
        let hours = min(max(request.hours, 1), maxHours)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            "Allow \(displayName(request.device)) to run coding agents without approval for \(hours) hours?"
        alert.informativeText =
            "YOLO mode runs every tool request without asking, including commands, file edits, purchases, "
            + "messages, and deletes, until it expires."
        // Deny first: it is the default button, so Return — or a key held down while the alert
        // appears — refuses rather than grants.
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow for \(hours) hours")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            model.allowYolo(hours: hours, requestId: request.requestId)
        }
    }

    /// The requester is usually a base64url public key, too long to read: show the same short
    /// fingerprint the Devices screen and the pairing prompt use, so the person can compare it.
    /// A device that is a name rather than a key is shown as it is, cut short if it runs long.
    static func displayName(_ device: String) -> String {
        if let fingerprint = QrPayload.fingerprint(ofBase64URLKey: device) { return fingerprint }
        return device.count > 32 ? String(device.prefix(32)) + "…" : device
    }
}
