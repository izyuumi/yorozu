#!/bin/sh
# node-pty 1.1.0 ships its macOS spawn-helper without an executable bit.
set -eu
[ "$(uname -s)" = Darwin ] || exit 0
helper="$1/prebuilds/darwin-$(uname -m)/spawn-helper"
[ -f "$helper" ] || { echo "missing node-pty spawn-helper: $helper" >&2; exit 1; }
chmod +x "$helper"
