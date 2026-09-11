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
        )
    ]
)
