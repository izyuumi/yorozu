#!/bin/sh
# The external TestFlight kill switch. A step that would give a build to an external TestFlight group or submit it
# to Beta App Review runs this first and goes on only if it exits 0, which it does only when the repository
# variable YOROZU_EXTERNAL_TESTFLIGHT, passed into the job's environment, is exactly `true`. Unset, empty,
# `false`, `TRUE` or anything else exits 1. Builds reach the internal group without it.
#
#   scripts/external_testflight.sh           the switch
#   scripts/external_testflight.sh --audit   exits 1 if a workflow or script names an App Store Connect group or
#                                            Beta App Review call without running the switch (checks.yml)
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" = --audit ]; then
    markers='betaAppReviewSubmissions|betaGroups|distribute_external|distribute-external|submit_beta_review|publicLinkEnabled'
    bad=0
    for file in $(git ls-files .github/workflows scripts); do
        [ "$file" = scripts/external_testflight.sh ] && continue
        grep -qE "$markers" "$file" || continue
        grep -q 'external_testflight\.sh' "$file" && continue
        grep -nE "$markers" "$file" | sed "s|^|::error file=$file::An external TestFlight path without scripts/external_testflight.sh: $file:|"
        bad=1
    done
    [ "$bad" = 0 ] && echo "No external TestFlight or Beta App Review path runs without scripts/external_testflight.sh."
    exit "$bad"
fi
if [ "${YOROZU_EXTERNAL_TESTFLIGHT:-}" = true ]; then
    echo "YOROZU_EXTERNAL_TESTFLIGHT is true: external TestFlight groups and Beta App Review are allowed."
    exit 0
fi
echo "YOROZU_EXTERNAL_TESTFLIGHT is '${YOROZU_EXTERNAL_TESTFLIGHT:-}', not true: internal group only; no external group, no Beta App Review." >&2
exit 1
