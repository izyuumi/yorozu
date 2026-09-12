import AppKit
import Sparkle
import SwiftUI

/// Sparkle, whole. The feed URL and the public EdDSA key live in `Info.plist`, written by
/// `scripts/build-mac.sh`; a build without them (`swift run`, the dev bundle) has no feed
/// to check, so the updater is not started and the menu item is not shown rather than
/// greeting the user with Sparkle's "update feed URL is not set" alert.
///
/// Updates install themselves: this is a menu bar app with no document to lose and no
/// window to interrupt, so the user should never have to know a release happened. The
/// sidecar it relaunches comes back onto the same state directory
/// (`~/Library/Application Support/Yorozu`, which has nothing version-shaped in it), so
/// the room and every paired phone survive the swap.
@MainActor
enum Updates {
    /// Marks that this build has already forced the automatic-update preferences on. Sparkle
    /// persists those in the host's user defaults, so a Mac that answered "no" to the older
    /// build's "check for updates automatically?" prompt would otherwise keep answering no
    /// forever — the Info.plist keys only supply an initial value, and there already is one.
    private static let configuredKey = "YorozuUpdatesConfigured"

    static let controller: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        if !UserDefaults.standard.bool(forKey: configuredKey) {
            controller.updater.automaticallyChecksForUpdates = true
            controller.updater.automaticallyDownloadsUpdates = true
            controller.updater.updateCheckInterval = 3600
            UserDefaults.standard.set(true, forKey: configuredKey)
        }
        return controller
    }()

    private static let delegate = UpdaterDelegate()

    /// The Settings toggle. Reading and writing Sparkle's own property rather than a second
    /// preference of ours: Sparkle persists it, and two places to store one fact is one place
    /// too many.
    static var automatic: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }
}

/// Why this exists at all: once an update is downloaded, Sparkle's default is to sit on it
/// until the app quits. A menu bar app is quit about once a month, so "automatic" would mean
/// "eventually". Returning true here takes the installation over and runs it now — no UI,
/// the app relaunches itself — but only while the user is not looking at us. While the app is
/// active there is a chat on screen that a relaunch would cut off mid-stream, so the update
/// is left to Sparkle's own scheduler, which offers it again later and installs it on quit.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        guard !NSApp.isActive else { return false }
        immediateInstallationBlock()
        return true
    }
}

struct CheckForUpdatesButton: View {
    var body: some View {
        if let controller = Updates.controller {
            Button("Check for Updates…") { controller.updater.checkForUpdates() }
        }
    }
}

/// The automatic-updates toggle, next to the button that checks right now. Hidden with the
/// button in a build that has no feed.
struct AutomaticUpdatesToggle: View {
    @State private var automatic = Updates.automatic

    var body: some View {
        if Updates.controller != nil {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Update automatically", isOn: $automatic)
                    .onChange(of: automatic) { Updates.automatic = automatic }
                Text("Downloads new versions in the background and installs them while you are away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
