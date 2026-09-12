import AppKit
import Sparkle
import SwiftUI
import YorozuKeepalive

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

    /// Set while Sparkle is installing and about to relaunch us. Quitting for an update is not
    /// the user quitting, so it must not pause the watchdog — see ``AppDelegate``.
    static var installing = false

    /// Touches `controller`, which is what starts the updater and its hourly schedule, and
    /// starts saying in the log what that schedule is actually doing.
    static func start() {
        _ = controller
        logStatus()
        // Sparkle's own scheduling is opaque from the outside: this Mac was three releases
        // behind with a last-check time eight hours old and nothing anywhere said why. An
        // hourly line is what turns "it stopped updating" into a thing that can be read.
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { logStatus() }
        }
    }

    /// One line: whether a check can run, when the last one did, and if it cannot, why not.
    /// A check that is overdue by more than an interval is also nudged — the log is there to
    /// explain the silence, not to keep a tidy record of it.
    static func logStatus() {
        guard let updater = controller?.updater else {
            Log.write("updates: no SUFeedURL in this build, updater not started")
            return
        }
        let last = updater.lastUpdateCheckDate
        let age = last.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "never"
        Log.write(
            "updates: canCheck=\(updater.canCheckForUpdates) checks=\(updater.automaticallyChecksForUpdates) "
                + "downloads=\(updater.automaticallyDownloadsUpdates) "
                + "interval=\(Int(updater.updateCheckInterval))s lastCheck=\(age)"
        )
        guard updater.canCheckForUpdates else {
            Log.write(
                "updates: no check now — "
                    + (updater.sessionInProgress ? "one is already running" : "the updater is not ready")
            )
            return
        }
        guard updater.automaticallyChecksForUpdates else {
            Log.write("updates: no check now — automatic checks are turned off")
            return
        }
        let overdue = last.map { Date().timeIntervalSince($0) > updater.updateCheckInterval * 2 } ?? true
        if overdue {
            Log.write("updates: last check is overdue, checking now")
            updater.checkForUpdatesInBackground()
        }
    }

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
/// the app relaunches itself — but only while there is no chat window open. An open chat is
/// the one thing a relaunch would cut off mid-stream; with none, there is nothing on screen
/// to interrupt, whether or not the app happens to be the active one.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        guard !WindowPresence.isOpen else {
            Log.write("updates: \(item.displayVersionString) held, a chat window is open")
            return false
        }
        Log.write("updates: installing \(item.displayVersionString) now")
        Updates.installing = true
        immediateInstallationBlock()
        return true
    }

    /// Never postpone the relaunch. Sparkle asks in case the app has something to finish; this
    /// one does not, and a postponed relaunch on a Mac with nobody at it is an app that is
    /// simply gone until somebody notices. If the relaunch itself fails, the watchdog has it.
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        Updates.installing = true
        Log.write("updates: relaunching into \(item.displayVersionString)")
        return false
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.write("updates: found \(item.displayVersionString) (build \(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Log.write("updates: none available — \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        Log.write("updates: aborted — \(error.localizedDescription)")
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
