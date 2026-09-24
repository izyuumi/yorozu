#!/bin/sh
# Publish the signed main build to a rolling prerelease and a separate Sparkle beta feed.
set -eu
cd "$(dirname "$0")/.."

DIST=${DIST:-dist}
PUBLIC=${PUBLIC:-izyuumi/yorozu}
BETA_TAG=${BETA_TAG:-main-beta}
BETA_REMOTE=${BETA_REMOTE:-origin}
VERSION=${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' | sed 's/^v//')}
BUILD=${BUILD:-$(git rev-list --count HEAD)}
DMG="$DIST/Yorozu-$VERSION-$BUILD.dmg"
[ -s "$DMG" ] || { echo "beta release needs built DMG: $DMG" >&2; exit 1; }

BETA_DIST="$DIST/beta"
rm -rf "$BETA_DIST"
mkdir -p "$BETA_DIST"
ln "$DMG" "$BETA_DIST/$(basename "$DMG")"
DIST="$BETA_DIST" CHANNEL=beta \
  DOWNLOAD_PREFIX="https://github.com/$PUBLIC/releases/download/$BETA_TAG/" \
  ./scripts/appcast.sh
ln "$DMG" "$BETA_DIST/Yorozu.dmg"

if ! gh release view "$BETA_TAG" --repo "$PUBLIC" >/dev/null 2>&1; then
  git tag -f "$BETA_TAG" HEAD
  git push --force "$BETA_REMOTE" "refs/tags/$BETA_TAG"
  gh release create "$BETA_TAG" --repo "$PUBLIC" --verify-tag --draft --prerelease \
    --title "Yorozu Beta" \
    --notes "Rolling main build. Download Yorozu.dmg to join beta updates; stable installs stay on the stable feed."
fi

# Upload the versioned DMG first. The old feed keeps working until the new feed is uploaded.
gh release upload "$BETA_TAG" --repo "$PUBLIC" "$DMG" --clobber
gh release upload "$BETA_TAG" --repo "$PUBLIC" "$BETA_DIST/Yorozu.dmg" --clobber
gh release upload "$BETA_TAG" --repo "$PUBLIC" "$BETA_DIST/appcast.xml" --clobber
git tag -f "$BETA_TAG" HEAD
git push --force "$BETA_REMOTE" "refs/tags/$BETA_TAG"
gh release edit "$BETA_TAG" --repo "$PUBLIC" --draft=false --prerelease

# One old versioned DMG is enough for the previous feed during publication. Once the new
# feed is live, keep only its referenced archive to avoid adding hundreds of MB per push.
gh release view "$BETA_TAG" --repo "$PUBLIC" --json assets --jq '.assets[].name' |
while IFS= read -r asset; do
  case "$asset" in
    Yorozu-*.dmg) [ "$asset" = "$(basename "$DMG")" ] || gh release delete-asset "$BETA_TAG" "$asset" --repo "$PUBLIC" --yes ;;
  esac
done
