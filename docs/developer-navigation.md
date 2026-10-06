# Developer navigation and scoped checks

This map adapts the useful navigation from PR #295 to the minimal-worker candidate. It does not
select a backend, authorize a release, or certify unfinished integration. Start with
[the minimal-worker contract](minimal-workers.md), then inspect the exact source you are changing.
The first candidate's packaged entry was not selected; consult the final integration's source and
receipts rather than assuming that a documented option is the shipped default.

## Find the owning boundary

| Work | Read first |
| --- | --- |
| Minimal composition and adapter selection | `packages/runtime/src/worker-platform.ts`, `secretary-serve.ts` and `docs/minimal-workers.md` |
| Canonical SQL memory, grants and process-bound tools | `worker-memory.ts`, `worker-tools.ts` under `packages/runtime/src`; keep identity, ownership and one-shot approval separate |
| Native harness adapter | `packages/harness-plugins/hermes/adapter.mjs` or `packages/harness-plugins/openclaw/adapter.mjs`, sibling `adapter.test.mjs`, and the pinned runtime contract |
| Retained execution supervisor / transport | `person-agent-runtime.ts`, `harness-process.ts`, `harness-runner.ts`, `harness-ledger.ts`; production composition also uses `scripts/secretary-production.patch` |
| Native clients and protocol | `apps/mac`, `apps/ios`, `packages/shared-swift`, `packages/shared`; preserve pairing/history and negotiated capabilities |
| Legacy OpenClaw channel, not a minimal-worker adapter | `packages/openclaw-channel/README.md`, `channel.js` and `test/`; its own fixture suite does not certify a harness adapter |
| Release or distribution | `docs/RELEASE_WORKFLOW.md`; source checks below grant no upload/deployment/installation authority |

The `worker-*.ts` shorthand above refers to `packages/runtime/src/`. A descriptor in a map is not
proof that an implementation supports uniform memory. Preserve fail-closed selection and consult
the exact integration for availability and admission/rollback policy. Do not use an ambient SDK,
a live profile, or a native provider as an accidental test substitute.

## Commands and their limits

Run from your own checkout unless otherwise specified. Use the repository's declared Node/pnpm
versions; do not silently install or upgrade tools to make a command work. Begin with `git status
--short`, `git rev-parse HEAD`, and `git diff --check` so the tested source and working changes are
explicit. A signed commit and a green historical run do not establish current integration success.

- **Production staging fixtures:** `python3 scripts/test-stage-internal-alpha.py` validates the
  staging contract. It does not execute the complete runtime or establish app acceptance.
- **Inert harness adapters:** `node --test packages/harness-plugins/hermes/adapter.test.mjs packages/harness-plugins/openclaw/adapter.test.mjs`.
  Keep native/provider opt-ins disabled unless separately authorized; record optional skips.
- **Selected runtime checks:** first stage the exact intended source with
  `python3 scripts/stage-internal-alpha.py "$TASK_STAGE"`, where `TASK_STAGE` is a fresh task-owned
  directory. Run build/test commands **inside that staged source**, not against an undecorated raw
  `serve.ts`. Staging takes committed Git content: commit reviewed changes before treating the
  staging receipt as their test proof. Resolve dependencies and any required fixture binaries using
  the current gate's explicit steps; do not point tests at a production host binary.
- **Current bounded internal gate:** read `scripts/check-internal-alpha.sh`,
  `scripts/check-internal-host.py` and `scripts/check-internal-swift.py` before execution. When its
  source/dependency scope is authorized, `sh scripts/check-internal-alpha.sh` assembles the source,
  installs its locked dependencies and runs the selected host/runtime/adapter/Swift checks. It is
  more than a quick offline unit test. Preserve explicit receipts, skips and exact source identity.
  The current runtime selection includes `worker-` and the retained harness/person/registry tests;
  do not replace it with a guessed broad command as the gate evolves.
- **Individual native Swift check:** use `env -u SDKROOT swift test --package-path packages/shared-swift --filter '<reviewed-test-name>'`
  for an explicitly selected fixture. Do not mistake compiling the package for testing a device.
- **Legacy channel only:** `pnpm --filter @yorozu/openclaw-channel test` runs that package's fixtures.
  Discover its actual installed SDK location if a separately authorized load check is needed; never
  hardcode a Homebrew path or treat a successful ambient import as curated-runtime provenance.

There is deliberately no new root `pnpm check` alias. Recursive builds/all Vitest or all Swift tests
are not interchangeable with the bounded internal gate: legacy recovery/interposer/FIFO or live
acceptance suites require their own scope. SQL/pipe/encrypted-loopback fixtures establish local
implementation behavior, not live gateway/subscription, deployed relay, physical-device, or
production-readiness proof.

## Parallel work and lifecycle

Keep the full safeguards in `AGENTS.md`. A clean worktree can still belong to an active worker;
never switch, reset, clean, remove or rewrite it merely because a PR was pushed. Preserve unmerged
commits, index/working changes and nonignored untracked work before a deliberate closure/deletion.
Where current task authority requires detached work rather than a new permanent branch, follow
that bounded instruction without changing another worker's checkout. Archive references and an
explicit integration decision are not the same as merging source or shipping a feature.
