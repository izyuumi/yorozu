#!/bin/sh
# Wrap the `swift build` product in a minimal .app bundle and ad-hoc sign it.
#
# TCC keys grants by bundle ID and code signature. A bare `swift run` binary has neither. This
# beta bundle deliberately defaults to an identity separate from the installed stable app; callers
# can override it when they explicitly need the long-lived development identity.
set -eu
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-debug}
APP=${APP:-apps/mac/.build/Yorozu.app}
BUNDLE_ID=${BUNDLE_ID:-to.yumi.yorozu.beta}
DISPLAY_NAME=${DISPLAY_NAME:-Yorozu Beta}
SHORT_VERSION=${SHORT_VERSION:-$(cat version.txt)}
VERSION_LABEL=${VERSION_LABEL:-$SHORT_VERSION-beta}

swift build --package-path apps/mac -c "$CONFIG"
BIN="$(swift build --package-path apps/mac -c "$CONFIG" --show-bin-path)/YorozuMac"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Yorozu"
# The native tool host ships inside the bundle so it shares the app's signature: TCC keys
# Accessibility and Screen Recording on that, and the helper is what actually needs them.
cp "$(dirname "$BIN")/yorozu-native" "$APP/Contents/MacOS/yorozu-native"
# SwiftPM keeps the provider marks in a companion bundle. AgentMarkView loads it from
# Contents/Resources; Bundle.module can point at the build directory.
cp -R "$(dirname "$BIN")/YorozuShared_YorozuShared.bundle" "$APP/Contents/Resources/"
cp -R "$(dirname "$BIN")/SwiftTerm_SwiftTerm.bundle" "$APP/Contents/Resources/"
# SwiftPM's CLI build can leave the catalog uncompiled. Match the shipping bundle.
MARKS="$APP/Contents/Resources/YorozuShared_YorozuShared.bundle"
if [ ! -f "$MARKS/Contents/Resources/Assets.car" ]; then
  mkdir -p "$MARKS/Contents/Resources"
  cat > "$MARKS/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>shared-swift.YorozuShared.resources</string>
  <key>CFBundleName</key><string>YorozuShared_YorozuShared</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
  xcrun actool packages/shared-swift/Sources/YorozuShared/Resources/ProviderMarks.xcassets \
    --compile "$MARKS/Contents/Resources" --platform macosx \
    --minimum-deployment-target 15.0 --output-partial-info-plist /dev/null >/dev/null
fi

# Sparkle, and the rpath that finds it. Same two steps as scripts/build-mac.sh and for the
# same reason: SwiftPM links the framework as @rpath but only gives the binary @loader_path,
# which in a bundle is Contents/MacOS, so without this the app dies at launch with "Library
# not loaded". Before signing — install_name_tool rewrites the binary.
cp -R "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Yorozu"

# The icon. Xcode compiles apps/ios/Resources/AppIcon.icon straight into an asset catalog
# for iOS, but this bundle is assembled by hand and has no catalog, so it takes the .icns
# that scripts/icon-render.sh renders from the same artwork.
cp apps/mac/Resources/Yorozu.icns "$APP/Contents/Resources/Yorozu.icns"
# The app's accent — YorozuPalette.vermilion — which macOS then uses for sidebar selection
# and controls while the user's system accent is left at Multicolor. Only an asset catalog
# can carry it, so the one colour is compiled here.
ACCENT_RESOURCES="$(cd "$APP/Contents/Resources" && pwd)"
xcrun actool "$PWD/apps/mac/Resources/Accent.xcassets" --compile "$ACCENT_RESOURCES" \
  --platform macosx --minimum-deployment-target 15.0 \
  --output-partial-info-plist /dev/null >/dev/null
[ -f "$ACCENT_RESOURCES/Assets.car" ] || { echo "actool produced no accent Assets.car" >&2; exit 1; }
xcrun xcstringstool compile apps/mac/Resources/Localizable.xcstrings \
  --output-directory "$APP/Contents/Resources"

# The NS…UsageDescription strings, taken from the helper's own Info.plist rather than
# written out again here: TCC reads them from whichever binary is asking, so the app and
# the helper both need the same set, and two copies would drift. See that file.
USAGE=$(sed -n '/<key>NS/,/<\/string>/p' apps/mac/Sources/YorozuNative/Info.plist)

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Yorozu</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleIconFile</key><string>Yorozu</string>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>YorozuVersionLabel</key><string>$VERSION_LABEL</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>$BUNDLE_ID.pair</string>
    <key>CFBundleURLSchemes</key><array><string>yorozu</string></array>
  </dict></array>
$USAGE
</dict>
</plist>
PLIST

codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
echo "$APP"
