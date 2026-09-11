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
                "NSCameraUsageDescription": "Yorozu scans the pairing QR code shown by your Mac.",
            ]),
            sources: ["Sources/YorozuIOS/**"],
            dependencies: [.package(product: "YorozuShared")]
        )
    ]
)
