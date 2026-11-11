#!/bin/bash
# Runs every example script against a temporary copy of this PAIOS folder. Changes nothing else.
# Prints SELFTEST PASS (exit 0) or the first failing step (exit 1).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
root="$tmp/root"
mkdir -p "$root" && cp -R "$src" "$root/PAIOS"
# The scripts read PAIOS_ROOT, else its older name PAIOS_VAULT. Point exactly one of them at the copy:
# PAIOS_VAULT when that is the only one the caller has set (an older install), else PAIOS_ROOT.
if [ -z "${PAIOS_ROOT:-}" ] && [ -n "${PAIOS_VAULT:-}" ]; then
  unset PAIOS_ROOT; export PAIOS_VAULT="$root"
else
  unset PAIOS_VAULT; export PAIOS_ROOT="$root"
fi
export PAIOS_TZ="${PAIOS_TZ:-UTC}" PAIOS_PREFLIGHT_STATE="$tmp/state"
unset PAIOS_LOGS HANDOFF_ROOT HANDOFF_ROLES
S="$root/PAIOS/System/Scripts"
fail() { echo "SELFTEST FAIL: $1"; exit 1; }
expect() { local want="$1"; shift; out="$("$@" 2>&1)"; [[ "$out" == *"$want"* ]] || fail "$* -> $out"; }

# vault-preflight: first run lists files to re-read, second run says unchanged
json="$(bash "$S/vault-preflight/preflight.sh")" || fail "preflight.sh"
expect "RE-READ" bash -c "printf '%s' '$json' | python3 '$S/vault-preflight/compare.py' --bot selftest"
expect "unchanged" bash -c "printf '%s' '$json' | python3 '$S/vault-preflight/compare.py' --bot selftest"

# paios-log: writes a note, numbers a second one, refuses a secret
cat > "$tmp/r.json" <<'J'
{"request":"selftest","context_used":"none","tools_used":"none","checks":"none","retries":"0","user_corrections":"none","result":"ok","rollback":"delete the note","lesson":"none"}
J
expect "Execution/Logs/" python3 "$S/paios-log/paios-log.py" --bot selftest --topic run --receipt "$tmp/r.json"
expect "(2).md" python3 "$S/paios-log/paios-log.py" --bot selftest --topic run --receipt "$tmp/r.json"
printf 'token: ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123456789" > "$tmp/bad.md"
expect "REFUSED" python3 "$S/paios-log/paios-log.py" --bot selftest --topic bad --receipt "$tmp/r.json" --body-file "$tmp/bad.md"
expect "CHECK PASS" bash "$S/paios-log/log-receipt-check.sh"

# handoff: new, claim, done, check
expect "Tell the receiver" python3 "$S/handoff/handoff.py" new --from product-owner --to coder --slug selftest --ask "Selftest." --done-when "check passes" --reply-to product-owner --body-file /dev/null
f="$(ls "$root/PAIOS/Handover/inbox/coder/"*-product-owner-selftest.md)"
expect "claimed" python3 "$S/handoff/handoff.py" claim "$f" --by coder
expect "done/coder/" python3 "$S/handoff/handoff.py" done "$f" --by coder --result "selftest ok"
expect "CHECK PASS" python3 "$S/handoff/handoff.py" check
expect "not a role slug" python3 "$S/handoff/handoff.py" new --from nobody --to coder --slug x --ask x --done-when x --reply-to x --body-file /dev/null

echo "SELFTEST PASS"
