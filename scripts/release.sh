#!/bin/sh
# Build, notarize, sign the Sparkle appcast, and publish one versioned Mac release.
# Release Please supplies RELEASE_TAG in CI; local releases use the latest v* tag, which
# must be at HEAD (or ALLOW_UNTAGGED=1 for a local experiment).
set -eu
cd "$(dirname "$0")/.."

DIST=${DIST:-dist}
PUBLIC=${PUBLIC:-izyuumi/yorozu}
TAG=${RELEASE_TAG:-$(git describe --tags --abbrev=0 --match 'v*')}
case "$TAG" in
  v[0-9]*) ;;
  *) echo "release tag must start with v followed by a version: $TAG" >&2; exit 1 ;;
esac
# Build only the commit the tag names: in CI the checkout is `ref: RELEASE_TAG`, so this
# holds by construction; locally it stops a stray HEAD from shipping under an old tag.
# ALLOW_UNTAGGED=1 is for local experiments only. The two SHAs are assigned on their own
# lines: a substitution inside `[ ]` escapes `set -e`, so a failing git would leave both
# sides empty and equal, and the guard would pass.
HEAD_SHA=$(git rev-parse --verify HEAD)
TAG_SHA=$(git rev-parse --verify "$TAG^{commit}")
if [ "${ALLOW_UNTAGGED:-0}" != 1 ] && [ "$HEAD_SHA" != "$TAG_SHA" ]; then
  echo "release refused: HEAD is not the commit tagged $TAG; check out the tag or set ALLOW_UNTAGGED=1 for a local experiment" >&2
  exit 1
fi
# Refuse to replace a newer published version when an old workflow is rerun.
PUBLISHED_TAGS=$(gh api "repos/$PUBLIC/releases" --paginate --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name')
python3 - "$TAG" "$PUBLISHED_TAGS" <<'PY_VERSION'
import re
import sys


def version(tag):
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", tag)
    return tuple(map(int, match.groups())) if match else None


target = version(sys.argv[1])
if target is None:
    sys.exit("release tag must be a stable vMAJOR.MINOR.PATCH version")
for tag in sys.argv[2].splitlines():
    previous = version(tag)
    if previous is not None and previous > target:
        sys.exit(f"refusing to replace newer published release {tag} with {sys.argv[1]}")
PY_VERSION
VERSION=${TAG#v}
BUILD=${BUILD:-$(git rev-list --count HEAD)}
export DIST VERSION BUILD

./scripts/build-mac.sh
./scripts/appcast.sh

# Keep every DMG referenced by this feed, including older builds in a local dist/.
# The stable name always points to this exact build, regardless of file timestamps.
DMGS=$(grep -o 'download/Yorozu-[^"]*\.dmg' "$DIST/appcast.xml" | sed 's#^download/##')
STABLE_DIR=$(mktemp -d "$DIST/stable.XXXXXX")
trap 'rm -rf "$STABLE_DIR"' EXIT
trap 'exit 1' HUP INT TERM
ln "$DIST/Yorozu-$VERSION-$BUILD.dmg" "$STABLE_DIR/Yorozu.dmg"
set --
while IFS= read -r dmg; do
  [ -n "$dmg" ] || continue
  [ -f "$DIST/$dmg" ] || { echo "appcast asset missing: $dmg" >&2; exit 1; }
  set -- "$@" "$DIST/$dmg"
done <<EOF_DMGS
$DMGS
EOF_DMGS
[ "$#" -gt 0 ] || { echo "appcast contains no DMGs" >&2; exit 1; }

# A new release stays hidden until all downloads are uploaded successfully. Release
# Please may have already created the release and its changelog; preserve those notes.
gh release view "$TAG" --repo "$PUBLIC" >/dev/null 2>&1 \
  || gh release create "$TAG" --repo "$PUBLIC" --verify-tag --draft \
    --title "Yorozu $VERSION" --notes "Download: https://yorozu.yumi.to/mac"
gh release upload "$TAG" --repo "$PUBLIC" "$@" "$STABLE_DIR/Yorozu.dmg" "$DIST/appcast.xml" catalog/models.json --clobber
gh release edit "$TAG" --repo "$PUBLIC" --draft=false --latest

# Only retire previous releases after publishing every asset. Preserve Git tags for
# Release Please's version history, and leave unrelated drafts alone. Paginate so the
# repository converges to one published release even if it has more than 100 releases.
RELEASES=$(gh api "repos/$PUBLIC/releases" --paginate --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name')
while IFS= read -r old_tag; do
  [ -n "$old_tag" ] || continue
  [ "$old_tag" = "$TAG" ] && continue
  echo "Deleting superseded release: $old_tag (keeping its Git tag)"
  gh release delete "$old_tag" --repo "$PUBLIC" --yes
done <<EOF_RELEASES
$RELEASES
EOF_RELEASES

# The build number is what Sparkle compares.
grep -m1 '<sparkle:version>' "$DIST/appcast.xml"
