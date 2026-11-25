#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
real="$here/workflows/release-mac.yml"

failed=0
passed=0
ok() { echo "ok - $1"; passed=$((passed + 1)); }
fail() { echo "FAIL - $1" >&2; failed=$((failed + 1)); }

release_job() {
  awk '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      job = $1
      sub(/:$/, "", job)
      in_release = (job == "release")
      next
    }
    in_release { print }
  ' "$1"
}

strip_attach_step() {
  awk '
    /name: Attach the unsigned Windows installer to the beta prerelease/ { skip=1; next }
    skip && /^      - name: Forget signing credentials/ { skip=0 }
    !skip { print }
  ' "$1"
}

check_workflow() {
  local file=$1
  local job publish_line attach_line after
  [ -f "$file" ] || return 1
  job=$(release_job "$file")
  [ -n "$job" ] || return 1
  publish_line=$(printf '%s\n' "$job" | grep -nF 'scripts/release_mac.sh --publish' | head -1 | cut -d: -f1 || true)
  attach_line=$(printf '%s\n' "$job" | grep -nF 'apps/windows/ci/attach-beta.sh' | head -1 | cut -d: -f1 || true)
  [ -n "${publish_line:-}" ] || return 1
  [ -n "${attach_line:-}" ] || return 1
  [ "$attach_line" -gt "$publish_line" ] || return 1
  after=$(printf '%s\n' "$job" | sed -n "${publish_line},\$p")
  printf '%s\n' "$after" | grep -Fq 'apps/windows/ci/attach-beta.sh' || return 1
  printf '%s\n' "$after" | grep -Fq -- '--append-notes' || return 1
  printf '%s\n' "$after" | grep -Fq -- '--artifact-sha' || return 1
  printf '%s\n' "$after" | grep -Fq -- '--tag' || return 1
  printf '%s\n' "$after" | grep -Fq 'dist/candidate.json' || return 1
  printf '%s\n' "$after" | grep -Eq '\.tag' || return 1
  printf '%s\n' "$after" | grep -Eq '\.source_sha' || return 1
  return 0
}

if check_workflow "$real"; then
  ok "Release Mac job runs attach-beta.sh after publish with candidate tag, sha, and --append-notes"
else
  fail "Release Mac job must call attach-beta.sh after release_mac.sh --publish using dist/candidate.json and --append-notes"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$real" "$tmp/ok.yml"
if check_workflow "$tmp/ok.yml"; then
  ok "a copy of the real workflow still passes"
else
  fail "a copy of the real workflow should pass"
fi

awk '
  /apps\/windows\/ci\/attach-beta.sh/ { skip=1 }
  skip && /^      - name: Forget signing credentials/ { skip=0 }
  !skip { print }
' "$real" >"$tmp/no-attach.yml"
if check_workflow "$tmp/no-attach.yml"; then
  fail "missing attach-beta.sh should fail"
else
  ok "missing attach-beta.sh fails"
fi

printf '%s\n' "      - name: Attach the unsigned Windows installer to the beta prerelease" >"$tmp/early.yml"
printf '%s\n' "        run: bash apps/windows/ci/attach-beta.sh --tag v0.0.0-beta --artifact-sha dead --append-notes" >>"$tmp/early.yml"
needle="      - name: Build, notarize and publish the Mac beta"
: >"$tmp/before.yml"
while IFS= read -r line; do
  if [ "$line" = "$needle" ]; then
    cat "$tmp/early.yml" >>"$tmp/before.yml"
  fi
  printf '%s\n' "$line" >>"$tmp/before.yml"
done < <(strip_attach_step "$real")
if check_workflow "$tmp/before.yml"; then
  fail "attach before publish should fail"
else
  ok "attach before publish fails"
fi

{
  strip_attach_step "$real"
  printf '%s\n' ''
  printf '%s\n' '  attach:'
  printf '%s\n' '    runs-on: ubuntu-latest'
  printf '%s\n' '    steps:'
  printf '%s\n' '      - run: bash apps/windows/ci/attach-beta.sh --tag v0.0.0-beta --artifact-sha dead --append-notes'
} >"$tmp/other-job.yml"
if check_workflow "$tmp/other-job.yml"; then
  fail "attach in a different job should fail"
else
  ok "attach in a different job fails"
fi

sed '/--append-notes/s/--append-notes//' "$real" >"$tmp/no-notes.yml"
if check_workflow "$tmp/no-notes.yml"; then
  fail "missing --append-notes should fail"
else
  ok "missing --append-notes fails"
fi

sed 's/dist\/candidate.json/dist\/missing.json/;s/\.source_sha/.commit/' "$real" >"$tmp/no-candidate.yml"
if check_workflow "$tmp/no-candidate.yml"; then
  fail "missing candidate.json source_sha should fail"
else
  ok "missing candidate.json source_sha fails"
fi

echo "passed=$passed failed=$failed"
[ "$failed" -eq 0 ]
