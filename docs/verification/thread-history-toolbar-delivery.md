# Read-only delivery-route assessment (2026-10-06)

No release/account command has been executed for this assessment.

## Existing iOS-only capability

`scripts/build-ios.sh` already supports a local, signed **iOS-only** internal upload:
`VERSION=0.6.0 BUILD=<allocated> INTERNAL_ONLY=1 DIST=<isolated-ios-dist> ./scripts/build-ios.sh`.
It sets `TUIST_SECRETARY_ENABLED=true`, archives for generic iOS, checks that the
archive contains `YorozuSecretaryEnabled=true`, exports one retained IPA, and uploads
using `testFlightInternalTestingOnly=true`. It neither builds nor notarizes a Mac app.
Uses existing ASC credential path/identifiers and automatic signing; account/identity
availability was deliberately NOT checked in this worker.

Parent-controlled sequence, only after exact-source review/CI, current signing and
owner delivery authority checks, and with no concurrent release allocation:
1. Verify clean exact signed source; preserve the existing exact-source/CI gate from
   `scripts/publish-internal-beta.py --check-source --source <SHA> --branch <branch>`.
2. With normal protected credential routing, `node scripts/asc-internal.mjs preflight`.
   This verifies app bundle `to.yumi.yorozu.ios`, the established internal group,
   one tester, and no other auto-all-builds internal group. Do not enumerate identities.
3. `node scripts/asc-candidate.mjs next-build 0.6.0` allocates the next build number by
   reading ASC. Allocation must be serialized with all other uploads (script alone
   is not an atomic reservation). Do NOT call this script's `distribute` command;
   that is the external TestFlight path.
4. Execute the internal-only build-ios command above once. Retain archive, signed IPA,
   export options, build metadata, source SHA and checksums in the private receipt.
5. `node scripts/asc-internal.mjs resolve 0.6.0 <build> <ios.json>` waits for the exact
   valid INTERNAL_ONLY build. Then `distribute <ios.json> <availability.json>` assigns
   only the established internal group and waits for IN_BETA_TESTING.
6. `node scripts/asc-internal.mjs verify <ios.json> <verification.json>` is the
   read-only readback route. Verify exact source-to-artifact provenance locally too;
   the ASC scripts verify app/version/build/audience/group, not source contents.
7. If upload result is uncertain, resolve/read back the exact build before retrying.

## GitHub workflow limitation

There is **no existing iOS-only internal workflow_dispatch input/job**. In
`.github/workflows/release.yml`, `internal_only=true` unconditionally runs `internal`,
which intakes the Hermes runtime, prepares both Mac/iOS signing, notarization
credentials, builds a signed Mac package, uploads iOS, and requires both platform
artifacts in provenance. `publish_mac_beta=false` disables publication only, not the
Mac build. The public route also invokes legacy UI gates and is inappropriate here.

If parent prefers hosted dispatch over the existing local script-level route, a narrow
workflow change is necessary: an iOS-only internal job/input retaining reviewed SHA,
valid signed source and exact-CI gate, native acceptance evidence, serialization,
existing-group preflight, internal-only export flag, exact build availability checks,
private signed IPA/provenance artifacts, and cleanup. Do not dispatch the whole release
as a workaround and do not skip its source/authority gates.

No workflow edits, remote reads, account access, signing, dispatch, upload, push,
publication, or installation were performed by this assessment.
