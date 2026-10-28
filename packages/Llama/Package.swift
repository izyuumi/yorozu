// swift-tools-version: 6.0
import PackageDescription

// llama.cpp's Apple build for on-device voice input; b11954 is the first release that runs LFM3-Audio.
// It has no iOS Simulator slice, so the app builds for devices and the Mac only.
let package = Package(
    name: "Llama",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "llama", targets: ["llama"])],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11954/llama-b11954-xcframework.zip",
            checksum: "dd8469e0d8d2396b245128cecfbe7164e37a7c110bf2b5b3ebec447ca739bc64"
        ),
    ]
)
