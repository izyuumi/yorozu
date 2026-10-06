# Second real uniform-memory adapter: bounded feasibility result

As inspected 2026-10-06, base `b4748d07d6764220188d95e491a67b33c640981c`.
Work performed in detached worktree `/Users/yumi/Projects/yorozu-wt/openclaw-memory-20261006`; no new branch, production OpenClaw change, Hermes change, install, account access, provider call, or external publication.

## Result: blocked on a usable native runtime input; capability remains disabled

Do not register OpenClaw as `worker-memory-v1` yet. The existing adapter is a real Gateway transport design, but is not a working uniform-memory adapter. Its current curated input is source-only, and the adapter deliberately rejects every nonempty tool scope. No native OpenClaw Gateway was executed in this investigation. This is not evidence that OpenClaw fundamentally cannot support the design.

### Directly checked input

The retained task-local source is:

`/Users/yumi/Documents/Codex/2026-10-04/task-5/harness-openclaw-adapter/tmp/upstream-openclaw`

- HEAD is exactly `9bbdbaec153dd28fb452e6652c3dcacd829cb00f`; tracked worktree is clean.
- `node_modules` exists, but `dist` does not. In particular the required `dist/yorozu-gateway-embedding.js`, `dist/entry.js`, and `dist/build-info.json` cannot be supplied to the current validator.
- The adjacent `tmp/build-review-blocker.json` records that the earlier build stopped before `plugins:assets:build`: pnpm 12.5.1's registry signature fetch was unavailable. It also records rejected earlier authorization reviews. Those historical decisions are evidence, not fresh instructions or a claim that this request forbids all local compilation.
- The existing build route is therefore not a demonstrated offline/no-install route. This assignment expressly excludes installation. I did not retry that network/dependency bootstrap, bypass it by changing package-manager security, or mutate the shared retained source.
- The unrelated older evaluation checkout is not the required source identity and was not substituted. Production package/profile/credentials were not used.

## Required implementation after input readiness

This is more than adding an adapter ID to the registry:

1. `packaged-agent-runtime.ts` has only a verified Hermes resource loader; there is no OpenClaw sealed package input or verifier. `curated-agent-runtime.ts` requires the exact built curated OpenClaw tree and rejects every nonempty OpenClaw tool scope before selecting a broker. Keep both fail-closed until the replacement path has proof.
2. `openclaw/adapter.mjs` does not accept `workerMemory` in its strict initialization fields, implement child-to-host worker tool requests, or bind host work currency to native plugin calls. Merely allowing the flag or advertising the capability would be false.
3. The pinned source does expose a potentially suitable native plugin tool factory: `src/plugins/tool-types.ts` has agent/session identity, runtime-only `toolBindings`, and version-2 `assertInvocationCurrent`. That is a promising supported seam, not proof that Gateway `chat.send` carries the necessary Yorozu execution identity through it. Establish the full trusted mapping; never take execution currency from model arguments or infer it from an arbitrary latest turn.
4. The current managed configuration intentionally preserves native memory/settings, including previous plugin configuration; global `deny: ['*']` is not native-memory shutdown. Uniform mode must suppress the actual native memory slot/search, compaction memory flush, bootstrap/context memory ingestion and any retained native-memory hooks without erasing historical native files. Validate actual pinned schema and behavior; do not equate missing tools with disabled memory.
5. Keep the existing account/model broker selection, exact scope and admission checks, invocation cancellation, exact-approval share/revoke protocol, durable terminal receipts and migration custody. Register only the narrowly proved mode; no connected Gateway fallback.

## Smallest next choices for the integration owner

- **Remain blocked honestly:** integrate the independently owned Hermes work, leave OpenClaw unavailable, and report that mixed-harness memory acceptance is unmet.
- **Supply an explicit prepared input:** provide a reviewed, intact, built tree at the current curated pin (including all required dist metadata and dependencies) plus an explicit trusted startup selection; then implement the native plugin bridge and run the existing confined native fixture before uniform-memory acceptance. No production installation is needed.
- **Authorize separate runtime preparation if no such input exists:** separately scope dependency/package-manager acquisition and an isolated detached build, without production edits or ambient credentials. Review any source/patch repin and packaging inventory separately. Do not silently change the current pin or turn an arbitrary local checkout into a release input.

A shipping second adapter additionally needs a sealed OpenClaw runtime artifact, reviewed inventory/provenance, adapter/plugin bytes, and explicit host resource selection. There is currently no OpenClaw equivalent of the packaged Hermes input. No runtime input or model/account choice was changed here.

## Acceptance evidence

`/Users/yumi/.local/share/mise/installs/node/26.10.0/bin/node --test packages/harness-plugins/openclaw/adapter.test.mjs`

Result: **37 passed, zero failed, zero skipped**. These unchanged tests use fake Gateway/socket contracts and inert filesystem/descriptor fixtures. They do **not** establish native Gateway execution, native memory suppression, mixed-harness sharing, live subscription access or device acceptance. The same suite also passed with ambient Node 25.9.0, but only the explicit Node 26.10.0 result is relevant to the curated host pin.

`git diff --check` passed before this report. No runtime capability was enabled and no source-code behavior was changed.
