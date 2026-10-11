import AppKit
import Sparkle

/// Sparkle, with v1's feed and EdDSA key (Info.plist `SUFeedURL`, `SUPublicEDKey`), so an installed v1 updates to this app
/// and this app keeps updating (owner, 2026-10-11). Beta is v1's own `YorozuBetaUpdates` default, so a v1 beta user stays
/// on beta. A build without a feed starts no updater.
@MainActor final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()
    private static let configuredKey = "YorozuUpdatesConfigured"
    private(set) var controller: SPUStandardUpdaterController?
    /// No task is running: a downloaded update may install now. Set by the app.
    var idle: () -> Bool = { true }
    private var install: (() -> Void)?

    func start() {
        guard controller == nil, let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true,updaterDelegate: self,userDriverDelegate: nil)
        // As v1: automatic checks and downloads, hourly, forced on once per Mac (an earlier "no" persists in defaults).
        if !UserDefaults.standard.bool(forKey: Self.configuredKey) {
            controller.updater.automaticallyChecksForUpdates = true
            controller.updater.automaticallyDownloadsUpdates = true
            controller.updater.updateCheckInterval = 3600
            UserDefaults.standard.set(true,forKey: Self.configuredKey)
        }
        self.controller = controller
    }

    var available: Bool { controller != nil }
    var beta: Bool {
        get { UserDefaults.standard.bool(forKey: betaKey) }
        set { UserDefaults.standard.set(newValue,forKey: betaKey); controller?.updater.resetUpdateCycleAfterShortDelay() }
    }
    func check() { NSApp.activate(); controller?.checkForUpdates(nil) }

    /// The menu-bar host is meant to keep running, so an update that waits for Quit might wait forever: it installs and
    /// relaunches once no task runs. Interrupted runs resume after a restart (docs/architecture.md, Restart and resume).
    func installIfIdle() {
        guard let install, idle() else { return }
        self.install = nil
        install()
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.bool(forKey: betaKey) ? betaFeed : nil
    }
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: betaKey) ? ["beta"] : []
    }
    nonisolated func updater(_ updater: SPUUpdater,willInstallUpdateOnQuit item: SUAppcastItem,immediateInstallationBlock: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { install = immediateInstallationBlock; installIfIdle() }
        return true
    }
}

/// v1's key and beta feed, read as is so its beta users stay on beta.
private let betaKey = "YorozuBetaUpdates", betaFeed = "https://yorozu.yumi.to/beta/appcast.xml"
