#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD"
mkdir -p build .build/tmp .build/module-cache
export TMPDIR="$ROOT/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
swift build -c release --cache-path .build/dependency-cache --config-path .build/config --security-path .build/security
BIN=$(swift build -c release --cache-path .build/dependency-cache --config-path .build/config --security-path .build/security --show-bin-path)
APP_NAME="${PROJECTX_APP_NAME:-PROJECTX}"
case "$APP_NAME" in *[!A-Za-z0-9-]*|'') echo "Invalid project-local app name" >&2; exit 2;; esac
APP="$ROOT/build/$APP_NAME.app"
if [ -f "$APP/Contents/MacOS/PROJECTX" ] && /usr/sbin/lsof -t "$APP/Contents/MacOS/PROJECTX" >/dev/null 2>&1; then
    echo "Refusing to replace a running app. Coordinate closure, or stage with PROJECTX_APP_NAME=PROJECTX-QA-fixed." >&2
    exit 3
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PROJECTX" "$APP/Contents/MacOS/PROJECTX"
# SwiftPM's GRDB resource bundle holds its privacy manifest, not executable plugins.
for BUNDLE in "$BIN"/*.bundle; do
    if [ -d "$BUNDLE" ]; then cp -R "$BUNDLE" "$APP/Contents/Resources/"; fi
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PROJECTX</string>
<key>CFBundleIdentifier</key><string>local.projectx.native.r1</string>
<key>CFBundleName</key><string>PROJECTX</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
# Local ad-hoc signature only; no account, identity, network or notarization.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
shasum -a 256 "$APP/Contents/MacOS/PROJECTX" > build/native-sha256.txt
printf '\nNative app (not launched): %s\n' "$APP"
