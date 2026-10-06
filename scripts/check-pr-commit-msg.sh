#!/bin/sh
# No process substitution: failed revision resolution or enumeration must fail CI.
set -eu
[ "$#" -eq 3 ] || { echo 'usage: check-pr-commit-msg.sh TITLE BASE HEAD' >&2; exit 1; }
checker="$(dirname "$0")/check-commit-msg.sh"
"$checker" "$1"
base=$(git rev-parse --verify --end-of-options "$2^{commit}")
head=$(git rev-parse --verify --end-of-options "$3^{commit}")
subjects=$(git log --no-merges --format=%s "$base..$head" --)
[ -n "$subjects" ] || exit 0
printf '%s\n' "$subjects" | while IFS= read -r subject; do
  "$checker" "$subject" || exit 1
done
