# Sealed OpenClaw inputs — DEVELOPMENT ONLY

`packaged-openclaw-runtime.ts`, re-exported by `packaged-agent-runtime.ts`, supplies
`loadPackagedOpenClawRuntime(resourcesRoot)` and
`verifyPackagedOpenClawArtifact(resourcesRoot)`. Only trusted host composition may
supply Resources. It is not a client/config/environment discovery interface.

Fixed layout: `Resources/agent-runtimes/openclaw/{node,source,plugin}`. The loader
validates the complete manifest and rehashes every regular file on every
preparation. Extra/missing/duplicate files, altered bytes/modes, hardlinks,
nonregular files, escaping/dangling/absolute links, linked parents and malformed
metadata fail closed. The manifest binds the exact corrected native commit,
full official-upstream diff, lockfile, build-info, entry, protocol and Node pins.
A sealed inventory cannot authenticate itself: its trust root must be the
immutable trusted app payload/outer signature. Mutable caller-owned Resources
are never suitable. No success cache is permitted. Hashing is before execution,
not a defense against a party allowed to mutate the trusted bundle concurrently.

The helper returns explicit Node and OpenClaw input records. It does not acquire
a broker/listener, launch a Gateway, read a profile, adopt old work or change
scope/identity/memory semantics. Host composition must call it before preparing
the existing curated runtime, and must preserve that runtime's isolation,
listener leases, embedding lifetime and fresh-profile/journal rules. Availability
must not imply provider authorization or a completed paired-device acceptance.

`packaged-agent-runtime.ts` now does exactly that: for an OpenClaw agent it runs
`verifyPackagedOpenClawArtifact(resourcesRoot)` on every preparation (no cached
success) before the curated factory selects a broker or acquires the Gateway
listener, passes the fixed `source`/`plugin/adapter.mjs` paths with
`sourceIntegrity: "sealed-inventory-v1"`, and keeps the curated factory's ordinary
exact-commit/clean-tree Git checks and the adapter's full-diff/build/Node/lock
pins against the sealed minimal Git metadata. The curated pin is the reviewed
corrected commit `f04797ef4d24f3da0f9df74acd58ab773ab5f11e` with full diff
`601c2eea…ebc4e`; only an empty or exact `["memory"]` OpenClaw resource scope is
admitted. The packaged catalog shows OpenClaw available only when the sealed
`runtime-artifact.json` is present and registers `worker-memory-v1` for it on the
basis of the integrated adapter proof (`memory-gateway-proof.mjs`), DEVELOPMENT
only. The sealed plugin tree must contain the complete `plugin/memory-plugin/`
package (bridge module, plugin entry, manifests); the pinned Gateway captures a
plugin as a self-contained package.

## Offline assembly

`scripts/package-openclaw-runtime.py` takes **explicit** `--source`, `--evidence`,
`--plugin`, `--node`, and fresh `--output` paths. It requires the exact clean
reviewed native source/full diff and build digests. It copies tracked source,
reviewed build artifacts and all existing workspace-local node_modules closures,
not a guessed minimal set. It never resolves, installs or downloads dependencies.
Links must stay within the copied closure; each copy is compared with its input.

A new minimal detached Git metadata set retains only the corrected and official
base commits plus their trees/blobs. This satisfies the adapter's existing Git
identity/full-diff verification without weakening it. No branches, original
config, remotes, hooks, alternates or accounts are copied. Missing parent history
is deliberate; the artifact is runtime input, not a complete development clone.
No invocation of a Git repository template occurs.

The archive has canonical metadata and is stream-verified against every file/link
in its inventory. Generated `receipt.json` records archive/manifest/inventory
hashes and explicit provenance limits. All bytes (including adapter and manifest)
are sealed; adapter semantic review remains a separate integration gate.

## What this proves and does not prove

It proves **local byte custody and filesystem closure** from the explicit local
inputs to the packaged archive, not original npm archive provenance, not full
lockfile correspondence of reused installations, not native dynamic-library
relocatability. Including dependencies fixes the earlier archive omission but
is not by itself proof of a standalone installable release. The artifact contains
development dependencies as a conservative superset; no minimal/production
closure claim is made. No production profile/account material is needed.

The schema permits `productionReady:false` only, and exactly two dependency
evidence shapes:

- `reused-local-bytes-inventory-only` (`archiveProvenanceVerified:false`,
  `lockfileMatchEstablished:false`): an existing local closure was reused by bytes.
- `pnpm-frozen-lockfile-install-v1` (`archiveProvenanceVerified:true`,
  `lockfileMatchEstablished:true`, `packageManager`, `lockSha256` = the pinned reviewed
  lockfile, `installedLockSha256`): the closure came from
  `pnpm@<pinned> install --frozen-lockfile --ignore-scripts` of the exact reviewed
  lockfile, so pnpm verified every fetched archive against the lockfile's integrity
  digests and refused resolution changes. The assembler re-checks the pinned lockfile
  digest and the pnpm-written `node_modules/.pnpm/lock.yaml`. Lifecycle scripts are
  not run, so no script-fetched platform binary enters the closure. This is package
  manager integrity verification, not an independent audit of upstream publishers.

Nested code signing changes Mach-O bytes. `package-openclaw-runtime.py
--reseal-after-nested-signing <artifact>` admits only hash changes of existing
Mach-O files with unchanged modes and layout, requires the sealed `node` to be
among them, records `reseal{unsignedInventorySha256, unsignedNodeSha256,
resignedPaths}` and advances `hashStage` to
`after-nested-signing-before-outer-bundle-signing`. The loader accepts that stage
only with that record; every other pin stays exact. `build-mac.sh` bundles an
explicit `YOROZU_OPENCLAW_RUNTIME_ARTIFACT` beside the Hermes runtime, signs its
Node with the Node entitlements, verifies the nested signatures, reseals, re-verifies
through the packaged loader and records the result in `internal-source.json`;
`build-internal-alpha.sh` asserts the signed/unsigned descent in `provenance.json`.

Remaining shipping gates: independent audit of upstream publishers (pnpm
integrity is the only archive check), native shared-library/platform relocation
acceptance beyond the bundle-relocated proof, independent review of the integrated
adapter/memory/packaged composition, `PersonAgentRuntime`-level mixed-harness and
approval-card acceptance, paired-device and provider/account acceptance,
distribution signing/post-sign inventory. The adapter-level integrated Gateway
proof (catalog, dispatch to host SQL, isolation, approval share/revoke, Stop
fencing, restart) is development evidence, not release acceptance. No
upload/install/release is performed.

## Offline tests

- `python3 scripts/test-package-openclaw-runtime.py`
- With the deliberately assembled test fixture, set only
  `YOROZU_TEST_SEALED_OPENCLAW_RESOURCES=<assembly>/Resources` and run Node 26.10.0
  `--experimental-strip-types --test packages/runtime/src/packaged-openclaw-runtime.test.ts`.
  This environment variable belongs to the test harness only. Missing fixture is
  a failure, not a skipped positive test. Run under a network-denied sandbox.
