#!/bin/sh
# Prints CFBundleVersion for a visible build: major·10⁷ + minor·10⁵ + patch·10³ + build (0.9.0 build 1 = 900001).
#   scripts/build-number.sh <major.minor.patch> <build>
# Sparkle compares this integer and 0.5.0-beta installs are build 10279, so it only ever rises (OWNER_DECISIONS.md).
# Same formula as bundleVersion in apps/ios/Project.swift.
set -eu
IFS=. read -r major minor patch <<V
$1
V
build=$2
for n in "$major" "$minor" "$patch" "$build"; do
    case "$n" in ''|*[!0-9]*) echo "Expected a numeric major.minor.patch and build, got $1 $2" >&2; exit 64 ;; esac
done
if [ "$minor" -ge 100 ] || [ "$patch" -ge 100 ] || [ "$build" -lt 1 ] || [ "$build" -ge 1000 ]; then
    echo "Version $1 build $2 overflows CFBundleVersion: minor and patch below 100, build 1 to 999" >&2; exit 65
fi
echo $((major * 10000000 + minor * 100000 + patch * 1000 + build))
