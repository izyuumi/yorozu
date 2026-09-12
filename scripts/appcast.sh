#!/bin/sh
# Regenerate the Sparkle appcast from whatever DMGs are sitting in dist/.
#
# generate_appcast signs each update with the private EdDSA key in the login keychain (the
# one `generate_keys` put there) and writes dist/appcast.xml, which is uploaded to the
# GitHub Release next to the DMG. Its public half is in the app's Info.plist.
set -eu
cd "$(dirname "$0")/.."

DIST=${DIST:-dist}
DOWNLOAD_PREFIX=${DOWNLOAD_PREFIX:-https://dl.yumi.to/}

# Shipped inside the Sparkle package, so `swift build` is what installs it.
TOOL="$(find apps/mac/.build/artifacts -name generate_appcast -type f -perm -u+x 2>/dev/null | head -1)"
[ -n "$TOOL" ] || {
  echo "Sparkle tools missing: run swift build --package-path apps/mac first" >&2
  exit 1
}

# The key comes out of the keychain by default. On a machine where the keychain refuses
# `generate_appcast` access without a click — which is a headless release hanging on an
# invisible dialog — export it once into a file only this run can read:
#
#   KEY=$(mktemp -d)/ed && generate_keys -x "$KEY" && SPARKLE_ED_KEY_FILE=$KEY ./scripts/appcast.sh; rm -rf "$(dirname "$KEY")"
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then
  "$TOOL" --ed-key-file "$SPARKLE_ED_KEY_FILE" --download-url-prefix "$DOWNLOAD_PREFIX" "$DIST"
else
  "$TOOL" --download-url-prefix "$DOWNLOAD_PREFIX" "$DIST"
fi
echo "$DIST/appcast.xml"
