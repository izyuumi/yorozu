#!/bin/sh
# Compile the shipping session/store with fake network/UI boundaries. No real Keychain,
# pairing, relay, or sidecar is touched; builds and fixtures live in a temporary directory.
# Optional native view proof: --screenshot /tmp/yorozu-mac-hosts.png (also writes -details.png).
set -eu
YOROZU_CHECK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
export YOROZU_CHECK_ROOT
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yorozu-mac-multi-host.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT HUP INT TERM
mkdir -p "$CHECK_DIR/Sources/Check" "$CHECK_DIR/Sources/YorozuKeepalive"
ln -s "$YOROZU_CHECK_ROOT/apps/mac/Sources/YorozuMac/MacChatSession.swift" "$CHECK_DIR/Sources/Check/MacChatSession.swift"
ln -s "$YOROZU_CHECK_ROOT/apps/mac/Sources/YorozuMac/RelaySettings.swift" "$CHECK_DIR/Sources/Check/RelaySettings.swift"
ln -s "$YOROZU_CHECK_ROOT/scripts/check-mac-multi-host.swift" "$CHECK_DIR/Sources/Check/Check.swift"
ln -s "$YOROZU_CHECK_ROOT/apps/mac/Sources/YorozuKeepalive/Keepalive.swift" "$CHECK_DIR/Sources/YorozuKeepalive/Keepalive.swift"
cat > "$CHECK_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import Foundation
import PackageDescription
let root = ProcessInfo.processInfo.environment["YOROZU_CHECK_ROOT"]!
let package = Package(
    name: "MacMultiHostCheck",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: root + "/packages/shared-swift")],
    targets: [
        .target(name: "YorozuKeepalive"),
        .executableTarget(name: "Check", dependencies: [
            "YorozuKeepalive", .product(name: "YorozuShared", package: "shared-swift"),
        ]),
    ]
)
SWIFT
env -u SDKROOT swift run --package-path "$CHECK_DIR" Check "$@"
