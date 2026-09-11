// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YorozuMac",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../packages/shared-swift")],
    targets: [
        .executableTarget(
            name: "YorozuMac",
            dependencies: [.product(name: "YorozuShared", package: "shared-swift")]
        ),
        // The native tool host the Node runtime spawns and talks JSON lines to.
        .executableTarget(name: "yorozu-native", path: "Sources/YorozuNative")
    ]
)
