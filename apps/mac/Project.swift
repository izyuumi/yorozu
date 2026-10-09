import Foundation
import ProjectDescription

/// Generates Yorozu.xcworkspace (not checked in): `tuist generate --no-open --path apps/mac`.
/// Identity matches Yorozu v1 (bundle id, team, Developer ID) so this build updates it in place.
let versionFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../version.txt").standardizedFileURL
let version: String = {
    guard let raw = try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          raw.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
    else { fatalError("Expected numeric major.minor.patch in \(versionFile.path)") }
    return raw
}()

let project = Project(
    name: "Yorozu",
    packages: [.package(path: "../.."), .package(path: "../../packages/YorozuWire")],
    targets: [
        .target(
            name: "Yorozu",
            destinations: .macOS,
            product: .app,
            bundleId: "to.yumi.yorozu",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "CFBundleIconFile": "Yorozu",
                "NSAccentColorName": "AccentColor",
                "LSApplicationCategoryType": "public.app-category.productivity",
                "LSUIElement": true, // Menu-bar host: no Dock icon, no main window.
            ]),
            sources: ["../../Sources/ProjectXApp/**"],
            resources: ["Resources/Yorozu.icns", "Resources/Accent.xcassets", "Resources/Localizable.xcstrings"],
            entitlements: "Yorozu.entitlements",
            dependencies: [.package(product: "ProjectXCore"), .package(product: "YorozuWire")],
            settings: .settings(base: [
                "DEVELOPMENT_TEAM": "AN5KM8QGEF",
                "CODE_SIGN_STYLE": "Manual",
                "ENABLE_HARDENED_RUNTIME": "YES",
                "MARKETING_VERSION": .string(version),
                "CURRENT_PROJECT_VERSION": "1",
            ], configurations: [
                // Identity and timestamp flag: Signing.xcconfig, overridden by the gitignored Signing.local.xcconfig.
                .debug(name: .debug, xcconfig: "Signing.xcconfig"),
                .release(name: .release, xcconfig: "Signing.xcconfig"),
            // Tuist's defaults would set the identity at target level, over the xcconfig.
            ], defaultSettings: .recommended(excluding: ["CODE_SIGN_IDENTITY"]))
        ),
    ]
)
