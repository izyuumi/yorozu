import Foundation
import ProjectDescription

let versionFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../version.txt").standardizedFileURL
let version: String = {
    guard let raw = try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          raw.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
    else { fatalError("Expected numeric major.minor.patch in \(versionFile.path)") }
    return raw
}()

func bundleVersion(build: Int) -> String {
    let p = version.split(separator: ".").compactMap { Int($0) }
    guard p[1] < 100, p[2] < 100, (1..<1000).contains(build) else { fatalError("Version \(version) build \(build) overflows CFBundleVersion") }
    return String(p[0] * 10_000_000 + p[1] * 100_000 + p[2] * 1_000 + build)
}

let notificationKeychainGroup = "$(AppIdentifierPrefix)to.yumi.yorozu.notifications"
// The pairing lives in the app's default Keychain group (the first entry below, which equals the app's
// identifier, so items saved before the entitlement existed are there too). The share extension lists the
// same group first to read it. Reordering or renaming it would hide existing pairings and unpair devices.
let pairingKeychainGroup = "$(AppIdentifierPrefix)to.yumi.yorozu.ios"
let appGroup = "group.to.yumi.yorozu"
// llama.cpp's xcframework (voice input) has no iOS Simulator slice: `TUIST_VOICE_INPUT=0 tuist generate` leaves
// it out, for simulator builds.
let voiceInput = Environment.voiceInput.getBoolean(default: true)
func signing(_ extra: SettingsDictionary = [:]) -> Settings {
    .settings(base: [
        "DEVELOPMENT_TEAM": "AN5KM8QGEF",
        "CODE_SIGN_STYLE": "Automatic",
        "MARKETING_VERSION": .string(version),
        "CURRENT_PROJECT_VERSION": .string(bundleVersion(build: 1)),
        "YOROZU_BUILD": "1",
    ].merging(extra) { _, new in new })
}

let project = Project(
    name: "Yorozu",
    packages: [
        .local(path: "../../packages/YorozuWire"),
        .remote(url: "https://github.com/sparkle-project/Sparkle", requirement: .upToNextMajor(from: "2.9.0")),
    ] + (voiceInput ? [.local(path: "../../packages/Llama")] : []),
    targets: [
        .target(
            name: "YorozuIOS",
            destinations: [.iPhone, .iPad, .mac],
            product: .app,
            bundleId: "to.yumi.yorozu.ios",
            deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "YorozuBuild": "$(YOROZU_BUILD)",
                "SUFeedURL": "https://yorozu.yumi.to/appcast.xml",
                "SUPublicEDKey": "pD6gPv1CP/XDvIJXbztjQRTIkgR/kfMMYT/Mpp8aQvI=",
                "SUEnableAutomaticChecks": true,
                "SUAutomaticallyUpdate": true,
                "SUAllowsAutomaticUpdates": true,
                "SUScheduledCheckInterval": 3600,
                "UILaunchStoryboardName": "LaunchScreen",
                "ITSAppUsesNonExemptEncryption": false,
                "CFBundleDisplayName": "Yorozu",
                "CFBundleName": "Yorozu",
                "LSApplicationCategoryType": "public.app-category.productivity",
                "NSCameraUsageDescription": "Yorozu scans the pairing QR code shown by your Mac, and takes photos you choose to send in a message.",
                "NSPhotoLibraryAddUsageDescription": "Yorozu saves pictures to your library when you ask it to.",
                "NSMicrophoneUsageDescription": "Yorozu turns what you say into a message, on this device, when you use voice input.",
                "UIBackgroundModes": ["remote-notification"],
                "YorozuNotificationKeychainAccessGroup": .string(notificationKeychainGroup),
                "UTExportedTypeDeclarations": [
                    [
                        "UTTypeIdentifier": "to.yumi.yorozu.conversation",
                        "UTTypeDescription": "Yorozu Conversation",
                        "UTTypeConformsTo": ["public.data"],
                    ]
                ],
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
                .glob(pattern: "Resources/LaunchScreen.storyboard", inclusionCondition: .when([.ios])),
                "Resources/Assets.xcassets",
                "Resources/AppShortcuts.xcstrings",
                "Resources/InfoPlist.xcstrings",
                "Resources/Localizable.xcstrings",
                "Resources/PrivacyInfo.xcprivacy",
            ],
            entitlements: .dictionary([
                "aps-environment": "production",
                "com.apple.developer.associated-domains": ["applinks:yorozu.yumi.to"],
                "keychain-access-groups": [.string(pairingKeychainGroup), .string(notificationKeychainGroup)],
                "com.apple.security.application-groups": [.string(appGroup)],
            ]),
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
                    outputPaths: ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/openclaw-channel"],
                    basedOnDependencyAnalysis: false
                ),
            ],
            dependencies: [
                .package(product: "YorozuWire"),
                .package(product: "Sparkle", condition: .when([.macos])),
                .target(name: "YorozuNotificationService", condition: .when([.ios])),
                .target(name: "YorozuShare", condition: .when([.ios])),
            ] + (voiceInput ? [.package(product: "llama")] : []),
            settings: signing([
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*]": "to.yumi.yorozu",
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            ])
        ),
        .target(
            name: "YorozuNotificationService",
            destinations: [.iPhone, .iPad],
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
            resources: ["Resources/Localizable.xcstrings"],
            entitlements: .dictionary(["keychain-access-groups": [.string(notificationKeychainGroup)]]),
            dependencies: [.package(product: "YorozuWire")],
            settings: signing()
        ),
        .target(
            name: "YorozuShare",
            destinations: [.iPhone, .iPad],
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
            entitlements: .dictionary([
                "keychain-access-groups": [.string(pairingKeychainGroup)],
                "com.apple.security.application-groups": [.string(appGroup)],
            ]),
            dependencies: [.package(product: "YorozuWire")],
            settings: signing()
        ),
    ]
)
