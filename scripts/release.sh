#!/bin/sh
# Promote an existing tested candidate; never rebuild or re-sign it.
set -eu
cd "$(dirname "$0")/.."
exec python3 scripts/release.py promote "$@"
