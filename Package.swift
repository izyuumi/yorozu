// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "PROJECTX", platforms: [.macOS(.v14)],
    products: [.library(name: "ProjectXCore", targets: ["ProjectXCore"]), .executable(name: "PROJECTX", targets: ["ProjectXApp"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0")],
    targets: [.target(name: "ProjectXCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
              .executableTarget(name: "ProjectXApp", dependencies: ["ProjectXCore"]),
              .testTarget(name: "ProjectXCoreTests", dependencies: ["ProjectXCore", .product(name: "GRDB", package: "GRDB.swift")])])
