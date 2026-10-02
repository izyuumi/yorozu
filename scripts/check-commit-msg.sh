#!/bin/sh
# Fails unless every argument is a Conventional Commit subject; release-please reads them.
status=0
for subject in "$@"; do
  if ! printf '%s\n' "$subject" | grep -qE '^(feat|fix|docs|chore|refactor|test|ci|build|perf|style|revert)(\([^)]+\))?!?: .+'; then
    echo "not a Conventional Commit: $subject" >&2
    status=1
  fi
done
exit "$status"
