// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YorozuWire",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "YorozuWire", targets: ["YorozuWire"])],
    targets: [.target(name: "YorozuWire")]
)
