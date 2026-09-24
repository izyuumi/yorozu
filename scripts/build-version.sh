#!/bin/sh
# Sourced by shipping builds. Release metadata comes from the caller, never Git history.
: "${VERSION:?VERSION is required (numeric X.Y.Z)}"
: "${BUILD:?BUILD is required (allocated positive integer)}"
VERSION_LABEL=${VERSION_LABEL:-$VERSION}
VERSION_BUILD=${VERSION_BUILD:-$BUILD}

python3 - "$VERSION" "$BUILD" "$VERSION_LABEL" "$VERSION_BUILD" <<'PY'
import re
import sys

version, build, label, display_build = sys.argv[1:]
checks = [
    ("VERSION", version, r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"),
    ("BUILD", build, r"[1-9][0-9]*"),
    ("VERSION_LABEL", label, r"[A-Za-z0-9][A-Za-z0-9 ._()+-]*"),
    ("VERSION_BUILD", display_build, r"[1-9][0-9]*"),
]
for name, value, pattern in checks:
    if not re.fullmatch(pattern, value):
        sys.exit(f"Invalid {name}: expected canonical numeric version/build or plain display label")
PY
