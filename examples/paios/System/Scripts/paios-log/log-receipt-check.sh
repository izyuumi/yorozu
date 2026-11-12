#!/bin/bash
# Read-only: every PAIOS log note for an agent, dated on or after <since>, must carry a receipt with all nine fields.
# Usage: log-receipt-check.sh [--bot "<agent name>"] [--dir <Logs dir>] [YYYY-MM-DD since]
# Logs dir: --dir, else $PAIOS_LOGS, else $PAIOS_ROOT/PAIOS/Execution/Logs ($PAIOS_VAULT is the older name for PAIOS_ROOT).
# No --bot checks every dated note. Exit 0 = all pass, 1 = a note is missing fields, 2 = no Logs dir.
root="${PAIOS_ROOT:-${PAIOS_VAULT:-}}"
bot=""; dir="${PAIOS_LOGS:-${root:+$root/PAIOS/Execution/Logs}}"; since="0000-00-00"
while [ $# -gt 0 ]; do
  case "$1" in
    --bot) bot="$2"; shift 2;;
    --dir) dir="$2"; shift 2;;
    *) since="$1"; shift;;
  esac
done
missing() { local m=""
  for k in request context_used tools_used checks retries user_corrections result rollback lesson; do
    grep -qiE "^[-* ]*\**${k}\**:" "$1" || m="$m $k"
  done; echo "$m"; }
[ -d "$dir" ] || { echo "usage: set --dir, PAIOS_LOGS or PAIOS_ROOT (no such dir: $dir)"; exit 2; }
fail=0; n=0
shopt -s nullglob
if [ -n "$bot" ]; then files=("$dir"/????-??-??\ "$bot"\ *.md); else files=("$dir"/????-??-??\ *.md); fi
for f in "${files[@]}"; do
  d=$(basename "$f" | cut -c1-10); [[ "$d" < "$since" ]] && continue
  n=$((n+1)); miss=$(missing "$f")
  if [ -n "$miss" ]; then
    # paios-log forbids editing a note, so a numbered addendum "<name> (N).md" with a full receipt fixes it.
    fixed=""
    for a in "${f%.md}"\ \(*\).md; do [ -z "$(missing "$a")" ] && { fixed="$a"; break; }; done
    # Or a later note with a full receipt that names this one as [[<name>]] or [[<name>|...]].
    # The double-bracket form is this check's own plain-text marker and needs no particular editor;
    # it stays so that existing notes still count. The rest of PAIOS uses ordinary Markdown links.
    if [ -z "$fixed" ]; then
      link="[[$(basename "${f%.md}")"
      while IFS= read -r a; do
        [ "$a" != "$f" ] && [ -z "$(missing "$a")" ] && { fixed="$a"; break; }
      done < <(grep -lF -e "${link}]]" -e "${link}|" "$dir"/????-??-??\ *.md 2>/dev/null)
    fi
    if [ -n "$fixed" ]; then echo "ok $(basename "$f") (receipt in $(basename "$fixed"))"
    else echo "MISSING RECEIPT FIELDS in $(basename "$f"):$miss"; fail=1; fi
  else echo "ok $(basename "$f")"; fi
done
echo "$n notes checked"
[ $fail -eq 0 ] && echo "CHECK PASS" || { echo "CHECK FAIL"; exit 1; }
