import Sparkle
import SwiftUI

/// Sparkle, whole. The feed URL and the public EdDSA key live in `Info.plist`, written by
/// `scripts/build-mac.sh`; a build without them (`swift run`, the dev bundle) has no feed
/// to check, so the updater is not started and the menu item is not shown rather than
/// greeting the user with Sparkle's "update feed URL is not set" alert.
@MainActor
enum Updates {
    static let controller: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        return SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()
}

struct CheckForUpdatesButton: View {
    var body: some View {
        if let controller = Updates.controller {
            Button("Check for Updates…") { controller.updater.checkForUpdates() }
        }
    }
}
