#!/bin/sh
# Cut a release: build the Mac app, notarize it, sign an appcast for it, and publish both.
#
# Nothing is bumped by hand — scripts/build-mac.sh derives the marketing version from the
# latest v* tag and the build number from the commit count, so the only thing a release
# needs is a tag (and a commit, for a rebuild of the same tag to be newer than the last).
#
#   git tag -a v0.2.0 -m v0.2.0 && ./scripts/release.sh
set -eu
cd "$(dirname "$0")/.."

DIST=${DIST:-dist}
# Public downloads: the rolling `mac` release of this public repo. yorozu.yumi.to/mac,
# /appcast.xml and /download/* redirect there (apps/web/public/_redirects).
PUBLIC=${PUBLIC:-izyuumi/yorozu}

./scripts/build-mac.sh
./scripts/appcast.sh

# Only the DMGs the appcast offers, not every old build in dist/, plus Yorozu.dmg: a stable
# name for /mac, always the build just made.
DMGS=$(grep -o 'download/Yorozu-[^"]*\.dmg' "$DIST/appcast.xml" | sed "s#^download/#$DIST/#")
STABLE=$(mktemp -d "$DIST/stable.XXXXXX")/Yorozu.dmg
ln "$(ls -t "$DIST"/Yorozu-*.dmg | head -1)" "$STABLE"
# shellcheck disable=SC2086 # one path per DMG, none with spaces
gh release upload mac --repo "$PUBLIC" $DMGS "$STABLE" "$DIST/appcast.xml" --clobber
rm -rf "$(dirname "$STABLE")"

TAG=$(git describe --tags --abbrev=0 --match 'v*')
gh release upload "$TAG" "$DIST"/Yorozu-*.dmg "$DIST/appcast.xml" --clobber

# The build number is what Sparkle compares, so it is what says whether this went anywhere.
grep -m1 '<sparkle:version>' "$DIST/appcast.xml"
