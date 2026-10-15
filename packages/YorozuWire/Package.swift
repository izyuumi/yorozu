// swift-tools-version: 6.0
import PackageDescription

// Wire v3 (docs/ios-relay-contract.md): pairing, the Noise handshake, events and the relay connection of the client app.
let package = Package(
    name: "YorozuWire",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "YorozuWire", targets: ["YorozuWire"])],
    targets: [.target(name: "YorozuWire")]
)
