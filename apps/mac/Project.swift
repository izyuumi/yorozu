import Foundation
import ProjectDescription

/// Generates Yorozu.xcworkspace (not checked in): `tuist generate --no-open --path apps/mac`.
/// Identity matches Yorozu v1 (bundle id, team, Developer ID) so this build updates it in place.
let versionFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../version.txt").standardizedFileURL
let version: String = {
    guard let raw = try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          raw.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
    else { fatalError("Expected numeric major.minor.patch in \(versionFile.path)") }
    return raw
}()

let project = Project(
    name: "Yorozu",
    packages: [.package(path: "../.."), .package(path: "../../packages/YorozuWire"),
               .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMajor(from: "2.9.0"))],
    targets: [
        .target(
            name: "Yorozu",
            destinations: .macOS,
            product: .app,
            bundleId: "to.yumi.yorozu",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "CFBundleIconFile": "Yorozu",
                "NSAccentColorName": "AccentColor",
                "LSApplicationCategoryType": "public.app-category.productivity",
                "LSUIElement": true, // Menu-bar host: no Dock icon, no main window.
                "NSLocalNetworkUsageDescription": "Yorozu lets your paired client devices connect to this Mac directly over your local network or VPN.",
                // Sparkle (Updates.swift): v1's feed and EdDSA public key, so v1 installs update to this app. The feed is set
                // only by scripts/release_mac.sh: a dev build (build 1) would take v1's own release as an update.
                "SUFeedURL": "$(YOROZU_FEED_URL)",
                "SUPublicEDKey": "pD6gPv1CP/XDvIJXbztjQRTIkgR/kfMMYT/Mpp8aQvI=",
                "SUEnableAutomaticChecks": true,
                "SUAutomaticallyUpdate": true,
                "SUAllowsAutomaticUpdates": true,
                "SUScheduledCheckInterval": 3600,
            ]),
            // The client core the phone runs, for a Mac in the client role (connected to another host Mac).
            sources: ["../../Sources/ProjectXApp/**", "../ios/Sources/Client/**"],
            resources: ["Resources/Yorozu.icns", "Resources/Accent.xcassets", "Resources/Localizable.xcstrings", "Resources/InfoPlist.xcstrings"],
            entitlements: "Yorozu.entitlements",
            dependencies: [.package(product: "ProjectXCore"), .package(product: "YorozuWire"), .package(product: "Sparkle")],
            settings: .settings(base: [
                "DEVELOPMENT_TEAM": "AN5KM8QGEF",
                "CODE_SIGN_STYLE": "Manual",
                "ENABLE_HARDENED_RUNTIME": "YES",
                "MARKETING_VERSION": .string(version),
                "CURRENT_PROJECT_VERSION": "1",
                // A build never carries get-task-allow: notarization refuses it, and the dev app is the same signed app.
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
                "YOROZU_FEED_URL": "",
            ], configurations: [
                // Identity and timestamp flag: Signing.xcconfig, overridden by the gitignored Signing.local.xcconfig.
                .debug(name: .debug, xcconfig: "Signing.xcconfig"),
                .release(name: .release, xcconfig: "Signing.xcconfig"),
            // Tuist's defaults would set the identity at target level, over the xcconfig.
            ], defaultSettings: .recommended(excluding: ["CODE_SIGN_IDENTITY"]))
        ),
    ]
)
