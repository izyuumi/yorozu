#!/usr/bin/env bash
# Reads, writes and checks the Windows app's version, which matches the Mac and iOS apps'.
# It lives in four places: app/package.json, app/src-tauri/tauri.conf.json, Cargo.toml
# ([workspace.package]) and Cargo.lock (the workspace members).
#   version.sh get            the version, if all places agree
#   version.sh set <x.y.z>    writes it everywhere, changing only the version lines
#   version.sh check <x.y.z>  fails unless every place holds it
#   version.sh stable         the latest stable release tag, without the v
#   version.sh shared         what scripts/version.sh gives Mac and iOS builds of this commit
set -euo pipefail

root=${YOROZU_WINDOWS_DIR:-"$(cd "$(dirname "$0")/.." && pwd)"}
members=(yorozu-core yorozu-windows yorozu-probe)
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

usage() {
  echo "usage: version.sh get | set <x.y.z> | check <x.y.z> | stable | shared" >&2
  exit 2
}

# Each awk program finds the one version line of its place; with v set it rewrites that line's
# quoted value (keeping any trailing bytes, such as a CR), otherwise it prints the value.
json_awk='
  !done && /^  "version": "[^"]*"/ {
    done = 1
    if (v == "") { s = $0; sub(/^  "version": "/, "", s); sub(/".*/, "", s); print s; exit }
    sub(/"version": "[^"]*"/, "\"version\": \"" v "\"")
  }
  v != "" { print }'
toml_awk='
  /^\[/ { sec = $0; sub(/[[:space:]]*\r?$/, "", sec) }
  !done && sec == "[workspace.package]" && /^version = "[^"]*"/ {
    done = 1
    if (v == "") { s = $0; sub(/^version = "/, "", s); sub(/".*/, "", s); print s; exit }
    sub(/"[^"]*"/, "\"" v "\"")
  }
  v != "" { print }'
lock_awk='
  index($0, "name = \"" n "\"") == 1 { found = 1 }
  found && /^version = "[^"]*"/ {
    found = 0
    if (v == "") { s = $0; sub(/^version = "/, "", s); sub(/".*/, "", s); print s; exit }
    sub(/"[^"]*"/, "\"" v "\"")
  }
  /^\[\[package\]\]/ { found = 0 }
  v != "" { print }'

# read_place <file> <awk program> [package]
read_place() {
  awk -v v= -v n="${3-}" "$2" "$root/$1"
}

# write_place <file> <awk program> <version> [package]: via a temp file, so it works with any sed/awk.
# cat into the original keeps its mode.
write_place() {
  local tmp
  tmp=$(mktemp)
  awk -v v="$3" -v n="${4-}" "$2" "$root/$1" >"$tmp"
  cat "$tmp" >"$root/$1"
  rm -f "$tmp"
}

# Prints "<file>\t<value>" for every place; an absent version is empty.
all_places() {
  printf '%s\t%s\n' app/package.json "$(read_place app/package.json "$json_awk")"
  printf '%s\t%s\n' app/src-tauri/tauri.conf.json "$(read_place app/src-tauri/tauri.conf.json "$json_awk")"
  printf '%s\t%s\n' Cargo.toml "$(read_place Cargo.toml "$toml_awk")"
  local m
  for m in "${members[@]}"; do
    printf '%s\t%s\n' "Cargo.lock ($m)" "$(read_place Cargo.lock "$lock_awk" "$m")"
  done
}

show() {
  local file value
  while IFS=$'\t' read -r file value; do
    echo "$file: ${value:-(missing)}" >&2
  done <<<"$1"
}

valid() {
  [[ ${1-} =~ $semver ]] || { echo "version.sh: not a version x.y.z: '${1-}'" >&2; exit 2; }
}

cmd=${1-}
case $cmd in
  get)
    [ $# -eq 1 ] || usage
    places=$(all_places)
    values=$(cut -f2 <<<"$places" | sort -u)
    if [ -z "$values" ] || [[ $values == *$'\n'* ]]; then
      echo "version.sh: the version files disagree:" >&2
      show "$places"
      exit 1
    fi
    echo "$values"
    ;;
  set)
    [ $# -eq 2 ] || usage
    valid "$2"
    write_place app/package.json "$json_awk" "$2"
    write_place app/src-tauri/tauri.conf.json "$json_awk" "$2"
    write_place Cargo.toml "$toml_awk" "$2"
    for m in "${members[@]}"; do
      write_place Cargo.lock "$lock_awk" "$2" "$m"
    done
    bash "$0" check "$2" >/dev/null
    ;;
  check)
    [ $# -eq 2 ] || usage
    valid "$2"
    bad=$(awk -F'\t' -v v="$2" '$2 != v' <<<"$(all_places)")
    if [ -n "$bad" ]; then
      echo "version.sh: these differ from $2:" >&2
      show "$bad"
      echo "fix: bash apps/windows/ci/version.sh set $2" >&2
      exit 1
    fi
    echo "$2"
    ;;
  stable)
    [ $# -eq 1 ] || usage
    if ! tag=$(git -C "$root" describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-*' HEAD 2>/dev/null); then
      echo "version.sh: no stable release tag (v<x.y.z>) reachable from HEAD; a shallow clone has none" >&2
      exit 1
    fi
    echo "${tag#v}"
    ;;
  shared)
    [ $# -eq 1 ] || usage
    top=$(git -C "$root" rev-parse --show-toplevel)
    sh "$top/scripts/version.sh"
    ;;
  *) usage ;;
esac
