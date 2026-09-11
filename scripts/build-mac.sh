#!/bin/sh
# Build the shipping Mac app: Yorozu.app with the Node runtime inside it, Developer ID
# signed with the hardened runtime, wrapped in a signed DMG, and notarized when there are
# credentials for it.
#
# The dev counterpart is scripts/dev-bundle.sh, which ad-hoc signs a bundle with no runtime
# in it. This one is what a stranger downloads, so everything it needs has to be inside.
set -eu
cd "$(dirname "$0")/.."

# Every pnpm call here is non-interactive, and pnpm refuses to reconcile a modules
# directory without a TTY unless it believes it is in CI.
export CI=true

VERSION=${VERSION:-0.1.0}
DIST=${DIST:-dist}
IDENTITY=${IDENTITY:-"Developer ID Application: Yumi Izumi (AN5KM8QGEF)"}
NOTARY_PROFILE=${NOTARY_PROFILE:-yorozu-notary}
FEED_URL=${FEED_URL:-https://github.com/izyuumi/yorozu/releases/latest/download/appcast.xml}
# The public half of the EdDSA key `generate_keys` put in the login keychain; the private
# half never leaves it, and scripts/appcast.sh signs each update with it.
SU_PUBLIC_KEY=${SU_PUBLIC_KEY:-pD6gPv1CP/XDvIJXbztjQRTIkgR/kfMMYT/Mpp8aQvI=}

APP="$DIST/Yorozu.app"
DMG="$DIST/Yorozu-$VERSION.dmg"
STAGE="$DIST/stage"

pnpm -r build
env -u SDKROOT swift build --package-path apps/mac -c release
BIN="$(env -u SDKROOT swift build --package-path apps/mac -c release --show-bin-path | tail -1)"

rm -rf "$APP" "$STAGE" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN/YorozuMac" "$APP/Contents/MacOS/Yorozu"
# The native tool host ships inside the bundle so it shares the app's signature: TCC keys
# Accessibility and Screen Recording on that, and the helper is what needs them.
cp "$BIN/yorozu-native" "$APP/Contents/MacOS/yorozu-native"
cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"
# SwiftPM links Sparkle as @rpath but only gives the binary @loader_path, which in a bundle
# is Contents/MacOS. Point it at Contents/Frameworks, where the framework actually is, or
# the app dies at launch with "Library not loaded". Before signing: this rewrites the binary.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Yorozu"

# The runtime: a self-contained node next to the built sidecar and its production
# dependencies. `pnpm deploy` resolves the workspace links into a self-contained tree;
# --legacy because this workspace does not inject workspace packages.
#
# Not *this machine's* node: a Homebrew node is a stub against @rpath/libnode.<abi>.dylib
# plus a dozen more Homebrew dylibs, none of which are in the bundle, so it dies on a
# stranger's Mac (and on ours) with "Library not loaded". The nodejs.org build links only
# system frameworks, which is the whole reason the app can claim to need nothing installed.
# Cached in $DIST, which survives the rm above and is gitignored.
NODE_VERSION=${NODE_VERSION:-$(node --version)}
case "$(uname -m)" in
  arm64) NODE_ARCH=darwin-arm64 ;;
  x86_64) NODE_ARCH=darwin-x64 ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
NODE_DIR="node-$NODE_VERSION-$NODE_ARCH"
mkdir -p "$DIST"
[ -f "$DIST/$NODE_DIR.tar.gz" ] || \
  curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/$NODE_DIR.tar.gz" -o "$DIST/$NODE_DIR.tar.gz"
rm -rf "$DIST/$NODE_DIR"
mkdir -p "$DIST/$NODE_DIR"
tar -xzf "$DIST/$NODE_DIR.tar.gz" -C "$DIST/$NODE_DIR" --strip-components=1
cp "$DIST/$NODE_DIR/bin/node" "$APP/Contents/Resources/node"
# A node that cannot start makes a DMG that cannot work; fail here, not on a user's Mac.
"$APP/Contents/Resources/node" --version >/dev/null
rm -rf "$APP/Contents/Resources/runtime"
# node-linker=hoisted: pnpm's default layout is a thicket of symlinks into .pnpm, and
# codesign refuses to seal a bundle containing them ("invalid destination for symbolic
# link in bundle"). Hoisted is the flat node_modules the signature can cover.
pnpm --filter @yorozu/runtime --prod --legacy --config.node-linker=hoisted \
  deploy "$APP/Contents/Resources/runtime"
# --prod above leaves the *workspace* modules directory pruned to production too, which
# breaks the next `pnpm -r build` (no typescript). Put the dev dependencies back.
pnpm install --frozen-lockfile

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Yorozu</string>
  <key>CFBundleIdentifier</key><string>to.yumi.yorozu</string>
  <key>CFBundleName</key><string>Yorozu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SU_PUBLIC_KEY</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Yorozu drives Calendar, Mail, Reminders and System Events on your behalf.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Yorozu reads and writes your calendar when you ask it to.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Yorozu reads and writes your calendar when you ask it to.</string>
  <key>NSRemindersUsageDescription</key>
  <string>Yorozu reads and writes your reminders when you ask it to.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Yorozu reads and writes your reminders when you ask it to.</string>
  <key>NSSystemAdministrationUsageDescription</key>
  <string>Yorozu needs Full Disk Access to read and write files anywhere you can.</string>
</dict>
</plist>
PLIST

# Sign inside out: nested code has to be sealed before the bundle that contains it.
# --deep does exactly that walk, and every binary in here wants the same entitlements.
codesign --force --deep --timestamp --options runtime \
  --entitlements apps/mac/Yorozu.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Yorozu -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# Notarization needs an App Store Connect key stored as a keychain profile; see README.
# Without one the DMG is still Developer ID signed, which is a worse first-launch story
# (Gatekeeper asks) but a working one, so a missing profile is skipped, not a failure.
# The profile is probed rather than assumed: `submit` with no credentials fails slowly and
# in the middle of a release build, which is the wrong place to find out.
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
else
  echo "notarization skipped: no profile"
fi

spctl --assess --type open --context context:primary-signature -v "$DMG" || true
echo "$DMG"
