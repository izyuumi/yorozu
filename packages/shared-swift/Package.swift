// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YorozuShared",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "YorozuShared", targets: ["YorozuShared"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.19.0")],
    targets: [
        .target(
            name: "YorozuShared",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "YorozuFixtureGen", dependencies: ["YorozuShared"]),
        .executableTarget(name: "YorozuUIHarness", dependencies: ["YorozuShared"]),
        .testTarget(name: "YorozuSharedTests", dependencies: ["YorozuShared", .product(name: "SwiftTerm", package: "SwiftTerm")]),
    ]
)
