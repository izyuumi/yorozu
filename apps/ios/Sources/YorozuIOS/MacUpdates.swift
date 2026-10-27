#if os(macOS)
import AppKit
import Sparkle
import SwiftUI

/// Sparkle on the Mac. Feed (the stable one, which every Mac reads), public key and the hourly automatic install are in
/// Info.plist (apps/ios/Project.swift).
@MainActor
enum MacUpdates {
    private static let configuredKey = "YorozuUpdatesConfigured"
    private static weak var model: AppModel?

    /// Nil in a build without a feed (dev builds that strip it), so no "feed URL is not set" alert.
    static let controller: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        // Info.plist only seeds a Mac without Sparkle preferences; 0.5 forced these on once with the same marker.
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

    private static let delegate = Delegate()

    private final class Delegate: NSObject, SPUUpdaterDelegate {
        func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
            try allowUpdates()
        }

        func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
            try allowUpdates()
        }

        private func allowUpdates() throws {
            if MacUpdates.model?.isDemo == true {
                throw NSError(domain: "YorozuDemo", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "Exit demo mode before checking for updates.")])
            }
        }
    }
}

/// About and Check for Updates in the app menu. About shows the visible build ("0.9.0 (1)"), not `CFBundleVersion`.
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
