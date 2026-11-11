#!/usr/bin/env bash
# Tests commit-type.sh against throwaway git repositories.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/commit-type.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

failed=0
n=0

# A fresh repository: one base commit on main, then a branch `work`. Sets BASE.
new_repo() {
  n=$((n + 1))
  mkdir "$tmp/$n"
  cd "$tmp/$n"
  git init -q
  git symbolic-ref HEAD refs/heads/main
  git config user.name test
  git config user.email test@example.invalid
  git config commit.gpgsign false
  git config tag.gpgsign false
  commit base.txt 'chore: base'
  BASE=$(git rev-parse HEAD)
  git checkout -q -b work
}

# commit <path> <subject> [body]
commit() {
  mkdir -p "$(dirname "$1")"
  echo x >> "$1"
  git add "$1"
  if [ $# -ge 3 ]; then
    git commit -q -m "$2" -m "$3"
  else
    git commit -q -m "$2"
  fi
}

# expect <exit code> <name> <title> [body]
expect() {
  local out code=0
  out=$(BASE=$BASE TITLE=$3 BODY=${4-} bash "$script" 2>&1) || code=$?
  if [ "$code" -eq "$1" ]; then
    echo "PASS $n $2"
  else
    echo "FAIL $n $2: exit $code, expected $1"
    printf '%s\n' "$out" | sed 's/^/    /'
    failed=1
  fi
}

deps='chore(deps): bump actions/setup-node from 7.0.0 to 7.1.0'
installer=.github/workflows/windows-installer.yml

# Allowed.
new_repo; commit apps/windows/a 'ci(windows): x'
expect 0 'windows type' 'ci(windows): x'

new_repo; commit src/a 'feat: x'
expect 0 'not Windows, skipped' 'feat: x'

new_repo; commit apps/windows/a 'chore(windows): x'
git checkout -q main; commit src/y 'feat: y'; BASE=$(git rev-parse HEAD)
git checkout -q work; git merge -q --no-ff -m "Merge branch 'main' into work" main
expect 0 'merge from main' 'chore(windows): x'

new_repo; commit apps/windows/a 'Revert "ci(windows): x"'
expect 0 'revert of a windows type' 'Revert "ci(windows): x"'

# A revert subject never moves the minor, whatever it reverts.
new_repo; commit apps/windows/a 'Revert "feat(windows): x"'
expect 0 'revert of a feat' 'Revert "feat(windows): x"'

# Rejected.
new_repo; commit apps/windows/a 'feat(windows): x'
expect 1 'feat(windows)' 'feat(windows): x'

new_repo; commit apps/windows/a 'chore(windows)!: x'
expect 1 'breaking mark' 'chore(windows)!: x'

new_repo; commit apps/windows/a 'chore: x'
expect 1 'Windows-only diff without the scope' 'chore: x'

new_repo; commit apps/windows/a 'chore(windows): x'
expect 1 'BREAKING CHANGE in the body' 'chore(windows): x' "Summary

BREAKING CHANGE: y"

new_repo; commit apps/windows/a 'chore(windows): x'; commit apps/windows/b 'fix: y'
expect 1 'fix commit on a Windows-only diff' 'chore(windows): x'

# The script rejects Dependabot's title; the workflow skips Dependabot's pull requests before it runs.
new_repo; commit "$installer" "$deps"
expect 1 'Dependabot title, installer workflow' "$deps"

new_repo; commit apps/windows/a 'chore(windows): x' 'BREAKING CHANGE: y'
expect 1 'BREAKING CHANGE in a commit message' 'chore(windows): x'

# The scope alone applies the rule, whatever the files.
new_repo; commit src/a 'chore(windows): x'
expect 1 'scope only' 'feat(windows): x'

new_repo; commit apps/windows/a 'chore(windows): x' 'BREAKING-CHANGE: x'
expect 1 'BREAKING-CHANGE hyphen' 'chore(windows): x'

# Bad input.
new_repo; BASE=not-a-commit
expect 2 'BASE not a commit' 'chore(windows): x'

exit "$failed"
