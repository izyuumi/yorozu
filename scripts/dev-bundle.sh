#!/bin/sh
# Wrap the `swift build` product in a minimal .app bundle and ad-hoc sign it.
#
# TCC keys grants by bundle ID and code signature. A bare `swift run` binary has neither, so
# every rebuild looks like a new app and every permission has to be granted again. Running
# the app out of this bundle gives it a stable identity (to.yumi.yorozu) and grants stick.
set -eu
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-debug}
APP=${APP:-apps/mac/.build/Yorozu.app}

swift build --package-path apps/mac -c "$CONFIG"
BIN="$(swift build --package-path apps/mac -c "$CONFIG" --show-bin-path)/YorozuMac"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Yorozu"
# The native tool host ships inside the bundle so it shares the app's signature: TCC keys
# Accessibility and Screen Recording on that, and the helper is what actually needs them.
cp "$(dirname "$BIN")/yorozu-native" "$APP/Contents/MacOS/yorozu-native"

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
  <key>CFBundleIdentifier</key><string>to.yumi.yorozu</string>
  <key>CFBundleName</key><string>Yorozu</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleIconFile</key><string>Yorozu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
$USAGE
</dict>
</plist>
PLIST

codesign --force --sign - --identifier to.yumi.yorozu "$APP"
echo "$APP"
