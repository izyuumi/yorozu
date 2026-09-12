import ProjectDescription

/// Generates `Yorozu.xcworkspace`, which is *not* checked in: CI and the e2e harness run
/// `tuist generate --path apps/ios --no-open` first. Re-run it after changing this file.

/// The App Group is the only thing the three targets share at runtime: the share extension
/// writes into it and the app reads out of it. Nothing secret goes in there — see `ShareBox`.
let appGroup = "group.to.yumi.yorozu"

/// Automatic signing plus `xcodebuild -allowProvisioningUpdates` and an App Store Connect key:
/// Xcode issues the distribution certificate and the App Store profiles itself, so there is no
/// .p12 or .mobileprovision to carry — for the extensions as much as for the app, which is why
/// this is shared rather than written out three times.
func signing(_ extra: SettingsDictionary = [:]) -> Settings {
    .settings(
        base: [
            "DEVELOPMENT_TEAM": "AN5KM8QGEF",
            "CODE_SIGN_STYLE": "Automatic",
            "MARKETING_VERSION": "0.1.0",
            "CURRENT_PROJECT_VERSION": "1",
        ].merging(extra) { _, new in new }
    )
}

/// Both are build settings so that scripts/build-ios.sh can pass the version and the build
/// number on the xcodebuild command line rather than editing a generated file that tuist
/// rewrites on the next run. Every target in the app has to carry the same pair, or the
/// embedded extensions are rejected at upload for disagreeing with their host.
let version: [String: Plist.Value] = [
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
]

let project = Project(
    name: "Yorozu",
    packages: [.local(path: "../../packages/shared-swift")],
    targets: [
        .target(
            name: "YorozuIOS",
            destinations: .iOS,
            product: .app,
            bundleId: "to.yumi.yorozu.ios",
            deploymentTargets: .iOS("18.0"),
            infoPlist: .extendingDefault(with: version.merging([
                "UILaunchScreen": [:],
                "ITSAppUsesNonExemptEncryption": false,
                "CFBundleDisplayName": "Yorozu",
                "NSCameraUsageDescription": "Yorozu scans the pairing QR code shown by your Mac.",
                // Dictation in the composer: the mic to hear it and recognition to write it
                // down. On-device wherever the language supports it.
                "NSMicrophoneUsageDescription": "Yorozu listens while you dictate a message, and only then.",
                "NSSpeechRecognitionUsageDescription": "Yorozu turns what you dictate into the message you send, on this device where your language supports it.",
                // The lock screen activity for a turn running while the phone is in a pocket.
                "NSSupportsLiveActivities": true,
                // No `…Frequent Updates`: every update here is local and there are only ever a
                // handful of them in a turn, so asking for the unbudgeted rate would be asking
                // for something this does not use.
                // `yorozu://pair?…` is the pairing string itself: tapping one opens the app.
                // `yorozu://thread/<id>` is a Live Activity being tapped, and
                // `yorozu://share?token=…` is the share extension handing over.
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "to.yumi.yorozu.pair",
                        "CFBundleURLSchemes": ["yorozu"],
                    ]
                ],
            ]) { a, _ in a }),
            sources: ["Sources/YorozuIOS/**"],
            resources: ["Resources/**"],
            entitlements: .dictionary(["com.apple.security.application-groups": [.string(appGroup)]]),
            dependencies: [
                .package(product: "YorozuShared"),
                // Embedded in the app's PlugIns, which is how an extension ships at all.
                .target(name: "YorozuShare"),
                .target(name: "YorozuActivity"),
            ],
            settings: signing(["ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"])
        ),
        .target(
            name: "YorozuShare",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "to.yumi.yorozu.ios.share",
            deploymentTargets: .iOS("18.0"),
            infoPlist: .extendingDefault(with: version.merging([
                "CFBundleDisplayName": "Yorozu",
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.share-services",
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ShareViewController",
                    // Exactly what the composer can draw and the runtime can be told about: a
                    // selection of text, a web link, or one picture. A rule that claimed more
                    // would put Yorozu in share sheets it has nothing to offer.
                    "NSExtensionAttributes": [
                        "NSExtensionActivationRule": [
                            "NSExtensionActivationSupportsText": true,
                            "NSExtensionActivationSupportsWebURLWithMaxCount": 1,
                            "NSExtensionActivationSupportsImageWithMaxCount": 1,
                        ]
                    ],
                ],
            ]) { a, _ in a }),
            sources: ["Sources/YorozuShare/**"],
            entitlements: .dictionary(["com.apple.security.application-groups": [.string(appGroup)]]),
            dependencies: [.package(product: "YorozuShared")],
            settings: signing()
        ),
        .target(
            name: "YorozuActivity",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "to.yumi.yorozu.ios.activity",
            deploymentTargets: .iOS("18.0"),
            infoPlist: .extendingDefault(with: version.merging([
                "CFBundleDisplayName": "Yorozu",
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.widgetkit-extension"
                ],
            ]) { a, _ in a }),
            sources: ["Sources/YorozuActivity/**"],
            // The group is not read here — the activity is handed its state by the app — but the
            // entitlement has to match the app's for the three to share one App Store profile
            // family, and it costs nothing.
            entitlements: .dictionary(["com.apple.security.application-groups": [.string(appGroup)]]),
            dependencies: [.package(product: "YorozuShared")],
            settings: signing()
        ),
    ]
)
