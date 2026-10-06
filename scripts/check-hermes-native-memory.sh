#!/bin/sh
# Required offline release regression. Missing/unpinned inputs fail, never skip.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
: "${YOROZU_HERMES_RUNTIME_ARTIFACT:?required sealed runtime artifact}"
: "${YOROZU_REVIEWED_REPO:?required reviewed repository}"
: "${YOROZU_REVIEWED_SHA:?required reviewed revision}"
# Execute the reviewed test/adapter bytes, not a mixed working-tree harness.
python3 - "$ROOT" "$YOROZU_REVIEWED_REPO" "$YOROZU_REVIEWED_SHA" <<'PYVERIFY'
import pathlib, subprocess, sys
root, repo, revision = sys.argv[1:]
for name in ('adapter.mjs', 'adapter.test.mjs', 'bootstrap.py', 'platform/__init__.py', 'platform/plugin.yaml'):
    relative = 'packages/harness-plugins/hermes/' + name
    expected = subprocess.check_output(['git', '-C', repo, 'show', revision + ':' + relative])
    if (pathlib.Path(root) / relative).read_bytes() != expected:
        raise SystemExit('Native memory gate differs from reviewed source: ' + relative)
PYVERIFY
python3 "$ROOT/scripts/hermes-release-provenance.py" \
  --artifact "$YOROZU_HERMES_RUNTIME_ARTIFACT" \
  --reviewed-repo "$YOROZU_REVIEWED_REPO" --reviewed-revision "$YOROZU_REVIEWED_SHA"
python3 "$ROOT/scripts/package-hermes-runtime.py" verify --artifact "$YOROZU_HERMES_RUNTIME_ARTIFACT"
export YOROZU_REQUIRE_NATIVE_MEMORY=1 YOROZU_HERMES_TEST_SEALED=1
export YOROZU_HERMES_TEST_SOURCE="$YOROZU_HERMES_RUNTIME_ARTIFACT/source"
export YOROZU_HERMES_TEST_PYTHON="$YOROZU_HERMES_RUNTIME_ARTIFACT/python/bin/python3.13"
LOG=$(mktemp "${TMPDIR:-/tmp}/yorozu-native-memory.XXXXXX")
trap 'rm -f "$LOG"' EXIT HUP INT TERM
if ! node --test --test-reporter=tap --test-name-pattern='^native uniform memory discovery replaces vendor memory and preserves messaging checks$' \
  "$ROOT/packages/harness-plugins/hermes/adapter.test.mjs" > "$LOG" 2>&1; then
  cat "$LOG"; exit 1
fi
cat "$LOG"
# A renamed/deleted/skipped regression is not a successful release gate.
grep -qx '# tests 1' "$LOG"
grep -qx '# pass 1' "$LOG"
grep -qx '# skipped 0' "$LOG"
