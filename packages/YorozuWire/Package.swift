// swift-tools-version: 6.0
import PackageDescription

// The v1 relay wire (events, crypto, channel, RelayClient) shared by the Mac host and the iOS app.
let package = Package(
    name: "YorozuWire",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "YorozuWire", targets: ["YorozuWire"])],
    targets: [.target(name: "YorozuWire")]
)
