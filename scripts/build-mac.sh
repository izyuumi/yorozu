#!/bin/sh
# Build the shipping Mac app: Yorozu.app with the Node runtime inside it, Developer ID
# signed with the hardened runtime, wrapped in a signed DMG, and notarized when there are
# credentials for it.
#
# The dev counterpart is scripts/dev-bundle.sh, which ad-hoc signs a bundle with no runtime
# in it. This one is what a stranger downloads, so everything it needs has to be inside.
set -eu
cd "$(dirname "$0")/.."

# Capture the caller's CI policy before enabling pnpm's non-interactive mode locally.
NOTARIZATION_REQUIRED=${REQUIRE_NOTARIZATION:-0}
if [ -n "${CI:-}" ]; then NOTARIZATION_REQUIRED=1; fi

# Every pnpm call here is non-interactive, and pnpm refuses to reconcile a modules
# directory without a TTY unless it believes it is in CI.
export CI=true

if ! command -v pnpm >/dev/null 2>&1; then
  pnpm() { corepack pnpm "$@"; }
fi

# Sparkle needs CFBundleVersion to rise across marketing versions and beta builds. Keep
# that machine number global; show the build count since this version's tag to users.
TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
VERSION=${VERSION:-${TAG#v}}
VERSION=${VERSION:-0.1.0}
VERSION_LABEL=${VERSION_LABEL:-$VERSION}
BUILD=${BUILD:-$(git rev-list --count HEAD)}
VERSION_BUILD=$(( $(git rev-list --count ${TAG:+$TAG..}HEAD) + 1 ))
DIST=${DIST:-dist}
IDENTITY=${IDENTITY:-"Developer ID Application: Yumi Izumi (AN5KM8QGEF)"}
# Overridable so a test install can be built with an id of its own. Two bundles sharing one
# id confuse LaunchServices about which of them `open -a` means, and the watchdog names its
# LaunchAgent and its pause file after this — see apps/mac Keepalive.swift.
BUNDLE_ID=${BUNDLE_ID:-to.yumi.yorozu}
NOTARY_PROFILE=${NOTARY_PROFILE-yorozu-notary}
FEED_URL=${FEED_URL:-https://yorozu.yumi.to/appcast.xml}
# The public half of the EdDSA key `generate_keys` put in the login keychain; the private
# half never leaves it, and scripts/appcast.sh signs each update with it.
SU_PUBLIC_KEY=${SU_PUBLIC_KEY:-pD6gPv1CP/XDvIJXbztjQRTIkgR/kfMMYT/Mpp8aQvI=}

APP="$DIST/Yorozu.app"
# The build number is in the name: two builds of the same tag are two different files, so
# neither the appcast nor a CDN can serve one where the other was meant.
DMG="$DIST/Yorozu-$VERSION-$BUILD.dmg"
STAGE="$DIST/stage"

# The app embeds shared + runtime. Relay is deployed separately and compiling it here adds work
# to every local package/release build without changing a byte in the bundle.
pnpm --filter @yorozu/shared --filter @yorozu/runtime build
env -u SDKROOT swift build --package-path apps/mac -c release
BIN="$(env -u SDKROOT swift build --package-path apps/mac -c release --show-bin-path | tail -1)"

rm -rf "$APP" "$STAGE" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN/YorozuMac" "$APP/Contents/MacOS/Yorozu"
# The native tool host ships inside the bundle so it shares the app's signature: TCC keys
# Accessibility and Screen Recording on that, and the helper is what needs them.
cp "$BIN/yorozu-native" "$APP/Contents/MacOS/yorozu-native"
cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"
# SwiftPM keeps package resources in a companion bundle. The Bundle.module accessor that
# `swift build` generates looks for it only at the app bundle's root, and codesign refuses a
# resource there, so YorozuShared's own accessor (ResourceBundle.swift) resolves it from
# Contents/Resources instead. Omitting it makes the first provider mark render trap even
# though the executable itself built and signed successfully.
cp -R "$BIN/YorozuShared_YorozuShared.bundle" "$APP/Contents/Resources/"
cp -R "$BIN/SwiftTerm_SwiftTerm.bundle" "$APP/Contents/Resources/"
# Which layout that bundle has depends on the toolchain. Swift 6.4 emits an Xcode-style
# bundle (Contents/Resources) and compiles the asset catalog itself; the CI toolchain behind
# build 282 emitted a flat bundle with the catalog copied raw, as the .xcassets folder of
# SVGs, and Image("ClaudeMark", bundle:) finds nothing in a folder. Only the raw layout
# needs help: compile it to Assets.car with actool, then drop the folder so only the
# compiled one ships. A bundle with no raw folder already has its catalog compiled.
SHARED_BUNDLE="$APP/Contents/Resources/YorozuShared_YorozuShared.bundle"
if [ -d "$SHARED_BUNDLE/ProviderMarks.xcassets" ]; then
  xcrun actool "$SHARED_BUNDLE/ProviderMarks.xcassets" --compile "$SHARED_BUNDLE" \
    --platform macosx --minimum-deployment-target 15.0 \
    --output-format human-readable-text --output-partial-info-plist "$(mktemp)" >/dev/null
  # actool exits 0 even when it compiled nothing (it only warns); a missing marks catalog
  # should end the build here, not show up as an empty provider row on a user's Mac.
  [ -f "$SHARED_BUNDLE/Assets.car" ] || { echo "actool produced no Assets.car" >&2; exit 1; }
  rm -rf "$SHARED_BUNDLE/ProviderMarks.xcassets"
  # That flat bundle also carries no Info.plist, and CoreUI will not look inside a catalog
  # whose bundle has no identifier: image(forResource:) quietly returns nil. Build 282
  # shipped exactly that. The Xcode-style layout brings Contents/Info.plist of its own.
  if [ ! -f "$SHARED_BUNDLE/Info.plist" ]; then
    cat >"$SHARED_BUNDLE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.YorozuShared</string>
  <key>CFBundleName</key><string>YorozuShared</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
</dict>
</plist>
PLIST
  fi
fi

# The icon. Xcode compiles apps/ios/Resources/AppIcon.icon straight into an asset catalog
# for iOS, but this bundle is assembled by hand and has no catalog, so it takes the .icns
# that scripts/icon-render.sh renders from the same artwork.
cp apps/mac/Resources/Yorozu.icns "$APP/Contents/Resources/Yorozu.icns"
xcrun xcstringstool compile apps/mac/Resources/Localizable.xcstrings \
  --output-directory "$APP/Contents/Resources"
# The watchdog, which is a resource rather than an executable on purpose: it has to be
# runnable by launchd when the app it supervises is not running at all.
cp apps/mac/Resources/watchdog.sh "$APP/Contents/Resources/watchdog.sh"
chmod +x "$APP/Contents/Resources/watchdog.sh"
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
curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt" -o "$DIST/SHASUMS256.txt"
# Check cached downloads too. Match the complete filename, not a similarly named asset.
grep -F "  $NODE_DIR.tar.gz" "$DIST/SHASUMS256.txt" | \
  awk -v name="$NODE_DIR.tar.gz" '$2 == name' > "$DIST/node-shasum.txt"
[ "$(wc -l < "$DIST/node-shasum.txt" | tr -d ' ')" = 1 ] || {
  echo "missing or ambiguous Node checksum for $NODE_DIR.tar.gz" >&2
  exit 1
}
(cd "$DIST" && shasum -a 256 -c node-shasum.txt)
rm -rf "${DIST:?}/${NODE_DIR:?}"
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
# pnpm deploy copies package file modes; node-pty's published helper needs execute permission.
sh scripts/fix-pty-helper.sh "$APP/Contents/Resources/runtime/node_modules/node-pty"
# --prod above leaves the *workspace* modules directory pruned to production too, which
# breaks the next `pnpm -r build` (no typescript). Put the dev dependencies back.
pnpm install --frozen-lockfile

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
  <key>CFBundleName</key><string>Yorozu</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleIconFile</key><string>Yorozu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>YorozuVersionBuild</key><string>$VERSION_BUILD</string>
  <key>YorozuVersionLabel</key><string>$VERSION_LABEL</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>to.yumi.yorozu.pair</string>
    <key>CFBundleURLSchemes</key><array><string>yorozu</string></array>
  </dict></array>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SU_PUBLIC_KEY</string>
  <!-- Updates install themselves: check hourly, download in the background, install without
       asking. Apps/mac Updater.swift forces the same three on once per machine, because these
       keys are only the initial value for a Mac that has no Sparkle preferences yet. -->
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUAllowsAutomaticUpdates</key><true/>
  <key>SUScheduledCheckInterval</key><integer>3600</integer>
$USAGE
</dict>
</plist>
PLIST

# Sign inside out without --deep: nested code has to be sealed before the bundle that
# contains it, and every binary should get only the entitlements it needs. `find -depth`
# lists a bundle after its contents; -type f skips the framework's symlinks (Sparkle ->
# Versions/Current/Sparkle), and a .framework path signs the Versions/Current bundle.
# Sparkle's helpers and XPC services keep their own sandbox entitlements. The Agent SDK's
# vendored `claude` is a Bun-built Mach-O with a JIT of its own, so it takes the same
# entitlements as node; every other nested binary gets none. The loop body is a subshell:
# `|| exit 1` makes a failed codesign end the pipeline, and set -e the script.
find "$APP/Contents" -depth \( -type f -o -type d \) -print | while IFS= read -r code; do
  case "$code" in
    "$APP/Contents/Resources/node"|"$APP/Contents/MacOS/yorozu-native"|"$APP/Contents/MacOS/Yorozu") continue ;;
  esac
  if [ -f "$code" ]; then
    case "$(file -b "$code")" in *Mach-O*) ;; *) continue ;; esac
  else
    case "$code" in *.framework|*.app|*.xpc) ;; *) continue ;; esac
  fi
  case "$code" in
    "$APP/Contents/Frameworks/Sparkle.framework"|"$APP/Contents/Frameworks/Sparkle.framework/"*)
      codesign --force --options runtime --timestamp \
        --preserve-metadata=entitlements,requirements,flags --sign "$IDENTITY" "$code" || exit 1
      ;;
    "$APP/Contents/Resources/runtime/node_modules/@anthropic-ai/claude-agent-sdk-darwin-"*/claude)
      codesign --force --options runtime --timestamp \
        --entitlements apps/mac/Node.entitlements --sign "$IDENTITY" "$code" || exit 1
      ;;
    *) codesign --force --options runtime --timestamp --sign "$IDENTITY" "$code" || exit 1 ;;
  esac
done
codesign --force --options runtime --timestamp \
  --entitlements apps/mac/Node.entitlements --sign "$IDENTITY" "$APP/Contents/Resources/node"
codesign --force --options runtime --timestamp \
  --entitlements apps/mac/Yorozu.entitlements --sign "$IDENTITY" "$APP/Contents/MacOS/yorozu-native"
codesign --force --options runtime --timestamp \
  --entitlements apps/mac/Yorozu.entitlements --sign "$IDENTITY" "$APP/Contents/MacOS/Yorozu"
codesign --force --options runtime --timestamp \
  --entitlements apps/mac/Yorozu.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Yorozu -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# Notarization needs an App Store Connect key stored as a keychain profile; see README.
# Local builds may skip a missing profile; CI and explicit release checks must fail closed.
# The profile is probed rather than assumed: `submit` with no credentials fails slowly and
# in the middle of a release build, which is the wrong place to find out.
if [ -n "$NOTARY_PROFILE" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
else
  if [ "$NOTARIZATION_REQUIRED" = 1 ]; then
    echo "notarization required: profile '$NOTARY_PROFILE' is missing or unusable" >&2
    exit 1
  fi
  echo "notarization skipped: no profile"
fi

if [ "$NOTARIZATION_REQUIRED" = 1 ]; then
  spctl --assess --type open --context context:primary-signature -v "$DMG"
else
  spctl --assess --type open --context context:primary-signature -v "$DMG" || true
fi
echo "$DMG"
echo "version $VERSION build $BUILD"
