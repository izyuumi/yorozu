#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TO=${1:-HEAD}
FROM=$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-beta*' "$TO^" 2>/dev/null || true)
git log --no-merges --format=%s "${FROM:+$FROM..}$TO" | awk '
    match($0, /^[a-z]+(\([^)]*\))?!?: /) {
        head = substr($0, 1, RLENGTH - 2); text = substr($0, RLENGTH + 1)
        sub(/ *\[skip ci\]$/, "", text)
        type = head; sub(/[(!].*/, "", type)
        scope = ""; if (match(head, /\([^)]*\)/)) scope = substr(head, RSTART + 1, RLENGTH - 2)
        if (scope == "deps" || scope == "deps-dev") next
        line = "- " (head ~ /!$/ ? "**Breaking:** " : "") (scope != "" ? "**" scope ":** " : "") text
        if (type == "feat") feat = feat line "\n"
        else if (type == "fix") fix = fix line "\n"
        else if (type == "perf") perf = perf line "\n"
    }
    END {
        if (feat != "") printf "## Features\n\n%s\n", feat
        if (fix != "") printf "## Fixes\n\n%s\n", fix
        if (perf != "") printf "## Performance\n\n%s\n", perf
    }'
