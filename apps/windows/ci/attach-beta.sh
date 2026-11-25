#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: attach-beta.sh --tag vX.Y.Z-beta --file PATH [--repo owner/repo] [--append-notes]" >&2
  echo "       attach-beta.sh --tag vX.Y.Z-beta --artifact-sha SHA [--repo owner/repo] [--append-notes]" >&2
  exit 2
}

TAG=
FILE=
ARTIFACT_SHA=
REPO=${REPO:-${GITHUB_REPOSITORY:-}}
APPEND_NOTES=0
tag_re='^v[0-9]+\.[0-9]+\.[0-9]+-beta(\.[0-9]+)?$'
exe_re='^Yorozu_([0-9]+\.[0-9]+\.[0-9]+)_x64-setup\.exe$'

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG=${2-}; shift 2 ;;
    --file) FILE=${2-}; shift 2 ;;
    --artifact-sha) ARTIFACT_SHA=${2-}; shift 2 ;;
    --repo) REPO=${2-}; shift 2 ;;
    --append-notes) APPEND_NOTES=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ -n "$TAG" ] || usage
[ -n "$REPO" ] || { echo "attach-beta.sh: set --repo or REPO" >&2; exit 2; }
if [ -n "$FILE" ] && [ -n "$ARTIFACT_SHA" ]; then
  echo "attach-beta.sh: use either --file or --artifact-sha" >&2
  exit 2
fi
if [ -z "$FILE" ] && [ -z "$ARTIFACT_SHA" ]; then
  usage
fi
[[ $TAG =~ $tag_re ]] || { echo "attach-beta.sh: not a beta tag: $TAG" >&2; exit 2; }
TAG_VERSION=${TAG#v}
TAG_VERSION=${TAG_VERSION%%-beta*}

digest_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

require_exe() {
  local name=$1
  [[ $name =~ $exe_re ]] || {
    echo "attach-beta.sh: expected Yorozu_<x.y.z>_x64-setup.exe, got $name" >&2
    exit 1
  }
  local ver=${BASH_REMATCH[1]}
  if [ "$ver" != "$TAG_VERSION" ]; then
    echo "attach-beta.sh: $name is version $ver, but $TAG is $TAG_VERSION" >&2
    exit 1
  fi
}

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

download_artifact_zip() {
  local id=$1 dest=$2
  gh api --header "Accept: application/vnd.github+json" "repos/$REPO/actions/artifacts/$id/zip" >"$workdir/artifact.zip"
  unzip -qo "$workdir/artifact.zip" -d "$dest"
  rm -f "$workdir/artifact.zip"
}

pick_exe() {
  local dir=$1
  local found=
  local n=0
  local f
  for f in "$dir"/Yorozu_*_x64-setup.exe; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    found=$f
  done
  if [ "$n" -ne 1 ]; then
    echo "attach-beta.sh: expected one Yorozu_*_x64-setup.exe in $dir, found $n" >&2
    return 1
  fi
  printf '%s\n' "$found"
}

latest_main_artifact() {
  gh api --paginate "repos/$REPO/actions/artifacts?per_page=100" --jq '.artifacts[]' \
    | jq -s '[.[]
        | select((.expired|not) and (.name|startswith("yorozu-windows-")) and .workflow_run.head_branch == "main")
      ] | sort_by(.created_at) | reverse | .[0] // empty | {id,name,expired}'
}

if [ -n "$ARTIFACT_SHA" ]; then
  if ! printf '%s' "$ARTIFACT_SHA" | grep -qE '^[0-9a-f]{40}$'; then
    echo "attach-beta.sh: --artifact-sha must be a full 40-character commit SHA" >&2
    exit 2
  fi
  name="yorozu-windows-$ARTIFACT_SHA"
  art=$(gh api "repos/$REPO/actions/artifacts?name=$name&per_page=10" \
    --jq '[.artifacts[] | select(.expired|not)] | sort_by(.created_at) | reverse | .[0] // empty | {id,name}')
  if [ -z "$art" ] || [ "$art" = "null" ]; then
    echo "attach-beta.sh: no unexpired artifact $name; trying the latest main-branch Windows artifact"
    art=$(latest_main_artifact)
  fi
  if [ -z "$art" ] || [ "$art" = "null" ]; then
    echo "attach-beta.sh: no Windows installer artifact to attach; skipping"
    exit 0
  fi
  id=$(printf '%s' "$art" | jq -r .id)
  mkdir -p "$workdir/exe"
  if ! download_artifact_zip "$id" "$workdir/exe"; then
    echo "attach-beta.sh: could not download artifact $id" >&2
    exit 1
  fi
  FILE=$(pick_exe "$workdir/exe") || exit 1
fi

[ -n "$FILE" ] && [ -f "$FILE" ] || { echo "attach-beta.sh: file not found: ${FILE:-}" >&2; exit 1; }
[ -s "$FILE" ] || { echo "attach-beta.sh: file is empty: $FILE" >&2; exit 1; }
BASENAME=$(basename "$FILE")
require_exe "$BASENAME"
LOCAL_DIGEST=$(digest_of "$FILE")

if ! view=$(gh release view "$TAG" --repo "$REPO" --json isPrerelease,isDraft,tagName,assets,body 2>"$workdir/view.err"); then
  err=$(cat "$workdir/view.err")
  if grep -qiE 'release not found|not found' <<<"$err"; then
    echo "attach-beta.sh: $TAG does not exist yet; skipping"
    exit 0
  fi
  echo "attach-beta.sh: could not read $TAG: $err" >&2
  exit 1
fi

is_pre=$(jq -r .isPrerelease <<<"$view")
is_draft=$(jq -r .isDraft <<<"$view")
if [ "$is_draft" = true ]; then
  echo "attach-beta.sh: $TAG is a draft; skipping"
  exit 0
fi
if [ "$is_pre" != true ]; then
  echo "attach-beta.sh: refusing to attach to $TAG because it is not a prerelease" >&2
  exit 1
fi

latest=$(gh api "repos/$REPO/releases/latest" --jq .tag_name)
if [ "$latest" = "$TAG" ]; then
  echo "attach-beta.sh: refusing to attach to $TAG because it is the latest stable release" >&2
  exit 1
fi

existing=$(jq -r --arg n "$BASENAME" '.assets[] | select(.name == $n) | .digest // empty' <<<"$view")
if [ "$existing" = "sha256:$LOCAL_DIGEST" ]; then
  echo "attach-beta.sh: $BASENAME is already on $TAG with the same digest"
else
  upload=(gh release upload "$TAG" "$FILE" --repo "$REPO")
  if [ -n "$existing" ]; then
    echo "attach-beta.sh: replacing $BASENAME on $TAG (digest changed)"
    upload+=(--clobber)
  fi
  "${upload[@]}"
  echo "attach-beta.sh: attached $BASENAME (sha256:$LOCAL_DIGEST) to $TAG"
fi

if [ "$APPEND_NOTES" = 1 ]; then
  body=$(jq -r .body <<<"$view")
  line="The Windows installer (\`$BASENAME\`) is unsigned, so Windows SmartScreen will warn. Click 「詳細情報」→「実行」 / \"More info\" → \"Run anyway\"."
  if grep -Fq 'Windows SmartScreen' <<<"$body"; then
    echo "attach-beta.sh: release notes already mention Windows SmartScreen"
  else
    if [ -n "$body" ] && [ "${body: -1}" != $'\n' ]; then
      body+=$'\n'
    fi
    if [ -n "$body" ] && [ "${body: -2}" != $'\n\n' ]; then
      body+=$'\n'
    fi
    printf '%s%s\n' "$body" "$line" >"$workdir/notes.md"
    gh release edit "$TAG" --repo "$REPO" --notes-file "$workdir/notes.md"
    echo "attach-beta.sh: added the unsigned/SmartScreen line to $TAG notes"
  fi
fi
