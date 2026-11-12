#!/bin/bash
# vault-preflight (runs on the machine that holds the PAIOS folder). Read-only. Prints one JSON line:
# folder reachable, local time, and sha256/mtime of the PAIOS rule files, so an agent re-reads them only when changed.
# Needs PAIOS_ROOT (the folder that contains PAIOS/), or its older name PAIOS_VAULT. Time zone: PAIOS_TZ (default UTC).
VAULT="${PAIOS_ROOT:-${PAIOS_VAULT:-}}"
[ -n "$VAULT" ] || { echo "set PAIOS_ROOT to the folder that contains PAIOS/" >&2; exit 1; }
export TZ="${PAIOS_TZ:-UTC}"
if [ ! -d "$VAULT/PAIOS" ]; then
  echo '{"ok":false,"error":"PAIOS folder not found at PAIOS_ROOT"}'; exit 1
fi
iso() { date "$@" '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/'; }
sha() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -c1-16; }
mtime() { if stat -f '%m' "$1" >/dev/null 2>&1; then iso -r "$(stat -f '%m' "$1")"; else iso -d "@$(stat -c '%Y' "$1")"; fi; }
out="{\"ok\":true,\"host\":\"vault-host\",\"now\":\"$(iso)\",\"files\":{"
first=1
for rel in "PAIOS/README.md" "PAIOS/System/Constitution.md" "PAIOS/AGENTS.md"; do
  f="$VAULT/$rel"
  if [ -f "$f" ]; then
    entry="\"$rel\":{\"sha256_16\":\"$(sha "$f")\",\"mtime\":\"$(mtime "$f")\"}"
  else
    entry="\"$rel\":null"
  fi
  [ $first -eq 1 ] && first=0 || out="$out,"
  out="$out$entry"
done
echo "$out}}"
