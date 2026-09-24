#!/bin/sh
# Point rolling beta at an existing main candidate; keep every legacy download.
set -eu
cd "$(dirname "$0")/.."
exec python3 scripts/release.py beta "$@"
