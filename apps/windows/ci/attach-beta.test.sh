#!/usr/bin/env bash
set -euo pipefail

ci="$(cd "$(dirname "$0")" && pwd)"
script="$ci/attach-beta.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GH_TOKEN GITHUB_TOKEN GITHUB_REPOSITORY

failed=0
passed=0
ok() { echo "ok - $1"; passed=$((passed + 1)); }
fail() { echo "FAIL - $1" >&2; failed=$((failed + 1)); }

PATH="$tmp/bin:$PATH"
mkdir -p "$tmp/bin" "$tmp/log" "$tmp/files"

cat >"$tmp/bin/gh" << 'GH'
#!/usr/bin/env bash
set -euo pipefail
ROOT=${ATTACH_TEST_ROOT:?}
log="$ROOT/log/gh.log"
printf '%s\n' "$*" >>"$log"
jq_filter=
prev=
for a in "$@"; do
  if [ "$prev" = --jq ] || [ "$prev" = -q ]; then
    jq_filter=$a
  fi
  prev=$a
done
emit() {
  if [ -n "$jq_filter" ]; then
    jq -r "$jq_filter"
  else
    cat
  fi
}
cmd="$*"
case "$cmd" in
  *"release view "*)
    if [ -f "$ROOT/missing" ]; then
      echo "release not found" >&2
      exit 1
    fi
    emit <"$ROOT/view.json"
    ;;
  *"/releases/latest"*)
    emit <"$ROOT/latest.json"
    ;;
  *"release upload "*)
    printf '%s\n' "$cmd" >"$ROOT/log/upload"
    if [ ! -f "$ROOT/allow-upload" ]; then
      echo "unexpected upload" >&2
      exit 1
    fi
    ;;
  *"release edit "*)
    printf '%s\n' "$cmd" >"$ROOT/log/edit"
    notes=
    prev=
    for a in "$@"; do
      if [ "$prev" = --notes-file ]; then notes=$a; fi
      prev=$a
    done
    if [ -n "$notes" ]; then
      cp "$notes" "$ROOT/log/notes.md"
    fi
    ;;
  *"/actions/artifacts/"*"/zip"*)
    id=${cmd##*artifacts/}
    id=${id%%/zip*}
    id=${id%% *}
    cat "$ROOT/artifacts/$id.zip"
    ;;
  *"/actions/artifacts?name="*)
    emit <"$ROOT/named.json"
    ;;
  *"/actions/artifacts?per_page="*)
    emit <"$ROOT/list.json"
    ;;
  *)
    echo "gh mock: unexpected: $cmd" >&2
    exit 1
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

command -v jq >/dev/null
command -v unzip >/dev/null

exe="$tmp/files/Yorozu_0.17.0_x64-setup.exe"
printf 'MZ-test-installer-%s' "0.17.0" >"$exe"
digest=$(shasum -a 256 "$exe" | awk '{print $1}')

write_view() {
  local pre=${1:-true} draft=${2:-false} existing=${3:-} body=${4-}
  if [ -z "${4+x}" ]; then
    body=$'Yorozu 0.17.0 (7), beta.\n\n## Features\n\n- item\n\n'
  fi
  local assets
  assets=$(jq -n \
    --arg d "$existing" \
    '[{"name":"Yorozu.dmg","digest":"sha256:mac","size":10},
      {"name":"appcast.xml","digest":"sha256:cast","size":2},
      {"name":"candidate.json","digest":"sha256:cand","size":3}]
     | if $d == "" then . else [{"name":"Yorozu_0.17.0_x64-setup.exe","digest":("sha256:"+$d),"size":12}] + . end')
  jq -n --argjson pre "$pre" --argjson draft "$draft" --arg body "$body" --argjson assets "$assets" \
    '{isPrerelease:$pre, isDraft:$draft, tagName:"v0.17.0-beta", body:$body, assets:$assets}' \
    >"$tmp/view.json"
}

echo '{"tag_name":"v0.16.2"}' >"$tmp/latest.json"
rm -f "$tmp/missing" "$tmp/log/"* "$tmp/allow-upload"
mkdir -p "$tmp/artifacts"

run() {
  local want=$1 name=$2
  shift 2
  rm -f "$tmp/log/"*
  : >"$tmp/log/gh.log"
  local got=0
  out=$(ATTACH_TEST_ROOT="$tmp" REPO=izyuumi/yorozu bash "$script" "$@" 2>"$tmp/err") || got=$?
  err=$(cat "$tmp/err")
  if [ "$got" -eq "$want" ]; then
    ok "$name"
  else
    fail "$name: exit $got, wanted $want ($err)"
  fi
}

run 2 'no args'
run 2 'tag only' --tag v0.17.0-beta --repo izyuumi/yorozu
run 2 'bad tag' --tag v0.17.0 --file "$exe" --repo izyuumi/yorozu
run 2 'both file and sha' --tag v0.17.0-beta --file "$exe" --artifact-sha 56a4d69972adabebbd2505d9d9d6430c28eefd29 --repo izyuumi/yorozu
run 2 'short sha' --tag v0.17.0-beta --artifact-sha 56a4d699 --repo izyuumi/yorozu
got=0
out=$(ATTACH_TEST_ROOT="$tmp" env -u REPO -u GITHUB_REPOSITORY bash "$script" --tag v0.17.0-beta --file "$exe" 2>"$tmp/err") || got=$?
err=$(cat "$tmp/err")
[ "$got" -eq 2 ] && ok 'missing repo (no env)' || fail "missing repo: exit $got ($err)"

wrong="$tmp/files/Yorozu_0.16.2_x64-setup.exe"
printf 'MZ' >"$wrong"
write_view true false ""
run 1 'version mismatch' --tag v0.17.0-beta --file "$wrong" --repo izyuumi/yorozu
grep -q 'version 0.16.2' <<<"$err" && ok 'mismatch names versions' || fail "mismatch message: $err"

: >"$tmp/missing"
run 0 'missing release skips' --tag v0.17.0-beta --file "$exe" --repo izyuumi/yorozu
grep -q 'does not exist yet; skipping' <<<"$out$err" && ok 'missing release message' || fail "missing msg: $out $err"
[ ! -f "$tmp/log/upload" ] && ok 'missing release does not upload' || fail 'uploaded on missing release'
rm -f "$tmp/missing"

write_view false false ""
run 1 'refuse non-prerelease' --tag v0.17.0-beta --file "$exe" --repo izyuumi/yorozu
grep -q 'not a prerelease' <<<"$err" && ok 'non-prerelease message' || fail "pre msg: $err"

write_view true false ""
echo '{"tag_name":"v0.17.0-beta"}' >"$tmp/latest.json"
run 1 'refuse latest' --tag v0.17.0-beta --file "$exe" --repo izyuumi/yorozu
grep -q 'latest stable' <<<"$err" && ok 'latest message' || fail "latest msg: $err"
echo '{"tag_name":"v0.16.2"}' >"$tmp/latest.json"

write_view true true ""
run 0 'draft skips' --tag v0.17.0-beta --file "$exe" --repo izyuumi/yorozu
[ ! -f "$tmp/log/upload" ] && ok 'draft does not upload' || fail 'uploaded to draft'

write_view true false ""
: >"$tmp/allow-upload"
run 0 'upload new exe' --tag v0.17.0-beta --file "$exe" --repo izyuumi/yorozu
grep -q 'attached Yorozu_0.17.0_x64-setup.exe' <<<"$out$err" && ok 'upload message' || fail "upload msg: $out $err"
grep -q 'release upload v0.17.0-beta' "$tmp/log/upload" && ok 'called release upload' || fail "upload args: $(cat "$tmp/log/upload" 2>/dev/null)"
if grep -q -- '--clobber' "$tmp/log/upload"; then fail 'new upload used --clobber'; else ok 'new upload has no --clobber'; fi
if grep -q 'release edit' "$tmp/log/gh.log"; then fail 'notes edited without --append-notes'; else ok 'no notes edit by default'; fi
if grep -qE 'Yorozu.dmg|appcast|candidate' "$tmp/log/upload"; then fail 'upload named a Mac asset'; else ok 'upload only the exe'; fi

rm -f "$tmp/log/upload"
write_view true false "$digest"
run 0 'same digest is no-op' --tag v0.17.0-beta --file "$exe" --repo izyuumi/yorozu
[ ! -f "$tmp/log/upload" ] && ok 'same digest does not upload' || fail 're-uploaded same digest'
grep -q 'already on v0.17.0-beta' <<<"$out$err" && ok 'same digest message' || fail "same msg: $out $err"

write_view true false "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
run 0 'replace changed exe' --tag v0.17.0-beta --file "$exe" --repo izyuumi/yorozu
grep -q -- '--clobber' "$tmp/log/upload" && ok 'replace uses --clobber' || fail "replace args: $(cat "$tmp/log/upload")"
if grep -qE 'Yorozu.dmg|appcast|candidate' "$tmp/log/upload"; then fail 'replace named a Mac asset'; else ok 'replace only the exe'; fi

write_view true false "$digest"
run 0 'append SmartScreen notes' --tag v0.17.0-beta --file "$exe" --repo izyuumi/yorozu --append-notes
[ -f "$tmp/log/notes.md" ] || { fail 'notes file missing'; }
if grep -q 'Windows SmartScreen' "$tmp/log/notes.md" && grep -q 'Yorozu 0.17.0 (7), beta.' "$tmp/log/notes.md" && grep -q '詳細情報' "$tmp/log/notes.md"; then
  ok 'notes keep existing text and add SmartScreen line'
else
  fail "notes content: $(cat "$tmp/log/notes.md" 2>/dev/null)"
fi
grep -q 'release edit v0.17.0-beta' "$tmp/log/edit" && grep -q -- '--notes-file' "$tmp/log/edit" || fail "edit args: $(cat "$tmp/log/edit" 2>/dev/null)"
if grep -qE -- '--prerelease|--latest|--draft|--target|--title|--tag ' "$tmp/log/edit"; then
  fail "edit changed flags: $(cat "$tmp/log/edit")"
else
  ok 'notes edit does not change release flags'
fi
grep -q -- '- item' "$tmp/log/notes.md" && ok 'features list kept' || fail 'features list missing'

write_view true false "$digest" $'Yorozu 0.17.0 (7), beta.\n\nThe Windows installer (`Yorozu_0.17.0_x64-setup.exe`) is unsigned, so Windows SmartScreen will warn.\n'
rm -f "$tmp/log/edit" "$tmp/log/notes.md"
run 0 'notes already mention SmartScreen' --tag v0.17.0-beta --file "$exe" --repo izyuumi/yorozu --append-notes
[ ! -f "$tmp/log/edit" ] && ok 'does not re-edit notes' || fail 're-edited notes'

artid=14928345354
mkdir -p "$tmp/ziproot"
cp "$exe" "$tmp/ziproot/Yorozu_0.17.0_x64-setup.exe"
(cd "$tmp/ziproot" && zip -q "$tmp/artifacts/$artid.zip" Yorozu_0.17.0_x64-setup.exe)
jq -n --argjson id "$artid" '{artifacts:[{id:$id,name:"yorozu-windows-56a4d69972adabebbd2505d9d9d6430c28eefd29",expired:false,created_at:"2026-11-24T14:05:49Z",workflow_run:{head_branch:"main"}}]}' >"$tmp/named.json"
write_view true false ""
: >"$tmp/allow-upload"
run 0 'upload from artifact sha' --tag v0.17.0-beta --artifact-sha 56a4d69972adabebbd2505d9d9d6430c28eefd29 --repo izyuumi/yorozu
grep -q 'attached Yorozu_0.17.0_x64-setup.exe' <<<"$out$err" && ok 'artifact upload message' || fail "artifact msg: $out $err"
grep -q "actions/artifacts/$artid/zip" "$tmp/log/gh.log" && ok 'downloaded named artifact' || fail "no zip download: $(cat "$tmp/log/gh.log")"

echo '{"artifacts":[]}' >"$tmp/named.json"
jq -n --argjson id "$artid" '{artifacts:[
  {id:$id,name:"yorozu-windows-56a4d69972adabebbd2505d9d9d6430c28eefd29",expired:false,created_at:"2026-11-24T14:05:49Z",workflow_run:{head_branch:"main"}},
  {id:1,name:"yorozu-windows-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",expired:false,created_at:"2026-11-01T00:00:00Z",workflow_run:{head_branch:"main"}},
  {id:2,name:"yorozu-windows-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",expired:false,created_at:"2026-11-25T12:00:00Z",workflow_run:{head_branch:"feat/other"}}
]}' >"$tmp/list.json"
write_view true false ""
run 0 'fallback to latest main artifact' --tag v0.17.0-beta --artifact-sha cccccccccccccccccccccccccccccccccccccccc --repo izyuumi/yorozu
grep -q "actions/artifacts/$artid/zip" "$tmp/log/gh.log" && ok 'fallback picked newest main artifact' || fail "fallback zip: $(cat "$tmp/log/gh.log")"

echo '{"artifacts":[]}' >"$tmp/named.json"
echo '{"artifacts":[]}' >"$tmp/list.json"
rm -f "$tmp/log/upload"
run 0 'no artifact skips' --tag v0.17.0-beta --artifact-sha cccccccccccccccccccccccccccccccccccccccc --repo izyuumi/yorozu
grep -q 'skipping' <<<"$out$err" && ok 'no artifact message' || fail "no-art msg: $out $err"
[ ! -f "$tmp/log/upload" ] && ok 'no artifact does not upload' || fail 'uploaded without artifact'

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
