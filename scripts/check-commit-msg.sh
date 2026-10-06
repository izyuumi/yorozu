#!/bin/sh
# Validate every supplied subject; release-please reads these prefixes.
[ "$#" -gt 0 ] || { echo 'expected at least one subject' >&2; exit 1; }
status=0
for subject in "$@"; do
  case "$subject" in
    *'
'*) status=1; echo 'commit subject must be a single line' >&2; continue ;;
  esac
  if ! printf '%s\n' "$subject" | grep -qE '^(feat|fix|docs|chore|refactor|test|ci|build|perf|style|revert)(\([^)]+\))?!?: [[:space:]]*[^[:space:]].*$'; then
    printf 'not a Conventional Commit: %s\n' "$subject" >&2
    status=1
  fi
done
exit "$status"
