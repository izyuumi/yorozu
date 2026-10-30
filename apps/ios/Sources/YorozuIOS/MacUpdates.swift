#if os(macOS)
import AppKit
import Sparkle
import SwiftUI

@MainActor
enum MacUpdates {
    private static let configuredKey = "YorozuUpdatesConfigured"
    private static weak var model: AppModel?

    static let controller: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        if !UserDefaults.standard.bool(forKey: configuredKey) {
            controller.updater.automaticallyChecksForUpdates = true
            controller.updater.automaticallyDownloadsUpdates = true
            controller.updater.updateCheckInterval = 3600
            UserDefaults.standard.set(true, forKey: configuredKey)
        }
        return controller
    }()

    static func start(model: AppModel) {
        self.model = model
        guard !model.isDemo else { return }
        _ = controller
    }

    static func checkForUpdates() { controller?.checkForUpdates(nil) }

    nonisolated static let betaKey = "YorozuBetaUpdates"
    nonisolated static let betaFeedURL = "https://yorozu.yumi.to/beta/appcast.xml"

    static func betaChanged() { controller?.updater.checkForUpdatesInBackground() }

    /// The last check's outcome, for the About tab.
    @Observable final class Status {
        var lastCheck: Date?
        var message: String?
    }

    static let status = Status()

    private static let delegate = Delegate()

    private final class Delegate: NSObject, SPUUpdaterDelegate {
        func feedURLString(for updater: SPUUpdater) -> String? {
            UserDefaults.standard.bool(forKey: MacUpdates.betaKey) ? MacUpdates.betaFeedURL : nil
        }

        func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
            try allowUpdates()
        }

        func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
            try allowUpdates()
        }

        func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
            MainActor.assumeIsolated { MacUpdates.status.message = String(localized: "You’re up to date.") }
        }

        func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
            let version = item.displayVersionString
            MainActor.assumeIsolated { MacUpdates.status.message = String(localized: "Version \(version) is available.") }
        }

        func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
            let date = updater.lastUpdateCheckDate
            // 1001 is Sparkle's SUNoUpdateError, already reported above.
            let failure = (error as NSError?).flatMap { $0.code == 1001 ? nil : $0.localizedDescription }
            MainActor.assumeIsolated {
                MacUpdates.status.lastCheck = date
                if let failure { MacUpdates.status.message = failure }
            }
        }

        private func allowUpdates() throws {
            if MacUpdates.model?.isDemo == true {
                throw NSError(domain: "YorozuDemo", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "Exit demo mode before checking for updates.")])
            }
        }
    }
}

struct MacAppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "About Yorozu")) {
                let build = Bundle.main.object(forInfoDictionaryKey: "YorozuBuild") as? String ?? ""
                NSApp.orderFrontStandardAboutPanel(options: [.version: build])
            }
            Button(String(localized: "Check for Updates…")) { MacUpdates.checkForUpdates() }
                .disabled(model.isDemo || MacUpdates.controller == nil)
        }
    }
}
#endif
