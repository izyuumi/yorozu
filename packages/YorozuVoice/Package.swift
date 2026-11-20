// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YorozuVoice",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "VoiceText", targets: ["VoiceText"]),
        .library(name: "SpeechEngines", targets: ["SpeechEngines"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.0", traits: []),
    ],
    targets: [
        .target(name: "VoiceText"),
        .target(
            name: "SpeechEngines",
            dependencies: [
                "VoiceText",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(name: "VoiceTextTests", dependencies: ["VoiceText"]),
    ]
)
