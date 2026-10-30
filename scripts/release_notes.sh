#!/bin/sh
# Prints the notes for a build: the pull requests merged into main since the last stable tag v<x.y.z> (never a
# -beta tag), grouped by their Conventional Commits titles: feat, fix and perf, each with its PR number; other
# types and dependency bumps are left out. A PR is a merge "Merge pull request #N from …" on main's first-parent
# line, titled by the merge's body, or a squashed commit ending "(#N)"; a commit pushed straight to main counts by
# its own subject.
#
#   scripts/release_notes.sh [<commit>]           Markdown: the beta and stable releases, the release PR, CHANGELOG.md
#   scripts/release_notes.sh --plain [<commit>]   plain text within TestFlight's 4,000 bytes, for What to Test
set -eu
cd "$(dirname "$0")/.."
PLAIN=0; [ "${1:-}" = --plain ] && { PLAIN=1; shift; }
TO=${1:-HEAD}
FROM=$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-beta*' "$TO^" 2>/dev/null || true)
git log --first-parent --format='%s%x1f%b%x1e' "${FROM:+$FROM..}$TO" | LC_ALL=C awk -v plain="$PLAIN" '
    BEGIN { RS = "\036"; FS = "\037" }
    {
        subject = $1; sub(/^\n+/, "", subject); body = $2; number = ""
        if (subject ~ /^Merge pull request #[0-9]+ from /) {
            split(subject, word, " "); number = word[4]
            title = body; sub(/^\n+/, "", title); sub(/\n.*/, "", title)
        } else if (match(subject, / \(#[0-9]+\)$/)) {
            number = substr(subject, RSTART + 2, RLENGTH - 3); title = substr(subject, 1, RSTART - 1)
        } else if (subject ~ /^Merge /) {
            next
        } else {
            title = subject
        }
        if (!match(title, /^[a-z]+(\([^)]*\))?!?: /)) next
        head = substr(title, 1, RLENGTH - 2); text = substr(title, RLENGTH + 1)
        sub(/ *\[skip ci\]$/, "", text)
        type = head; sub(/[(!].*/, "", type)
        scope = ""; if (match(head, /\([^)]*\)/)) scope = substr(head, RSTART + 1, RLENGTH - 2)
        if (scope == "deps" || scope == "deps-dev") next
        if (type != "feat" && type != "fix" && type != "perf") next
        breaking = head ~ /!$/
        if (plain) line = "- " (breaking ? "Breaking: " : "") (scope != "" ? scope ": " : "") text (number != "" ? " (" number ")" : "")
        else {
            gsub(/&/, "\\&amp;", text); gsub(/</, "\\&lt;", text); gsub(/>/, "\\&gt;", text)
            line = "- " (breaking ? "**Breaking:** " : "") (scope != "" ? "**" scope ":** " : "") text (number != "" ? " (" number ")" : "")
        }
        count[type]++; item[type, count[type]] = line
    }
    END {
        name["feat"] = "Features"; name["fix"] = "Fixes"; name["perf"] = "Performance"
        order[1] = "feat"; order[2] = "fix"; order[3] = "perf"
        size = 0; left = 0
        for (o = 1; o <= 3; o++) {
            t = order[o]; if (!count[t]) continue
            heading = plain ? name[t] ":\n" : "## " name[t] "\n\n"
            shown = 0
            for (i = 1; i <= count[t]; i++) {
                # What to Test holds 4,000 bytes; keep room for the caller'\''s first line and the "and N more" line.
                if (plain && size + length(heading) + length(item[t, i]) + 1 > 3800) { left += count[t] - i + 1; break }
                if (!shown) { out = out heading; size += length(heading); shown = 1 }
                out = out item[t, i] "\n"; size += length(item[t, i]) + 1
            }
            if (shown) out = out "\n"
        }
        printf "%s", out
        if (left) printf "… and %d more in the GitHub release.\n", left
    }'
