#!/usr/bin/env bash
# Keeps Windows-only pull requests out of the app's version and release notes.
# Inputs (env): TITLE, BODY (may be empty), BASE (a commit). Checks BASE..HEAD of the current repo.
set -euo pipefail

TITLE=${TITLE-}
BODY=${BODY-}
if [ -z "${BASE-}" ] || ! git rev-parse -q --verify "$BASE^{commit}" >/dev/null 2>&1; then
  echo "commit-type: BASE must be a commit in this repository (got '${BASE-}')" >&2
  exit 2
fi

scope='^[A-Za-z]+\(windows\)'
windows_file='^(apps/windows/|\.github/workflows/windows-installer\.yml$)'
# The five Windows types, or any revert: a 'Revert "…"' subject only bumps the patch in
# scripts/version.sh, like a chore. The workflow skips Dependabot's pull requests before this runs.
allowed='^((chore|build|ci|test|docs)\(windows\): |Revert ")'
breaking='^BREAKING[ -]CHANGE: '

files=$(git diff --name-only "$BASE" HEAD)
applies=false
if [[ $TITLE =~ $scope ]]; then
  applies=true
elif [ -n "$files" ] && ! grep -qvE "$windows_file" <<<"$files"; then
  applies=true
fi
if [ "$applies" = false ]; then
  echo "not a Windows-only change; skipped"
  exit 0
fi

bad=0
flag() {
  echo "not allowed: $1" >&2
  bad=1
}

[[ $TITLE =~ $allowed ]] || flag "title: $TITLE"
while IFS= read -r subject; do
  [[ $subject =~ $allowed ]] || flag "commit subject: $subject"
done < <(git log --no-merges --format=%s "$BASE..HEAD")
while IFS= read -r line; do
  flag "pull request body: $line"
done < <(printf '%s\n' "$BODY" | grep -E "$breaking" || true)
while IFS= read -r line; do
  flag "commit message: $line"
done < <(git log --no-merges --format=%B "$BASE..HEAD" | grep -E "$breaking" || true)

if [ "$bad" -ne 0 ]; then
  cat >&2 <<'EOF'

A pull request that is scoped (windows), or that changes only apps/windows/** and
.github/workflows/windows-installer.yml, must not move the app's version or release notes:
in scripts/version.sh a feat bumps the minor and a "!" or "BREAKING CHANGE" the major, and
feat, fix and perf reach scripts/release_notes.sh. The title and every commit subject must
be "chore|build|ci|test|docs(windows): ..." or any 'Revert "..."' title (a revert only bumps
the patch). No line of the body or of a commit message may start with "BREAKING CHANGE: " or
"BREAKING-CHANGE: ". Dependabot's pull requests are skipped by the workflow, not by this script.
EOF
  exit 1
fi
echo "ok"
