#!/bin/sh
# Tests scripts/release_notes.sh in a throwaway repository: scripts/release_notes.overrides retitles one PR and drops
# another in both the Markdown and the What to Test form, and without the file every PR keeps its own title. Then
# checks that every line of the real overrides file is a comment, "#<n> -" or "#<n> <Conventional Commits title>".
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "release_notes_test: $*" >&2; exit 1; }
has() { printf '%s\n' "$1" | grep -qxF -- "$2" || fail "missing line: $2"; }
lacks() { ! printf '%s\n' "$1" | grep -qF -- "$2" || fail "unexpected: $2"; }

cd "$tmp"
git init -q
git config user.name test
git config user.email test@example.invalid
git config commit.gpgsign false
git config tag.gpgsign false
mkdir -p scripts apps/ios/metadata/testflight/en-US
cp "$root/scripts/release_notes.sh" scripts/
cp "$root/apps/ios/metadata/testflight/en-US/what_to_test.txt" apps/ios/metadata/testflight/en-US/
commit() { git commit -q --allow-empty -m "$1"; }
commit "feat: first (#1)"
git tag v0.1.0
commit "feat(relay): expire abandoned rooms (#2)"
commit "fix(relay): temporary route for old rooms (#3)"
commit "fix(relay): rebuild wiped rooms (#4)"

out=$(scripts/release_notes.sh)
has "$out" "- **relay:** expire abandoned rooms (#2)"
has "$out" "- **relay:** temporary route for old rooms (#3)"

cat > scripts/release_notes.overrides <<'NOTES'
# A comment, and a line that names no PR:
#   #2 not an override
#2 feat(relay): delete room data after 30 idle days (#2, #4)
#3 -
NOTES
out=$(scripts/release_notes.sh)
has "$out" "- **relay:** delete room data after 30 idle days (#2, #4)"
has "$out" "- **relay:** rebuild wiped rooms (#4)"
lacks "$out" "expire abandoned rooms"
lacks "$out" "(#3)"
plain=$(scripts/release_notes.sh --what-to-test en-US 0.2.0 7)
has "$plain" "- relay: delete room data after 30 idle days (#2, #4)"
lacks "$plain" "(#3)"

# An override without its own numbers keeps the PR's.
printf '#2 fix: reworded\n' > scripts/release_notes.overrides
has "$(scripts/release_notes.sh)" "- reworded (#2)"

bad=$(grep -nE '^#[0-9]' "$root/scripts/release_notes.overrides" \
    | grep -vE '^[0-9]+:#[0-9]+ +(-|[a-z]+(\([^)]*\))?!?: .*[^ ])$' || true)
[ -z "$bad" ] || fail "bad override line in scripts/release_notes.overrides: $bad"
echo "release_notes_test: ok"
