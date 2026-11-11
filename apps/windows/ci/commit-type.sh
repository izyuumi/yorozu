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
# The five Windows types, or any revert: a 'Revert "…"' subject matches neither the feat nor the
# breaking pattern in scripts/version.sh and does not start with feat, fix or perf, so it moves
# neither the minor or major version nor the release notes. The workflow skips Dependabot's pull
# requests before this runs.
allowed='^((chore|build|ci|test|docs)\(windows\): |Revert ")'
breaking='^BREAKING[ -]CHANGE: '

# Non-ASCII paths unquoted; a rename lists both sides.
files=$(git -c core.quotePath=false diff --no-renames --name-only "$BASE" HEAD)
# Captured first, so a git failure stops the script.
subjects=$(git log --no-merges --format=%s "$BASE..HEAD")
messages=$(git log --no-merges --format=%B "$BASE..HEAD")
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
  [ -z "$subject" ] && continue
  [[ $subject =~ $allowed ]] || flag "commit subject: $subject"
done <<<"$subjects"
while IFS= read -r line; do
  if [[ $line =~ $breaking ]]; then flag "pull request body: $line"; fi
done <<<"$BODY"
while IFS= read -r line; do
  if [[ $line =~ $breaking ]]; then flag "commit message: $line"; fi
done <<<"$messages"

if [ "$bad" -ne 0 ]; then
  cat >&2 <<'EOF'

commit-type: this pull request is scoped (windows), or every file it changes is under
apps/windows/ or is .github/workflows/windows-installer.yml. It must not raise the app's
minor or major version or reach the release notes. In scripts/version.sh a feat raises the
minor; a "!" or a "BREAKING CHANGE:"/"BREAKING-CHANGE:" footer raises the major, or the
minor while the major is 0. scripts/release_notes.sh lists feat, fix and perf.
Allowed for the title and every non-merge commit subject:
  chore|build|ci|test|docs(windows): ...
  Revert "..."
No line of the pull request body or of a commit message may start with "BREAKING CHANGE: "
or "BREAKING-CHANGE: ".
EOF
  exit 1
fi
echo "ok"
