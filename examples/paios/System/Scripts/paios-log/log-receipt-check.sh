#!/bin/bash
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
    fixed=""
    for a in "${f%.md}"\ \(*\).md; do [ -z "$(missing "$a")" ] && { fixed="$a"; break; }; done
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
