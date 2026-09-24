import AppKit

/// Pairing links require consent to add or explicitly repair their authenticated host.
///
/// An `NSAlert` rather than a SwiftUI alert: the link can arrive with no window open at all —
/// this is a menu bar app — and a sheet needs a window to hang off. Modal, because nothing
/// else should happen to the pairing while the question is on screen.
@MainActor
enum PairingConsent {
    /// True only when the explicit add, repair, or role-change button was chosen.
    static func ask(_ pending: MacChatSession.PendingPairing) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        // Floating, so the question is on top even when activation was refused — this is an
        // accessory app that may have no window up. A modal alert nobody can find is a menu
        // bar item that never answers again.
        alert.window.level = .floating
        alert.messageText = pending.stopsHosting
            ? String(localized: "Stop hosting and pair with another Mac?")
            : pending.repairsHost != nil ? String(localized: "Already connected") : String(localized: "Add host?")
        alert.informativeText = informativeText(pending)
        alert.addButton(withTitle: pending.repairsHost != nil ? String(localized: "Repair connection") : String(localized: "Add host"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// What the link would do, in the person's terms: where it dials and which Mac's key it
    /// carries, so a code from the Devices screen of the Mac they meant is recognisable.
    private static func informativeText(_ pending: MacChatSession.PendingPairing) -> String {
        var lines = [
            String(localized: "Relay: \(pending.relayHost)"),
            String(localized: "Mac key: \(pending.macKeyFingerprint)"),
            "",
        ]
        if pending.stopsHosting {
            lines.append(String(localized: "This Mac will stop hosting Yorozu: the runtime shuts down and paired phones lose their connection to it. It becomes a client of the Mac this code came from."))
        } else {
            lines.append(pending.repairsHost != nil
                ? String(localized: "Repair replaces this connection. Chats, drafts, and queued messages stay saved.")
                : String(localized: "This Mac will connect to the host from this code. Saved chats stay available."))
        }
        return lines.joined(separator: "\n")
    }
}
