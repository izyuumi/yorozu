#!/bin/sh
# Required offline release regression. Missing/unpinned inputs fail, never skip.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
: "${YOROZU_HERMES_RUNTIME_ARTIFACT:?required sealed runtime artifact}"
: "${YOROZU_REVIEWED_REPO:?required reviewed repository}"
: "${YOROZU_REVIEWED_SHA:?required reviewed revision}"
# Execute the reviewed test/adapter bytes, not a mixed working-tree harness.
git -C "$ROOT" diff --exit-code "$YOROZU_REVIEWED_SHA" --   packages/harness-plugins/hermes/adapter.mjs packages/harness-plugins/hermes/adapter.test.mjs   packages/harness-plugins/hermes/bootstrap.py packages/harness-plugins/hermes/platform
python3 "$ROOT/scripts/hermes-release-provenance.py" \
  --artifact "$YOROZU_HERMES_RUNTIME_ARTIFACT" \
  --reviewed-repo "$YOROZU_REVIEWED_REPO" --reviewed-revision "$YOROZU_REVIEWED_SHA"
python3 "$ROOT/scripts/package-hermes-runtime.py" verify --artifact "$YOROZU_HERMES_RUNTIME_ARTIFACT"
export YOROZU_REQUIRE_NATIVE_MEMORY=1 YOROZU_HERMES_TEST_SEALED=1
export YOROZU_HERMES_TEST_SOURCE="$YOROZU_HERMES_RUNTIME_ARTIFACT/source"
export YOROZU_HERMES_TEST_PYTHON="$YOROZU_HERMES_RUNTIME_ARTIFACT/python/bin/python3.13"
node --test --test-name-pattern='^native uniform memory discovery replaces vendor memory and preserves messaging checks$' \
  "$ROOT/packages/harness-plugins/hermes/adapter.test.mjs"
