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
            ]),
            sources: ["../../Sources/ProjectXApp/**"],
            resources: ["Resources/Yorozu.icns", "Resources/Accent.xcassets"],
            entitlements: "Yorozu.entitlements",
            dependencies: [.package(product: "ProjectXCore"), .package(product: "YorozuWire")],
            settings: .settings(base: [
                "DEVELOPMENT_TEAM": "AN5KM8QGEF",
                "CODE_SIGN_STYLE": "Manual",
                "CODE_SIGN_IDENTITY": "Developer ID Application: Yumi Izumi (AN5KM8QGEF)",
                "ENABLE_HARDENED_RUNTIME": "YES",
                "OTHER_CODE_SIGN_FLAGS": "--timestamp",
                "MARKETING_VERSION": .string(version),
                "CURRENT_PROJECT_VERSION": "1",
            ])
        ),
    ]
)
