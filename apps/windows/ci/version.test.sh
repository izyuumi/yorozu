#!/usr/bin/env bash
# Tests version.sh against copies of the four version files and throwaway git repositories.
set -euo pipefail

ci="$(cd "$(dirname "$0")" && pwd)"
script="$ci/version.sh"
real="$(cd "$ci/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# The fixture sits at <repo>/apps/windows, so the stable and shared tests can make <repo> a git repository.
repo="$tmp/repo"
fx="$repo/apps/windows"
files=(app/package.json app/src-tauri/tauri.conf.json Cargo.toml Cargo.lock)
version=$(bash "$script" get)
# The tests write 1.2.3 and 9.9.9; the real files must not already hold either.
if [ "$version" = 1.2.3 ] || [ "$version" = 9.9.9 ]; then
  echo "version.test.sh: the real version is $version, which the tests use as a changed value; pick other test values" >&2
  exit 1
fi
failed=0
passed=0

ok() { echo "ok - $1"; passed=$((passed + 1)); }
fail() { echo "FAIL - $1" >&2; failed=$((failed + 1)); }

# A fresh copy of the real files in $fx, the version.sh root.
fixture() {
  rm -rf "$fx"
  local f
  for f in "${files[@]}"; do
    mkdir -p "$fx/$(dirname "$f")"
    cp "$real/$f" "$fx/$f"
  done
}

# expect <exit code> <name> <args...>: runs version.sh on the fixture; output in $out, stderr in $err.
expect() {
  local want=$1 name=$2 got=0
  shift 2
  out=$(YOROZU_WINDOWS_DIR="$fx" bash "$script" "$@" 2>"$tmp/err") || got=$?
  err=$(cat "$tmp/err")
  if [ "$got" -eq "$want" ]; then ok "$name"; else fail "$name: exit $got, wanted $want ($err)"; fi
}

# changed <file> [base]: sets $n to the lines changed in a fixture file against base (default the real one).
# git diff --no-index exits 1 when the files differ; anything above 1 is a git error and stops the test.
changed() {
  local d rc=0
  d=$(git diff --no-index --numstat "${2:-$real/$1}" "$fx/$1") || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "version.test.sh: git diff --no-index failed on $1 (exit $rc)" >&2
    exit 1
  fi
  n=$(awk '{ s += $1 + $2 } END { print s + 0 }' <<<"$d")
}

# Awk programs that set the version of one place to v, as a hand edit would: the first version line of a
# JSON file or Cargo.toml, and in Cargo.lock the line after each member named by the regex m.
edit_first='!d && /^ *"?version"? *[:=] *"/ { sub(/"[0-9.]+"/, "\"" v "\""); d = 1 } { print }'
edit_lock='$0 ~ "^name = \"(" m ")\"\r?$" { p = 1 } p && /^version = / { sub(/"[0-9.]+"/, "\"" v "\""); p = 0 } { print }'
members='yorozu-core|yorozu-windows|yorozu-probe'

# edit <file> <version> <source> [members regex]: writes source, so edited, to the fixture's file.
edit() {
  if [ "$1" = Cargo.lock ]; then
    awk -v v="$2" -v m="${4:-$members}" "$edit_lock" "$3" >"$fx/$1"
  else
    awk -v v="$2" "$edit_first" "$3" >"$fx/$1"
  fi
}

fixture
expect 0 'get on the real files' get
[ "$out" = "$version" ] && ok "get prints $version" || fail "get printed '$out'"

expect 0 'set 1.2.3' set 1.2.3
expect 0 'get after set' get
[ "$out" = 1.2.3 ] && ok 'get prints 1.2.3' || fail "get printed '$out'"
expect 0 'check 1.2.3' check 1.2.3
# One version line in each JSON file and Cargo.toml, three in Cargo.lock; nothing else differs.
for f in "${files[@]}"; do
  want=2
  [ "$f" = Cargo.lock ] && want=6
  changed "$f"
  [ "$n" -eq "$want" ] && ok "set changes only the version lines of $f" ||
    fail "set changed $n lines of $f, wanted $want"
done
n=$(diff "$real/Cargo.lock" "$fx/Cargo.lock" | grep -c '^> version = "1\.2\.3"$' || true)
[ "$n" -eq 3 ] && ok 'Cargo.lock lines are the members versions' || fail "Cargo.lock: $n version lines"

fixture
expect 0 'check on the real files' check "$version"
expect 1 'check with another version' check 9.9.9

# One file edited by hand: get and check name it with its value.
for f in "${files[@]}"; do
  fixture
  label=$f
  if [ "$f" = Cargo.lock ]; then
    edit "$f" 9.9.9 "$real/$f" yorozu-windows
    label='Cargo.lock (yorozu-windows)'
  else
    edit "$f" 9.9.9 "$real/$f"
  fi
  expect 1 "check fails when $f differs" check "$version"
  grep -qF "$label: 9.9.9" <<<"$err" && ok "check names $label: 9.9.9" || fail "check did not name $label: 9.9.9: $err"
  grep -qF "version.sh set $version" <<<"$err" && ok "check prints the fix for $f" || fail "no fix: $err"
  expect 1 "get fails when $f differs" get
  grep -qF "$label: 9.9.9" <<<"$err" && ok "get names $label: 9.9.9" || fail "get did not name $label: 9.9.9: $err"
done

fixture
for bad in 1.2 v1.2.3 1.2.3-beta '' 01.2.3 +1.2.3 '1.2.3 '; do
  expect 2 "set '$bad'" set "$bad"
done
for f in "${files[@]}"; do
  changed "$f"
  [ "$n" -eq 0 ] && ok "invalid set leaves $f unchanged" || fail "invalid set changed $n lines of $f"
done
expect 2 'set without a version' set
expect 2 'unknown subcommand' bump
expect 2 'no subcommand'

# CRLF files: get reads them, and set swaps only the version values, keeping every CR.
fixture
mkdir -p "$tmp/want/app/src-tauri"
for f in "${files[@]}"; do
  awk '{ printf "%s\r\n", $0 }' "$real/$f" >"$fx/$f"
  cp "$fx/$f" "$tmp/crlf"
  edit "$f" 1.2.3 "$tmp/crlf"
  mv "$fx/$f" "$tmp/want/$f"
  cp "$tmp/crlf" "$fx/$f"
done
expect 0 'get on CRLF files' get
[ "$out" = "$version" ] && ok "get on CRLF files prints $version" || fail "get on CRLF files printed '$out'"
expect 0 'set 1.2.3 on CRLF files' set 1.2.3
for f in "${files[@]}"; do
  cmp -s "$tmp/want/$f" "$fx/$f" && ok "set on CRLF keeps $f byte for byte but the version" ||
    fail "set on CRLF: $f differs from the expectation"
done

# A version line in a section before [workspace.package] is not the workspace version.
fixture
awk '/^\[workspace\.package\]$/ { print "[workspace.metadata.x]"; print "version = \"7.7.7\""; print "" } { print }' \
  "$real/Cargo.toml" >"$tmp/Cargo.toml"
cp "$tmp/Cargo.toml" "$fx/Cargo.toml"
expect 0 'get with an earlier version line in Cargo.toml' get
[ "$out" = "$version" ] && ok "get reads [workspace.package]" || fail "get printed '$out'"
expect 0 'set with an earlier version line in Cargo.toml' set 1.2.3
changed Cargo.toml "$tmp/Cargo.toml"
[ "$n" -eq 2 ] && grep -qx 'version = "7.7.7"' "$fx/Cargo.toml" &&
  ok 'set rewrites only the [workspace.package] line' || fail "set changed $n lines of Cargo.toml: $(cat "$fx/Cargo.toml")"

# set with a version line missing fails, names the file and writes nothing.
fixture
awk '!/^  "version": /' "$real/app/src-tauri/tauri.conf.json" >"$tmp/tauri.conf.json"
cp "$tmp/tauri.conf.json" "$fx/app/src-tauri/tauri.conf.json"
expect 1 'set with a missing version line' set 1.2.3
grep -qF 'app/src-tauri/tauri.conf.json: (missing)' <<<"$err" && ok 'set names the file' || fail "set did not name it: $err"
for f in app/package.json Cargo.toml Cargo.lock; do
  changed "$f"
  [ "$n" -eq 0 ] && ok "failed set leaves $f unchanged" || fail "failed set changed $n lines of $f"
done
changed app/src-tauri/tauri.conf.json "$tmp/tauri.conf.json"
[ "$n" -eq 0 ] && ok 'failed set leaves tauri.conf.json unchanged' || fail "failed set changed $n lines of tauri.conf.json"

# stable and shared, in a throwaway repository around the fixture.
fixture
cd "$repo"
git init -q
git config user.name test
git config user.email test@example.invalid
git -c commit.gpgsign=false commit -q --allow-empty -m 'chore: base'
expect 1 'stable without tags' stable
grep -qF 'fatal:' <<<"$err" && ok "stable prints git's error" || fail "stable hid git's error: $err"
git -c tag.gpgsign=false tag v0.2.0
git -c commit.gpgsign=false commit -q --allow-empty -m 'feat: x'
git -c tag.gpgsign=false tag v0.4.0
git -c commit.gpgsign=false commit -q --allow-empty -m 'fix: y'
git -c tag.gpgsign=false tag v0.5.0-beta
expect 0 'stable with tags' stable
[ "$out" = 0.4.0 ] && ok 'stable is the latest stable tag' || fail "stable printed '$out'"

mkdir -p "$repo/scripts"
printf '#!/bin/sh\necho 3.4.5\n' >"$repo/scripts/version.sh"
expect 0 'shared' shared
[ "$out" = 3.4.5 ] && ok 'shared prints scripts/version.sh output' || fail "shared printed '$out'"
cd "$ci"

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
