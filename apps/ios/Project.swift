import Foundation
import ProjectDescription

/// Generates Yorozu.xcworkspace (not checked in): `tuist generate --no-open --path apps/ios`.
/// Identity matches Yorozu v1 (bundle id, team, ASC app 6811274963) so TestFlight takes it as the same app.
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
    packages: [.local(path: "../../packages/YorozuWire")],
    targets: [
        .target(
            name: "YorozuIOS",
            destinations: .iOS,
            product: .app,
            bundleId: "to.yumi.yorozu.ios",
            deploymentTargets: .iOS("18.0"),
            infoPlist: .extendingDefault(with: [
                // Build settings, so scripts/upload_ios.sh passes both on the xcodebuild command line.
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "UILaunchScreen": [:],
                "ITSAppUsesNonExemptEncryption": false,
                "CFBundleDisplayName": "Yorozu",
                "LSApplicationCategoryType": "public.app-category.productivity",
                "NSCameraUsageDescription": "Yorozu scans the pairing QR code shown by your Mac, and takes photos you choose to send in a message.",
                // "Save Image" in the share sheet of a file opened from a message.
                "NSPhotoLibraryAddUsageDescription": "Yorozu saves pictures to your library when you ask it to.",
                "NSLocalNetworkUsageDescription": "Yorozu connects straight to your Mac on the same network when Direct connection is on.",
                // The relay's silent push: a few seconds to catch up over the sealed channel (`AppDelegate`).
                "UIBackgroundModes": ["remote-notification"],
                // `yorozu://pair?…` is the pairing string itself: tapping one opens the app.
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "to.yumi.yorozu.pair",
                        "CFBundleURLSchemes": ["yorozu"],
                    ]
                ],
            ]),
            sources: ["Sources/YorozuIOS/**", "../../Sources/ProjectXApp/ChatMarkdown.swift", "../../Sources/ProjectXApp/NoticeText.swift"],
            resources: [
                "Resources/AppIcon.icon",
                "Resources/Assets.xcassets",
                "Resources/InfoPlist.xcstrings",
                "Resources/Localizable.xcstrings",
                "Resources/PrivacyInfo.xcprivacy",
            ],
            entitlements: .dictionary([
                // TestFlight is production APNs, the only environment the relay talks to.
                "aps-environment": "production",
                // The QR's web link opens the app (the site's AASA lists `/pair`).
                "com.apple.developer.associated-domains": ["applinks:yorozu.yumi.to"],
            ]),
            dependencies: [.package(product: "YorozuWire")],
            // Automatic signing plus `xcodebuild -allowProvisioningUpdates` and an App Store Connect key:
            // Xcode issues the distribution certificate and the App Store profile itself.
            settings: .settings(base: [
                "DEVELOPMENT_TEAM": "AN5KM8QGEF",
                "CODE_SIGN_STYLE": "Automatic",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "MARKETING_VERSION": .string(version),
                "CURRENT_PROJECT_VERSION": "1",
            ])
        ),
    ]
)
