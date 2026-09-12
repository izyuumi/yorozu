// swift-tools-version: 6.0
import PackageDescription

/// Absolute, because `swift build --package-path apps/mac` is run from the repository root
/// and the linker flag below is resolved against the *invoking* directory, not this one.
let helperPlist = "\(String(#filePath.dropLast("Package.swift".count)))Sources/YorozuNative/Info.plist"

let package = Package(
    name: "YorozuMac",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../packages/shared-swift"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        // Every macOS privacy grant, as one description the app and the helper share.
        .target(name: "YorozuPermissions"),
        .executableTarget(
            name: "YorozuMac",
            dependencies: [
                "YorozuPermissions",
                .product(name: "YorozuShared", package: "shared-swift"),
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        // The native tool host the Node runtime spawns and talks JSON lines to.
        //
        // It is a bare executable rather than a bundle, so its Info.plist is linked into the
        // binary. Without it TCC denies every privacy request outright instead of prompting,
        // which is what broke calendar access under Yorozu.app. See that file's comment.
        .executableTarget(
            name: "yorozu-native",
            dependencies: ["YorozuPermissions"],
            path: "Sources/YorozuNative",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", helperPlist
                ])
            ]
        )
    ]
)
