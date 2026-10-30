#!/bin/sh
# Opens or updates the release PR (branch `release`, like release-please): CHANGELOG.md gains the notes for
# <version>, and the body names the beta build that merging it makes stable (promote.yml).
set -eu
cd "$(dirname "$0")/.."
REPO=${REPO:-izyuumi/yorozu}
VERSION=${1:?usage: scripts/release_pr.sh <version> <build> <source sha>}
BUILD=${2:?}
SHA=${3:?}
NOTES=$(scripts/release_notes.sh "$SHA")
OLD=$(git show "$SHA:CHANGELOG.md" 2>/dev/null | sed '1,2d' || true)
FILE=$(mktemp)
printf '# Changelog\n\n## %s\n\n%s\n\n%s' "$VERSION" "$(printf '%s' "${NOTES:-No notable changes.}" | sed 's/^## /### /')" "$OLD" > "$FILE"
gh api -X PATCH "repos/$REPO/git/refs/heads/release" -f sha="$SHA" -F force=true >/dev/null 2>&1 \
    || gh api "repos/$REPO/git/refs" -f ref=refs/heads/release -f sha="$SHA" >/dev/null
# The contents API commits as GitHub, so the commit is signed as the main ruleset requires.
blob=$(gh api "repos/$REPO/contents/CHANGELOG.md?ref=release" -q .sha 2>/dev/null || true)
gh api -X PUT "repos/$REPO/contents/CHANGELOG.md" -f message="chore: release $VERSION" -f branch=release \
    -f content="$(base64 < "$FILE" | tr -d '\n')" ${blob:+-f sha="$blob"} >/dev/null
BODY="Merging this makes the Mac beta \`v$VERSION-beta\` (build $BUILD) stable as \`v$VERSION\` and deletes the beta. A newer beta updates this PR to name it.

$NOTES

Release-Build: $BUILD"
PR=$(gh pr list --repo "$REPO" --head release --state open --json number -q '.[0].number')
if [ -n "$PR" ]; then
    gh pr edit "$PR" --repo "$REPO" --title "chore: release $VERSION" --body "$BODY" >/dev/null
else
    gh pr create --repo "$REPO" --head release --base main --title "chore: release $VERSION" --body "$BODY" >/dev/null
fi
# The bot-authored PR's checks wait for approval; approve them so the required checks run.
for _ in 1 2 3 4 5 6; do
    sleep 10
    runs=$(gh run list --repo "$REPO" --workflow checks.yml --branch release --event pull_request --status action_required \
        --json databaseId -q '.[].databaseId' || true)
    [ -n "$runs" ] && break
done
for run in $runs; do
    gh api -X POST "repos/$REPO/actions/runs/$run/approve" >/dev/null || echo "Approve the checks on the release PR by hand." >&2
done
echo "Release PR for $VERSION names build $BUILD."
