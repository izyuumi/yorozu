// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YorozuShared",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "YorozuShared", targets: ["YorozuShared"])],
    targets: [.target(name: "YorozuShared")]
)
