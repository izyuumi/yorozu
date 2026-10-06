# Minimal worker integration handoff

**Status: supported managed-Hermes source integration complete and signed; ready for parent review/build.** This is not a live-provider/device or publication receipt. The final handoff commit contains only documentation/evidence/staging selection after executable checkpoint `e8c657ecca6411b770d2dbeb072d957311d3d6c4`. Obtain the one final candidate SHA with `git rev-parse HEAD`; the parent reply supplies it explicitly. All children have finished and their work is integrated. No second integrator or duplicate child jobs are needed.

## Location and custody

- Worktree: `/Users/yumi/Projects/yorozu-wt/minimal-workers-20261006` (detached; no new branch).
- Reviewed base: `be87a28fc75f1a8a0124a8ce3557f85de6ad2b2c`.
- Earlier signed slice: `4f5305bbc1e82b1e39de773e8f6e9366dcd84bdc`.
- Earlier tested executable source: `e3282e543d17daeeb66456b6c90517478d98878a`.
- Native memory editor `2dbe825`; menu-bar policy `b52baf7`; packaged activation/migration `4b4eafc`, `70ddd49`, `1e274fb`; typed held-settings rejection `f888fde`; native execution currency `c3839e9` (all signed).
- Parent owns canonical-branch integration, publication, TestFlight upload and normal-app replacement. This worker performs none of those actions.

There is a separate active canonical-branch cleanup/PR review. No branch refs are changed here. Before integration, the parent must obtain its target/ref/ancestry readback and confirmation that the retained source is preserved. In particular, do not assume an old alpha tip contains `be87a28`, reset `main`, delete an open PR source, or remove this active worktree. If the selected canonical tip does not contain the reviewed base, reconcile with that owner rather than blindly applying the delta.

## Changes versus the reviewed base

1. Small host-side adapter registry and explicit minimal composition (`worker-platform.ts`), distinct from durable `agents-v1` identity. No new SDK or model planner above the harness.
2. Canonical host-only SQLite memory (`worker-memory.ts`); independent namespaces, owner-only writes, per-note read/search grants, revocation, transactional/payload-checked receipts, finite budgets and literal search. No production imports, vector service or RAG claim.
3. Process-bound memory tools (`worker-tools.ts`) and a bounded bidirectional pipe contract. Sharing uses the existing exact native action/approval card; no caller-supplied acting identity or global bypass.
4. Hermes `worker_memory` bridge, native-memory disable configuration, explicit negotiation and real adapter/host-pipe compatibility test. Missing support is unavailable, never native-memory fallback.
5. Retained host supervisors enforce OS scope, stop/current-attempt currency, durable admission, uncertainty, restart and quiescent profile separation/rollback.
6. Production phone projection preserves the negotiated person registry; closed host controls retain a read-only shutdown projection without reopening mutations.
7. Existing native SwiftUI editor exposes the Memory permission only for an available managed harness advertising `worker-memory-v1`. A newly created second agent can receive or remove that permission. English/Japanese explanation added; legacy/unsupported descriptors do not imply authority.
8. Packaged/account composition now selects the central worker platform and retains the sole protected account owner. Unsettled old work is visibly held with durable settings rejection, not replayed or routed to the old planner. Native host launch defaults to the menu bar. Adapter-stamped session/run/attempt envelopes support verified continuations as well as foreground tools; stop invalidates all capability scopes before waiting for native receipts.

## Every owner acceptance, with evidence boundary

| Requirement | Implemented/proven so far | Remaining acceptance |
| --- | --- | --- |
| Minimal native SwiftUI macOS/iOS clients | Existing native scene/chat/agent/settings/action surfaces retained; no web/Electron replacement. Native memory-editor change compiled; three selected Swift tests and localization guard passed. | Final Mac build and both native-client display checks; physical iPhone not exercised by this worker. |
| Configured host defaults to menu-bar-only | Existing `MenuBarExtra`, explicit Open/Settings, onboarding and independent host service retained. | Native policy source integrated; child compiled the real app target and passed 30 Mac tests. Combined native receipt is above; actual window/device behavior remains a parent acceptance gate. Verify a configured cold launch shows no automatic chat window, onboarding still appears when needed, and closing a client window leaves the host running. |
| Packaged new backend actually active | The actual packaged factory now selects uniform workers and the `yorozu` secretary through the existing protected native account host. No legacy planner fallback; no ambient selector. | Fresh/quiescent activation and eleven unsettled/damaged migration conditions have compiled-entry tests. Verify final bundled entry and exact runtime artifact, not only an injected test option. |
| Two registered agents, independent durable memory | Real encrypted loopback relay registers Alice/Bob; canonical SQL, scope and immutable receipts are exercised. SQL reopening and quiescent native/uniform profile rollback preserve notes without import. | Run the same scenario with the final native gateway/provider and connected iPhone; fake protocol peers are not live execution proof. |
| Intentional share/revoke through existing iPhone UI | Existing native `HarnessActionCard`/`answerHarnessAction` carries exact origin and one-shot choice. Encrypted denial, pending-state denial, approval, selected-note-only sharing and revocation pass. Memory toggle is now reachable in the native agent editor. | Actual iPhone Create Agent → Memory permission → chat request → approval card → recipient read → revoke. Sharing is a chat/tool flow, not the obsolete preference-journal form. |
| Relay, pairing, onboarding and history preservation | Relay/crypto/public schemas unchanged; registry projection repaired behind negotiated capability filtering. No pairing/credential/history migration or production data import. Old evidence/profile bytes retained; unresolved work never automatically resubmitted. | Test final bundle against retained pairing/history and a fresh onboarding profile before replacing the normal app. Never clear old work merely to satisfy the migration gate. |
| Tools and approvals | Scoped native tools remain harness-owned. New memory tool cannot select its actor or write another namespace. Grant requires exact owner approval; changed-note rejection does not fabricate unknown mutation. | Native tool discovery and harmless live tool call in the final bundle. Verified-continuation provenance is implemented and tested against native contract fixtures; no guessing onto a foreground turn. |
| Cancel and restart | Exact stop intent invalidates foreground memory/approval authority; stale card cannot revive in a later turn. Lost post-commit receipt retains unknown fence. Cancellation persistence errors settle the tool promise. Durable notes/receipts survive reopen; no automatic replay. | Continuation-currency regressions passed. Actual packaged clean restart/stop readback remains required. Crash/unknown tests use isolated fixtures, not destructive experiments on production work. |
| Different harnesses | Central map separates implementation ID from person identity; multiple agents can share one implementation without sharing memory. Existing OpenClaw remains explicitly unavailable unless a verified compatible implementation is selected. | No claim of a real mixed-harness deployment. A second real uniform-memory adapter/packaged runtime remains a gate if mixed-harness operation is required for this delivery. Do not broaden the earlier blocked OpenClaw fetch/build authority. |

## Final integrated receipts

**Quality-first final-source run completed:** exact signed source `fb4d2e6746202d7809f0ff49dfb64895ffab3cc6`, assembled at `/private/tmp/yorozu-final-quality-20261006`, passed **548 runtime tests** (6 optional skips), **98 native tests** (zero skips, including the composer and host-launch cases), **86 adapter tests** (6 optional native skips), **10 shared protocol tests**, **22 isolated Rust cases** and the explicit **kernel file-isolation probe**. Staged shared/runtime/relay TypeScript and native Swift compilation passed. `internal-swift.json` and `internal-host.json` in that assembly bind receipts to this exact SHA. The final handoff update after that SHA changes only this documentation/evidence, not application, test, workflow or staging code. Actual release gates below remain unchanged.

### Earlier incremental receipts (preserved, not substituted for the final run)

Current record: `docs/verification/minimal-workers-integrated-20261006.json`.

- Runtime: **547 passed / 6 optional skipped**, 40 files, at `9147d80`; 105 runtime/shared-TS/adapter executable files were byte-identical through final integration, so the unchanged full suite was not repeated.
- Adapters: **86 passed / 6 optional native skipped**; shared wire projection: **10 passed**.
- Native bounded gate: **97 passed / zero skipped**, source `02556cf`; actual Mac/shared Swift targets compiled. The only later native product-source difference is the reviewed composer handler extraction, separately compiled/executed with **1 exact native regression passed**. Future bounded CI includes that exact case; there is no fabricated single 98-test receipt.
- Final changed-path packaged/304 checks: **22 passed**, source `0163819`.
- Commit guardrails: **5 passed**, shell syntax checked; files match the prepared reviewed guardrail patch. Native selector self-tests: **16 passed**. Staging: **9 passed**, with reviewed iOS source and toolbar fixtures retained. Localizations passed.
- Earlier exact isolated Rust **22-pass** receipt remains applicable: Rust source/tests have not changed.
- Historical iOS toolbar simulator receipts were preserved with `d871ff9`; no fresh simulator or physical-iPhone run is claimed here.

### Prepared patches integrated

| Prepared patch | Integrated commit | Review/validation |
| --- | --- | --- |
| `bf65ad5` | `dece570` | Candidate-aware navigation; updated to actual packaged selection |
| `e46c5ad` | `73aa83b` | Fail-closed PR subject enumeration; five local tests and shell syntax; unchanged prepared workflow |
| `ece28f` | `52ef274` | Native handler extraction preserves original logic; exact real-field caret regression passed |
| `d871ff9` | `f2f6e29` | Scoped offline history-toolbar test/docs preserved; no new UI acceptance claim |

### 304 decision

**Resolved for the final packaged candidate by retiring legacy admission, not by adopting the declined legacy planner extension.** The compiled-entry `304 retirement gate` test proves both runner routes refuse retained legacy task resumption, resume/rewind are disabled, task Stop cannot prepare an owner, the old planner is not instantiated, and old history is unchanged. Worker startup with unsettled state stays visibly held without fallback.

**Legacy execution/rollback remains explicitly restricted.** This is not a narrow fix to the old resume implementation, and an older app or unselected developer composition must not be approved for legacy worker resumption on this evidence. Preserve it for evidence/custody; separately fix or prove the specific rollback path before enabling that execution.

## Earlier slice receipt (historical)

`docs/verification/minimal-workers-20261006.json` records source `e3282e5`:

- Staged production runtime: **526 passed / 6 optional skipped**, 39 files.
- Hermes + OpenClaw adapter contract tests: **84 passed / 6 optional native skipped**.
- Shared registry/action/peer protocol tests: **10 passed**.
- Exact isolated Rust gate: **22 passed**, six groups; no aggregate recovery/interposer/FIFO run.
- Staging tests: **9 passed**.
- Separately selected kernel file-isolation probe: **1 passed**.
- Real confined relay peer additionally requires EPERM/EACCES when trying to read the existing synthetic canonical database; ENOENT is not accepted as isolation proof.
- Actual Hermes `serve()` + `HarnessProcess` + SQL test passes against a deterministic native gateway.
- Native editor follow-up: **3 selected Swift tests passed**, shared package compiled; English/Japanese catalog guard passed.

Deterministic gateway/protocol peers are **not** live Python/harness/model/provider/subscription or physical-device proof. The newer integrated receipts above supersede this slice for source acceptance; historical counts are never relabeled with later executable SHAs.

## Parent commands: local review and source validation only

These commands do not create/change branches, sign app bundles, publish, install or access accounts.

```sh
cd '/Users/yumi/Projects/yorozu-wt/minimal-workers-20261006'
git status --short
git rev-parse HEAD
git log be87a28..HEAD --format='%H %G? %s'
git diff --check be87a28..HEAD
git diff --stat be87a28..HEAD
python3 scripts/test-stage-internal-alpha.py  # run in the Git source checkout
python3 scripts/test-commit-msg.py            # likewise: requires the source Git history
# Inspect each intended source delta, not merely this report.
git diff be87a28..HEAD -- packages/runtime packages/harness-plugins packages/shared-swift apps/mac apps/ios scripts

NODE26="$(mise where node@26.10.0)/bin/node"
"$NODE26" --version                 # must read v26.10.0
CHECK="$(mktemp -d /private/tmp/yorozu-worker-review.XXXXXX)"
python3 scripts/stage-internal-alpha.py "$CHECK"  # requires clean, committed source
cd "$CHECK"
pnpm install --offline --ignore-scripts --frozen-lockfile
"$NODE26" packages/shared/node_modules/typescript/bin/tsc -p packages/shared
"$NODE26" packages/runtime/node_modules/typescript/bin/tsc -p packages/runtime
"$NODE26" apps/relay/node_modules/typescript/bin/tsc -p apps/relay
cargo build --locked --offline --manifest-path packages/host-core/Cargo.toml
export YOROZU_HOST_CORE="$CHECK/packages/host-core/target/debug/yorozu-host-core"
export YOROZU_SECRETARY_HOST="$CHECK/packages/host-core/target/debug/yorozu-alpha-host"
export TMPDIR=/private/tmp
(cd packages/runtime && "$NODE26" node_modules/vitest/vitest.mjs run \
  worker- harness agent- person-agent- curated-agent- packaged-agent- \
  siwc- native-account- secretary- --maxWorkers=2)
"$NODE26" --test packages/harness-plugins/hermes/adapter.test.mjs \
  packages/harness-plugins/openclaw/adapter.test.mjs
"$NODE26" packages/shared/node_modules/vitest/vitest.mjs run \
  packages/shared/src/person-agents packages/shared/src/peer-info --maxWorkers=2
CARGO_NET_OFFLINE=true python3 scripts/check-internal-host.py --receipt "$CHECK/internal-host.json"
"$NODE26" scripts/check-localizations.mjs
# Shared Swift package has no remote package dependencies. No UI is launched.
env -u SDKROOT swift test --package-path packages/shared-swift --filter \
 'uniformMemoryIsVisibleAndCanBeEnabledOrRemovedForANewNativeAgent|nativeEditorDoesNotInferUniformMemoryFromVendorNameOrAnUnavailableDescriptor|reviewNewAgentHasNoHiddenMemoryOrDelegationGrants'
```

For native full compilation, first ensure the reviewed locked Sparkle dependency is available locally, then use `env -u SDKROOT swift build --package-path apps/mac --product YorozuMac --skip-update --disable-automatic-resolution`. A local executable build is not a signed/distributable app. Run the safe native-client/account fixtures via `scripts/check-internal-swift.py --receipt <temporary-receipt>` rather than selecting mixed UI/ChatModel aggregates. Launch-policy functions are `hostPresentationDefaultsWithoutOverwritingSavedChoices`, `onlyHostsUseBackgroundPresentation`, `automaticLaunchPreservesClientAndOnboardingRoutes`, and `closingLastWindowDoesNotQuitHost`; run these from the Mac package with `swift test --skip-update --filter <function-regex>`.

**Do not use `scripts/build-ios.sh` as a harmless local compile:** it exports with `destination: upload` and may perform provisioning. `scripts/build-internal-alpha.sh` / `build-mac.sh` are also parent commit-point operations: they use signing, runtime intake and potentially notarization. They are not run by this worker.

## Actual release gates, not a blanket denial

The owner has conditionally authorized eventual existing internal TestFlight distribution, GitHub alpha and replacement of the normal Yorozu.app. Parent owns execution of those commitments. The earlier hold does **not** mean asking for the same authorization again; it means the old pre-rewrite artifact must not be shipped as the requested new backend.

Before those parent commit points:

1. Review the integrated source corrections and obtain final branch-bound CI. The combined local proofs above cover packaged selection/no fallback and native launch policy; they do not replace the final branch/build/device checks.
2. Obtain canonical-branch/PR review clearance and exact target/source ancestry from the separate cleanup owner. Preserve every unique/dirty/active source. Run branch-bound CI/review against the final integrated SHA, not an unrelated green run.
3. Regenerate and verify the packaged Hermes runtime artifact against the changed adapter/plugin/bootstrap source and pinned public inputs. Old adapter inventory/digests cannot stand in for this source. Verify the protected account helper's real provisioning/entitlements and exact source/bundle provenance. Do not alter permissions or use ambient credentials to bypass a failure.
4. Execute authorized bounded native/tool/account validation with a fresh test profile and explicit selected account/model: subscription/broker path only, no automatic paid/provider fallback. Prove tool catalog, native memory-disable behavior, actual invocation, approval, stop and restart. Deterministic tests do not clear this gate.
5. Exercise native Mac and connected-iPhone acceptance below. Verify preserved pairing/history and safe handling of any retained migration holds before normal-profile adoption.
6. Allocate version/build identities through the existing workflow, sign/notarize, distribute to the existing internal TestFlight group and GitHub alpha, verify publication readback and artifact/source hashes, then replace the normal app only with rollback/data preservation and post-install identity readback. No second app or development bundle substitutes for the owner's acceptance.

## Bounded connected-iPhone acceptance plan

Use synthetic note contents and a fresh unique nonce; no private files, messaging, purchases, browser or other external tools.

1. Confirm final Mac bundle/version/source, menu-bar-only configured launch, deliberate Open/Settings access, and host survival after closing its client window. Separately check first-run onboarding in an isolated profile.
2. Keep existing pairing. Open the native agent list, configure the first agent's explicitly selected account/model, and create a second managed agent with Memory enabled. Confirm distinct canonical conversations and durable agent IDs.
3. Ask each agent to save a different short `worker_memory` note containing the nonce. Read/search own notes. Ask the second to read the first's private note: it must be denied, without a file/tool bypass.
4. Ask the first to share only one note with the second. First deny the native harness card and verify no access. Repeat with a fresh operation, approve the exact note/recipient, verify the selected note is readable and another private note remains denied. Ask the first to revoke; re-read/search must deny the revoked note. A grant covers future updates until revoked, as the card states.
5. After confirmed idle, restart the final host; verify both private notes and revoked access persist, no old input/grant is resent, and history/pairing remain intact.
6. Test a harmless pending approval and Stop. A stopped/completed attempt's stale card must not grant in a later attempt. Use isolated automated fixtures for forced-crash/unknown-outcome tests; do not kill production work to manufacture evidence.
7. Capture exact source/build, device/OS, account/model selection (opaque IDs, no credentials), observed native tool receipts, screenshots of synthetic UI states and pass/fail for each step. Installation and a scheduler `ok` are not acceptance evidence.

## Rollback proof limit

The automated profile rollback test switches compositions within this candidate and verifies preserved sources; it is not proof that an older installed binary can safely consume every new journal. Validate the retained original app and a safely isolated profile copy before normal-app replacement. Preserve both pre-adoption and candidate-created history/memory evidence and protected account identity; do not restore stale credentials or discard candidate data to make rollback appear successful.

## Canonical-branch coordination

No named local or remote ref was changed by this worker. The last local cached readback was local alpha at reviewed `be87a28`, remote-tracking alpha at `1673b2e`, and main at `5be369c`; no fetch was performed. These are **not current GitHub/PR clearance**. The parent must reconcile the active cleanup/PR owner before applying the signed delta. Check that the approved target contains `be87a28`; otherwise stop and reconcile ancestry. Do not cherry-pick only this delta onto an older base missing its retained supervisors.
