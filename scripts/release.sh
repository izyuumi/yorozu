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
# What dl.yumi.to actually serves: a static server over this directory behind a cloudflared
# tunnel. Overridable because a git worktree has a dist/ of its own that nothing serves.
DL=${DL:-$DIST/dl}

./scripts/build-mac.sh
./scripts/appcast.sh

mkdir -p "$DL"
cp "$DIST"/Yorozu-*.dmg "$DIST/appcast.xml" "$DL/"

TAG=$(git describe --tags --abbrev=0 --match 'v*')
gh release upload "$TAG" "$DIST"/Yorozu-*.dmg "$DIST/appcast.xml" --clobber

# The build number is what Sparkle compares, so it is what says whether this went anywhere.
grep -m1 '<sparkle:version>' "$DIST/appcast.xml"
