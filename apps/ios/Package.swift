// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YorozuIOS",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "YorozuIOS", targets: ["YorozuIOS"])],
    dependencies: [.package(path: "../../packages/shared-swift")],
    targets: [
        .target(
            name: "YorozuIOS",
            dependencies: [.product(name: "YorozuShared", package: "shared-swift")]
        )
    ]
)
