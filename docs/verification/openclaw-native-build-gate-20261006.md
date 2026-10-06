# OpenClaw second adapter: actual offline build, native gate still closed

## Current result

The earlier source-only/no-build blocker in `openclaw-uniform-memory-feasibility-20261006.md` is **resolved**. The continuation clarified that ordinary isolated development dependency/build preparation was authorized. A supported entirely offline build worked without installing anything, fetching dependencies, changing package-manager security or touching the retained shared checkout.

A real confined native Gateway now starts and passes kernel, handshake, local signed-device pairing, session creation, subscription/history identity and clean-shutdown checks. **Inference and uniform memory are not accepted or enabled.** The next request reaches an actual protected API boundary:

`chat.send` → `INVALID_REQUEST: system provenance fields require admin scope`

The adapter deliberately preserves `suppressCommandInterpretation: true`, exact idempotency, followup/branch CAS and read/write-only operator scopes. It does not remove this safety field, request admin, impersonate a principal, replay the uncertain send, or substitute a production Gateway.

## Why this is now a bounded design/security gate

At native pin `9bbdbaec153dd28fb452e6652c3dcacd829cb00f`, `src/gateway/server-methods/chat-send-request.ts:147–161` requires admin/trusted-system authority for command suppression. The current generic backend embedding has only `operator.read` and `operator.write`. A token alone also cannot create an idempotent native session; that separate problem was resolved using a generated isolated Ed25519 device and the Gateway's own signed challenge/pairing policy, with **no scope expansion** and no external account.

Setting `commands.text=false` is not an equivalent safety mechanism. `src/auto-reply/commands-text-routing.ts:16–23` still enables text commands on non-native-command surfaces. Removing suppression on this route would change the action authority of user text. A fake Gateway had previously accepted these incompatible requests and therefore hid these failures.

Smallest remaining choices for the integration owner:

1. Keep this adapter unavailable; accept the native prerequisite fixes independently, but report the second-real-harness requirement unmet.
2. Review a narrowly specified upstream/curated non-admin literal-text embedding API (or another already supported route that demonstrably preserves the same authority), with a new source/patch pin and native tests if necessary.
3. Explicitly review whether an isolated admin-capable embedding principal is acceptable. This is a materially broader trust design, **not** ordinary dependency setup; it was not selected or implemented here.

Even after that gate, actual native inference/stop/restart receipts must pass before implementing/enabling the uniform-memory bridge, native memory suppression, exact native tool-to-host execution binding, host approval/cancellation transport, and sealed shipping runtime input. No promise is made that changing one scope completes those gates.

## Build evidence and inputs

Private task root: `/private/tmp/yorozu-openclaw-memory-20261006`.

- Independent `git clone --no-hardlinks --no-checkout` from the retained source; detached checkout at the exact curated pin; removed the clone's remote.
- APFS copy-on-write copies of prepared `node_modules` and workspace package dependency directories. No hardlink sharing, credential/config/profile import, new dependency resolution or global package-manager mutation.
- Existing pinned dependency closure was reused; original download archive/signature provenance was **not independently re-audited**. This is a development build input, not a sealed release artifact.
- Fresh HOME/TMP/cache, explicit Node 26.10.0 and sanitized environment.
- Actual command ran inside `/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)'`:

  `node --import ./scripts/tsx.mjs scripts/build-all.mts sourcePerformance`

  with `OPENCLAW_BUILD_ALL_NO_PNPM=1` and `OPENCLAW_TSDOWN_MAX_OLD_SPACE_MB=4096`.
- The pinned `scripts/build-all.mts:444–450` explicitly supports this Node fallback. It bypasses no signature/TLS/integrity check: it does not launch package-manager version acquisition at all.
- Exit **0**, native build phases **40.2 seconds**, `dist/yorozu-gateway-embedding.js` exists, `dist/build-info.json` identifies the exact curated pin and version 2026.9.8. Source tracked tree remains clean. `build-offline.log` retains the native compiler output.

## Source changes

Signed, detached, separately reviewable prerequisite commits:

- `9ca9441`: runtime policy permits only the null sink's write-data and signals to the process's own children. Real kernel tests confirm the parent/foreign-process signal boundary and peer filesystem boundary still deny access. This tiny shared runtime prerequisite is isolated for parent review because the requested ownership was otherwise OpenClaw plugin/runtime capability work.
- `53a867b`: OpenClaw adapter/native test alignment. Optional explicit developer Git verifier with owned TMPDIR; private persisted Ed25519 identity signed over the actual challenge/token/client/platform/read-write scopes; native pairing policy left authoritative; issued device tokens are not retained; strict native subscription response identity; supported `chat.history` request with exact returned session-id validation. Connected mode remains held. No uniform-memory capability or tool is advertised.

The native proof accepts optional `--git` and `--git-read-roots` for explicit read-only verifier code. Apple's Git shim tried to access Xcode metadata and writable cache beyond the sandbox; the successful proof instead selected the existing Homebrew Git 2.52.0 executable and the realpath-resolved pcre2/libiconv/gettext library directories. No Xcode license was accepted or modified. A sealed shipping input must eliminate reliance on this developer-only verifier closure.

## Acceptance accounting

- Node 26.10.0 adapter contract tests: **40 passed, zero failed/skipped**. They remain **fixtures**, including signed-device cryptographic and fail-closed admin-denial regressions.
- Focused exact-stage runtime tests: **29 passed, 1 optional skip**, across curated factory, packaged platform, worker registry and agent isolation. Shared/runtime TypeScript compilation passed. An initial packaged-platform test failed because its Rust helper had not been supplied; after an exact-source `cargo build --offline --locked` with copied registry cache, sanitized environment and network denied (23.93 seconds), the complete focused rerun passed. The prior failure is retained in `runtime-final.log`, and the passing result is `runtime-final-with-helper.log`.
- Actual kernel tests (included in that runtime count): **7 passed**, including null sink, owned-child SIGTERM, foreign-parent signal-0 denial, sibling file/memory denial, inherited subprocess denial and network confinement.
- Native proof overall: **failed**, by design retaining the real gate; it must not be counted as an accepted second harness.
- Verified real native sub-results: Gateway readiness; native-policy signed-device pairing; session creation; exact subscription/history identity; clean native shutdown. **Provider request count: 0.** No inference, memory-tool execution, mixed-harness sharing, subscription account or physical-device acceptance.
- Native memory is **not suppressed** in this prototype. Actual synthetic-profile startup loaded `memory-core` despite `tools.deny=['*']`; no uniform-memory registration was made. This confirms why merely disabling tools is insufficient.

Exact native command (fresh output directory required):

```sh
N=/Users/yumi/.local/share/mise/installs/node/26.10.0/bin/node
"$N" packages/harness-plugins/openclaw/native-proof.mjs \
  --source /private/tmp/yorozu-openclaw-memory-20261006/source \
  --node "$N" \
  --host-runtime /private/tmp/yorozu-openclaw-memory-20261006/exact-stage/packages/runtime/dist \
  --git /opt/homebrew/Cellar/git/2.52.0_1/bin/git \
  --git-read-roots '["/opt/homebrew/opt/pcre2/lib","/opt/homebrew/opt/libiconv/lib","/opt/homebrew/opt/gettext/lib"]' \
  --output /private/tmp/yorozu-openclaw-memory-20261006/native-exact-final
```

The proof-only wrapper observes rejected native RPCs and fictional history identity summaries; it does not replace the native loop or alter RPC/results. Raw runtime profiles (which contain task-generated local credentials) are not release/evidence inputs and must not be uploaded or copied into PAIOS. The checked-in JSON receipt contains only bounded results, source hashes and evidence locations.

No Hermes files, packaged capability registry, broker account/model selection, canonical branch refs, production OpenClaw, user data, provider account, installation, publication or release were changed.
