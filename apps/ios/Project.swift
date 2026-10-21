import Foundation
import ProjectDescription

/// Generates Yorozu.xcworkspace (not checked in): `tuist generate --no-open --path apps/ios`. One client app for iPhone, iPad and
/// Mac (native SwiftUI, not Catalyst); the extensions are iOS-only and uploads archive iOS only (docs/release.md).
/// Identity matches Yorozu 0.5 (bundle ids, team, ASC app 6811274963): TestFlight and the App Store take the iOS app as the
/// same app, and Sparkle updates the Mac app (`to.yumi.yorozu`) in place.
let versionFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../version.txt").standardizedFileURL
let version: String = {
    guard let raw = try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          raw.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
    else { fatalError("Expected numeric major.minor.patch in \(versionFile.path)") }
    return raw
}()

/// `CFBundleVersion` for a visible build: major·10⁷ + minor·10⁵ + patch·10³ + build (0.9.0 build 1 = 900001). Sparkle
/// compares this integer, and 0.5.0-beta installs are build 10279, so it must only ever rise (OWNER_DECISIONS.md).
/// `scripts/build-number.sh` is the same formula for the scripts, which pass both numbers on the command line.
func bundleVersion(build: Int) -> String {
    let p = version.split(separator: ".").compactMap { Int($0) }
    guard p[1] < 100, p[2] < 100, (1..<1000).contains(build) else { fatalError("Version \(version) build \(build) overflows CFBundleVersion") }
    return String(p[0] * 10_000_000 + p[1] * 100_000 + p[2] * 1_000 + build)
}

/// The Keychain group the app shares with its notification service extension, holding only the sealed-preview key
/// (`PreviewKeychain`). v1's group, same team and bundle ids, so the App IDs it was registered under still apply.
let notificationKeychainGroup = "$(AppIdentifierPrefix)to.yumi.yorozu.notifications"
/// The app and its share extension pass shares through this App Group's container (`ShareInbox`). v1's group.
let appGroup = "group.to.yumi.yorozu"
/// The app and its extension must carry the same version pair, or the upload is rejected.
func signing(_ extra: SettingsDictionary = [:]) -> Settings {
    .settings(base: [
        "DEVELOPMENT_TEAM": "AN5KM8QGEF",
        "CODE_SIGN_STYLE": "Automatic",
        "MARKETING_VERSION": .string(version),
        "CURRENT_PROJECT_VERSION": .string(bundleVersion(build: 1)),
        // The build people see, restarting at 1 per version.
        "YOROZU_BUILD": "1",
    ].merging(extra) { _, new in new })
}

let project = Project(
    name: "Yorozu",
    packages: [
        .local(path: "../../packages/YorozuWire"),
        // Mac updates (docs/upgrade-from-0.5.md); the iOS app does not link it.
        .remote(url: "https://github.com/sparkle-project/Sparkle", requirement: .upToNextMajor(from: "2.9.0")),
    ],
    targets: [
        .target(
            name: "YorozuIOS",
            destinations: [.iPhone, .iPad, .mac],
            product: .app,
            bundleId: "to.yumi.yorozu.ios",
            deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
            infoPlist: .extendingDefault(with: [
                // Build settings, so scripts/upload_ios.sh passes both on the xcodebuild command line.
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "YorozuBuild": "$(YOROZU_BUILD)",
                // Sparkle, read on the Mac only: the beta feed by default, 0.5's EdDSA key, hourly automatic installs.
                "SUFeedURL": "https://yorozu.yumi.to/beta/appcast.xml",
                "SUPublicEDKey": "pD6gPv1CP/XDvIJXbztjQRTIkgR/kfMMYT/Mpp8aQvI=",
                "SUEnableAutomaticChecks": true,
                "SUAutomaticallyUpdate": true,
                "SUAllowsAutomaticUpdates": true,
                "SUScheduledCheckInterval": 3600,
                "UILaunchStoryboardName": "LaunchScreen",
                "ITSAppUsesNonExemptEncryption": false,
                "CFBundleDisplayName": "Yorozu",
                // The Mac's app menu and Dock name, rather than the target's.
                "CFBundleName": "Yorozu",
                "LSApplicationCategoryType": "public.app-category.productivity",
                "NSCameraUsageDescription": "Yorozu scans the pairing QR code shown by your Mac, and takes photos you choose to send in a message.",
                // "Save Image" in the share sheet of a file opened from a message.
                "NSPhotoLibraryAddUsageDescription": "Yorozu saves pictures to your library when you ask it to.",
                // The relay's silent push launches a suspended app, which reconnects (#431).
                "UIBackgroundModes": ["remote-notification"],
                "YorozuNotificationKeychainAccessGroup": .string(notificationKeychainGroup),
                // A conversation dragged from the list onto a side of the conversation area (Pair.swift); in-app only.
                "UTExportedTypeDeclarations": [
                    [
                        "UTTypeIdentifier": "to.yumi.yorozu.conversation",
                        "UTTypeDescription": "Yorozu Conversation",
                        "UTTypeConformsTo": ["public.data"],
                    ]
                ],
                // `yorozu://pair?…` is the pairing string itself: tapping one opens the app.
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "to.yumi.yorozu.pair",
                        "CFBundleURLSchemes": ["yorozu"],
                    ]
                ],
            ]),
            sources: ["Sources/YorozuIOS/**", "Sources/Shared/**", "Sources/Client/**", "Sources/ShareInbox/**"],
            resources: [
                "Resources/AppIcon.icon",
                // iOS only: the Mac build rejects an iOS storyboard.
                .glob(pattern: "Resources/LaunchScreen.storyboard", inclusionCondition: .when([.ios])),
                "Resources/Assets.xcassets",
                // Siri phrases for the App Shortcuts (YorozuIntents.swift), in Japanese.
                "Resources/AppShortcuts.xcstrings",
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
                "com.apple.security.application-groups": [.string(appGroup)],
            ]),
            // The OpenClaw plugin rides in the Mac app at the path 0.5's `openclaw plugins install --link` points to, so
            // the Gateway loads this version after a reload (stable contract, OWNER_DECISIONS.md). TypeScript, run as is.
            scripts: [
                .post(
                    script: """
                    [ "$PLATFORM_NAME" = macosx ] || exit 0
                    dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/openclaw-channel"
                    rm -rf "$dest" && mkdir -p "$dest"
                    cd "$SRCROOT/../../plugins/openclaw-yorozu"
                    cp -R index.ts setup-entry.ts openclaw.plugin.json package.json README.md src "$dest/"
                    """,
                    name: "Bundle the OpenClaw plugin",
                    basedOnDependencyAnalysis: false
                ),
            ],
            dependencies: [
                .package(product: "YorozuWire"),
                .package(product: "Sparkle", condition: .when([.macos])),
                .target(name: "YorozuNotificationService", condition: .when([.ios])),
                .target(name: "YorozuShare", condition: .when([.ios])),
            ],
            // Automatic signing plus `xcodebuild -allowProvisioningUpdates` and an App Store Connect key:
            // Xcode issues the distribution certificate and the App Store profiles (app and extension) itself.
            settings: signing([
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                // The Mac ships as 0.5's Mac app id, so Sparkle replaces it in place; iOS keeps the App Store id.
                "PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*]": "to.yumi.yorozu",
                // The plugin copy above reads the repo outside the target.
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            ])
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
        // Yorozu in the share sheet: text, one link, one picture or one file, handed to the app (`ShareInbox`). v1's bundle id.
        .target(
            name: "YorozuShare",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "to.yumi.yorozu.ios.share",
            deploymentTargets: .iOS("18.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "CFBundleDisplayName": "Yorozu",
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.share-services",
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ShareViewController",
                    "NSExtensionAttributes": [
                        "NSExtensionActivationRule": [
                            "NSExtensionActivationSupportsText": true,
                            "NSExtensionActivationSupportsWebURLWithMaxCount": 1,
                            "NSExtensionActivationSupportsImageWithMaxCount": 1,
                            "NSExtensionActivationSupportsFileWithMaxCount": 1,
                        ],
                    ],
                ],
            ]),
            sources: ["Sources/YorozuShare/**", "Sources/ShareInbox/**"],
            resources: ["Resources/Localizable.xcstrings"],
            entitlements: .dictionary(["com.apple.security.application-groups": [.string(appGroup)]]),
            settings: signing()
        ),
    ]
)
