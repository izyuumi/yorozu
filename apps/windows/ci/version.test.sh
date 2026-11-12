#!/usr/bin/env bash
# Tests version.sh against copies of the four version files and throwaway git repositories.
set -euo pipefail

ci="$(cd "$(dirname "$0")" && pwd)"
script="$ci/version.sh"
real="$(cd "$ci/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

files=(app/package.json app/src-tauri/tauri.conf.json Cargo.toml Cargo.lock)
version=$(bash "$script" get)
failed=0
passed=0

ok() { echo "ok - $1"; passed=$((passed + 1)); }
fail() { echo "FAIL - $1" >&2; failed=$((failed + 1)); }

# A fresh copy of the real files in $tmp/fx, the version.sh root.
fixture() {
  rm -rf "$tmp/fx"
  local f
  for f in "${files[@]}"; do
    mkdir -p "$tmp/fx/$(dirname "$f")"
    cp "$real/$f" "$tmp/fx/$f"
  done
}

# expect <exit code> <name> <args...>: runs version.sh on the fixture; output in $out, stderr in $err.
expect() {
  local want=$1 name=$2 got=0
  shift 2
  out=$(YOROZU_WINDOWS_DIR="$tmp/fx" bash "$script" "$@" 2>"$tmp/err") || got=$?
  err=$(cat "$tmp/err")
  if [ "$got" -eq "$want" ]; then ok "$name"; else fail "$name: exit $got, wanted $want ($err)"; fi
}

# Lines changed in a fixture file against the real one.
changed() {
  git diff --no-index --numstat "$real/$1" "$tmp/fx/$1" | awk '{ print $1 + $2 }' || true
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
  n=$(changed "$f")
  [ "${n:-0}" -eq "$want" ] && ok "set changes only the version lines of $f" ||
    fail "set changed $n lines of $f, wanted $want"
done
n=$(diff "$real/Cargo.lock" "$tmp/fx/Cargo.lock" | grep -c '^> version = "1\.2\.3"$' || true)
[ "$n" -eq 3 ] && ok 'Cargo.lock lines are the members versions' || fail "Cargo.lock: $n version lines"

fixture
expect 0 'check on the real files' check "$version"
expect 1 'check with another version' check 9.9.9

# One file edited by hand: get and check name it.
for f in "${files[@]}"; do
  fixture
  if [ "$f" = Cargo.lock ]; then
    edit='p && /^version = / { sub(/"[0-9.]+"/, "\"9.9.9\""); p = 0 } /^name = "yorozu-windows"$/ { p = 1 } { print }'
  else
    edit='!d && /^ *"?version"? *[:=] *"/ { sub(/"[0-9.]+"/, "\"9.9.9\""); d = 1 } { print }'
  fi
  awk "$edit" "$real/$f" >"$tmp/fx/$f"
  expect 1 "check fails when $f differs" check "$version"
  grep -qF "$f" <<<"$err" && ok "check names $f" || fail "check did not name $f: $err"
  grep -qF "version.sh set $version" <<<"$err" && ok "check prints the fix for $f" || fail "no fix: $err"
  expect 1 "get fails when $f differs" get
  grep -qF "$f" <<<"$err" && ok "get names $f" || fail "get did not name $f: $err"
done

fixture
for bad in 1.2 v1.2.3 1.2.3-beta '' 01.2.3 +1.2.3 '1.2.3 '; do
  expect 2 "set '$bad'" set "$bad"
done
[ -z "$(changed Cargo.toml)" ] && ok 'invalid set changes nothing' || fail 'invalid set changed Cargo.toml'
expect 2 'set without a version' set
expect 2 'unknown subcommand' bump
expect 2 'no subcommand'

# stable, in a throwaway repository holding the fixture.
cd "$tmp/fx"
git init -q
git config user.name test
git config user.email test@example.invalid
git -c commit.gpgsign=false commit -q --allow-empty -m 'chore: base'
expect 1 'stable without tags' stable
git -c tag.gpgsign=false tag v0.2.0
git -c commit.gpgsign=false commit -q --allow-empty -m 'fix: x'
git -c tag.gpgsign=false tag v0.3.0-beta
expect 0 'stable with tags' stable
[ "$out" = 0.2.0 ] && ok 'stable skips the pre-release tag' || fail "stable printed '$out'"
cd "$ci"

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
