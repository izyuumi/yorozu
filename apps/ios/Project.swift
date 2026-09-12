import ProjectDescription

/// Generates `Yorozu.xcworkspace`, which is *not* checked in: CI and the e2e harness run
/// `tuist generate --path apps/ios --no-open` first. Re-run it after changing this file.
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
            infoPlist: .extendingDefault(with: [
                "UILaunchScreen": [:],
                "ITSAppUsesNonExemptEncryption": false,
                "CFBundleDisplayName": "Yorozu",
                "NSCameraUsageDescription": "Yorozu scans the pairing QR code shown by your Mac.",
                // `yorozu://pair?...` is the pairing string itself: tapping one opens the app.
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "to.yumi.yorozu.pair",
                        "CFBundleURLSchemes": ["yorozu"],
                    ]
                ],
                // Both are build settings so that scripts/build-ios.sh can pass the version
                // and the build number on the xcodebuild command line rather than editing a
                // generated file that tuist rewrites on the next run.
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            ]),
            sources: ["Sources/YorozuIOS/**"],
            resources: ["Resources/**"],
            dependencies: [.package(product: "YorozuShared")],
            settings: .settings(base: [
                // Automatic signing plus `xcodebuild -allowProvisioningUpdates` and an App
                // Store Connect key: Xcode issues the distribution certificate and the App
                // Store profile itself, so there is no .p12 or .mobileprovision to carry.
                "DEVELOPMENT_TEAM": "AN5KM8QGEF",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "CODE_SIGN_STYLE": "Automatic",
                "MARKETING_VERSION": "0.1.0",
                "CURRENT_PROJECT_VERSION": "1",
            ])
        )
    ]
)
