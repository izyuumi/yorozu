#if os(macOS)
import AppKit
import Sparkle
import SwiftUI

/// Sparkle on the Mac. Feed, public key and the hourly automatic install are in Info.plist (apps/ios/Project.swift); the
/// default feed is the beta one. The Mac shares 0.5's bundle id and so its user defaults: an explicit
/// `YorozuBetaUpdates = false` from 0.5 still picks the stable feed.
@MainActor
enum MacUpdates {
    private static let configuredKey = "YorozuUpdatesConfigured"
    private static let betaKey = "YorozuBetaUpdates"
    static let stableFeedURL = "https://yorozu.yumi.to/appcast.xml"

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

    static var beta: Bool { UserDefaults.standard.object(forKey: betaKey) as? Bool ?? true }

    static func start() { _ = controller }

    static func checkForUpdates() { controller?.checkForUpdates(nil) }

    private static let delegate = Delegate()

    private final class Delegate: NSObject, SPUUpdaterDelegate {
        func feedURLString(for updater: SPUUpdater) -> String? {
            MainActor.assumeIsolated { MacUpdates.beta ? nil : MacUpdates.stableFeedURL }
        }

        /// Beta appcast items carry `sparkle:channel` beta, as 0.5's did.
        func allowedChannels(for updater: SPUUpdater) -> Set<String> {
            MainActor.assumeIsolated { MacUpdates.beta ? ["beta"] : [] }
        }
    }
}

/// About and Check for Updates in the app menu. About shows the visible build ("0.9.0 (1)"), not `CFBundleVersion`.
struct MacAppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "About Yorozu")) {
                let build = Bundle.main.object(forInfoDictionaryKey: "YorozuBuild") as? String ?? ""
                NSApp.orderFrontStandardAboutPanel(options: [.version: build])
            }
            Button(String(localized: "Check for Updates…")) { MacUpdates.checkForUpdates() }
                .disabled(MacUpdates.controller == nil)
        }
    }
}
#endif
