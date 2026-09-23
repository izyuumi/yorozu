import AppKit

/// The question a pairing link has to get a yes to before it replaces anything on this Mac.
///
/// An `NSAlert` rather than a SwiftUI alert: the link can arrive with no window open at all —
/// this is a menu bar app — and a sheet needs a window to hang off. Modal, because nothing
/// else should happen to the pairing while the question is on screen.
@MainActor
enum PairingConsent {
    /// True only when "Replace pairing" was chosen.
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
            : String(localized: "Replace pairing?")
        alert.informativeText = informativeText(pending)
        alert.addButton(withTitle: String(localized: "Replace pairing"))
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
            lines.append(String(localized: "This Mac will forget its current pairing and cached threads, and connect to the Mac this code came from."))
        }
        return lines.joined(separator: "\n")
    }
}
