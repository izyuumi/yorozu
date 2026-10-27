#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build .build/tmp .build/module-cache
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift test --cache-path .build/dependency-cache --config-path .build/config --security-path .build/security "$@"
