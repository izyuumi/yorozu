// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YorozuShared",
    // watchOS is for `YorozuWatchLink` alone: `YorozuShared` is never built for the watch.
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11)],
    products: [
        .library(name: "YorozuShared", targets: ["YorozuShared"]),
        .library(name: "YorozuWatchLink", targets: ["YorozuWatchLink"]),
    ],
    targets: [
        .target(name: "YorozuWatchLink"),
        .testTarget(name: "YorozuWatchLinkTests", dependencies: ["YorozuWatchLink"]),
        .target(
            name: "YorozuShared",
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "YorozuFixtureGen", dependencies: ["YorozuShared"]),
        .executableTarget(name: "YorozuUIHarness", dependencies: ["YorozuShared"]),
        .testTarget(name: "YorozuSharedTests", dependencies: ["YorozuShared"]),
    ]
)
