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

/// The Keychain group the app shares with its notification service extension, holding only the sealed-preview key
/// (`PreviewKeychain`). v1's group, same team and bundle ids, so the App IDs it was registered under still apply.
let notificationKeychainGroup = "$(AppIdentifierPrefix)to.yumi.yorozu.notifications"
/// The app and its extension must carry the same version pair, or the upload is rejected.
func signing(_ extra: SettingsDictionary = [:]) -> Settings {
    .settings(base: [
        "DEVELOPMENT_TEAM": "AN5KM8QGEF",
        "CODE_SIGN_STYLE": "Automatic",
        "MARKETING_VERSION": .string(version),
        "CURRENT_PROJECT_VERSION": "1",
    ].merging(extra) { _, new in new })
}

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
                "YorozuNotificationKeychainAccessGroup": .string(notificationKeychainGroup),
                // `yorozu://pair?…` is the pairing string itself: tapping one opens the app.
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "to.yumi.yorozu.pair",
                        "CFBundleURLSchemes": ["yorozu"],
                    ]
                ],
            ]),
            sources: ["Sources/YorozuIOS/**", "Sources/Shared/**", "../../Sources/ProjectXApp/ChatMarkdown.swift", "../../Sources/ProjectXApp/NoticeText.swift"],
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
                // The app's own group first, so it stays the default for items saved without a group (the pairing's
                // private keys); the shared group holds only the preview key.
                "keychain-access-groups": ["$(AppIdentifierPrefix)to.yumi.yorozu.ios", .string(notificationKeychainGroup)],
            ]),
            dependencies: [.package(product: "YorozuWire"), .target(name: "YorozuNotificationService")],
            // Automatic signing plus `xcodebuild -allowProvisioningUpdates` and an App Store Connect key:
            // Xcode issues the distribution certificate and the App Store profiles (app and extension) itself.
            settings: signing(["ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"])
        ),
        // Opens sealed push previews (docs/ios-relay-contract.md, "Sealed previews"). v1's extension bundle id.
        .target(
            name: "YorozuNotificationService",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "to.yumi.yorozu.ios.notification-service",
            deploymentTargets: .iOS("18.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "CFBundleDisplayName": "Yorozu Notification Service",
                "YorozuNotificationKeychainAccessGroup": .string(notificationKeychainGroup),
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.usernotifications.service",
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).NotificationService",
                ],
            ]),
            sources: ["Sources/YorozuNotificationService/**", "Sources/Shared/**"],
            // The alert titles are the relay keys' v2 wording, from the app's catalog.
            resources: ["Resources/Localizable.xcstrings"],
            entitlements: .dictionary(["keychain-access-groups": [.string(notificationKeychainGroup)]]),
            dependencies: [.package(product: "YorozuWire")],
            settings: signing()
        ),
    ]
)
