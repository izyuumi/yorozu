# Internal Mac alpha QA

QA owns `scripts/alpha-*` and this report. Integration owns the Rust alpha host,
Node alpha worker and IPC contract. UI owns the standalone `YorozuAlpha` product.
Base: signed `1673b2e0a099ff4329292309b1b66af4430da9e3` on `v0.6.0-alpha`.
No main merge, release upload, beta feed, TestFlight, installation or profile migration.

## Read-only findings

- Installed official `codex-cli 0.157.0`: `codex login status` reports ChatGPT login.
  Authentication was checked through the official client; auth files/tokens were not read
  or copied. The sealed `ec1a0e3` bundle subsequently passed real `gpt-6-sol`
  English/Japanese file tasks, Stop and reconnect; this does not prove Astra runtime access.
- [Official app-server protocol](https://developers.openai.com/codex/app-server) and
  [authentication](https://developers.openai.com/codex/auth) support the existing official
  client route. The bridge must use `codexNativeRunner`; no new provider SDK or login.
- Installed `/Applications/Yorozu.app` identity: `to.yumi.yorozu`, team `AN5KM8QGEF`.
  Existing native helper queried with `permission.status` only: Accessibility false,
  Screen Recording false **in this execution context**. This does not identify the
  responsible TCC entry or prove permissions for another launch route. No prompt or grant.
- Helper branch `mac-helper-integration` includes ScreenCaptureKit/Enigo and typed Swift
  pipe; its Responses adapter requires an explicit API key. It cannot consume the
  ChatGPT login directly. Host admission, evidence retention and stable TCC identity are
  documented gaps. Synthetic helper checks are not native proof.
- Shipping `build-mac.sh` defaults to production identity/feed and automatic updates;
  it is unsuitable for this internal alpha. Legacy `dev-bundle.sh` starts the existing
  app target. The new standalone product avoids legacy startup and Sparkle.
- Installed Yorozu profile includes keys, devices, gateway configuration and history.
  It is not copied into the demo. Alpha's explicit temporary profile does not establish
  upgrade/migration compatibility. Original-profile migration remains a replacement gate.

## Build and package

Build only the owned binaries/products, never a test aggregate containing the paused
recovery/fault-injection work. Compile shared TypeScript, then runtime with `pnpm exec
tsc -p packages/runtime` directly; do not use its `build` script wrapper.
Build `yorozu-alpha-host` with Cargo `--bin yorozu-alpha-host` and the Swift shell with:

```sh
swift build --package-path apps/mac --product YorozuAlpha
```

Stage a production runtime dependency tree with pnpm's lockfile-derived deploy
in a fresh staging directory (`--config.inject-workspace-packages=true
--filter @yorozu/runtime --prod --config.node-linker=hoisted deploy ...`). This
CLI option applies only to staging; no workspace configuration change is required.
The old `--legacy` route re-resolves dependency ranges and was observed to drift
the Anthropic SDK from locked 0.3.278 to 0.3.286; do not use it for this candidate.
The packaging script accepts the locked tree,
built UI/host binaries, a relocatable Node binary and the Swift shared resource bundle:

```sh
python3 scripts/alpha-package.py \
  --ui /absolute/build/YorozuAlpha --host /absolute/build/yorozu-alpha-host \
  --node /absolute/relocatable/node --runtime /absolute/staged/runtime \
  --shared-resources /absolute/build/YorozuShared_YorozuShared.bundle \
  --source-sha EXACT_INTEGRATED_SHA --output /tmp/fresh/YorozuAlpha.app
```

Default signing is ad-hoc, internal only. `--identity` may select the existing Developer
ID for an authorized signing run. Signature verification is mandatory in either mode.
Output is confined to this checkout or the OS temporary directory. Copied staging
xattrs are cleared before signing, because File Provider can add Finder detritus.
No notarization, upload or installation occurs. The adjacent manifest hashes sealed
files and identifies the source and original input binaries. No updater/feed or URL
scheme is added. The app retains its separate bundle ID `to.yumi.yorozu.alpha.internal`.

Launch exact bundle path, never `open -a Yorozu`. Environment overrides are
`YOROZU_ALPHA_PROFILE/HOST/NODE/WORKER`; flags are
`-alphaProfile/-alphaHost/-alphaNode/-alphaWorker`. Profile must be a new OS temporary
subdirectory, or a host-marked alpha directory. Defaults use the bundled binaries and
an isolated temporary profile. Draft cache is under that profile's `state/` directory.

## Acceptance and test value

The smoke script protects real IPC, provider, persistence and stop boundaries. Credible
failures include UTF-8 loss, fake completion, replayed work, premature Stop acknowledgement,
and reconnection dropping accepted events. Existing synthetic helper tests cannot prove
these boundaries. It uses the real process interface and needs no production test seam.

```sh
python3 scripts/alpha-smoke.py --live \
  --host /absolute/yorozu-alpha-host --node /absolute/node \
  --worker /absolute/runtime/dist/alpha-worker.js \
  --evidence /absolute/fresh/alpha-smoke.json
```

This invokes the already-authenticated official client in a newly allocated temporary
workspace. It checks separate English/Japanese prompts, exact file bytes and independently
computed SHA-256 in each final result, same-run replay, durable Stop intent versus observed
cessation, and terminal event retention after a fresh host process reconnects. Every turn
is bounded by a timeout; stderr is not captured because provider diagnostics may contain
private configuration. Failure retains the fixture/evidence and exits nonzero.

UI acceptance additionally requires entering English/Japanese in the native composer,
visible truthful progress, draft preservation, Stop status and reconnect. CLI smoke alone
does not establish UI or native computer-use acceptance. Native TextEdit capture/input is
blocked until the actual helper identity and existing grants are verified; do not request
blanket permissions, substitute another identity, or claim screenshots as helper proof.

## Replacement gate

Keep the current installed bundle/profile intact. Before parent authorizes replacement:
retain a tested app rollback copy, separately approved connection/history backup, prove
compatibility against a copied profile with supported migration interfaces, and verify
the exact candidate. Current alpha deliberately refuses installed-profile paths and is
not an upgrade candidate. No old recovery/SQLite fault-injection test may be resumed.

## Latest bounded checkpoint

The signed `ec1a0e3e12d7551115d34e624c0b28adf78de85b` bundle passed real
English/Japanese file bytes and independently computed SHA-256, same-run replay,
durable Stop with process-exit evidence, and reconnect retaining terminal events.
Its source CI passed. Archive extraction preserved all 6,390 sealed file hashes
and passed `codesign --verify --deep --strict`. See `alpha-qa-results.json` for
exact local artifact paths and hashes; the tested runtime model is `gpt-6-sol`.

This is runtime evidence, not final native acceptance. The native app automation
call stalled and ended with `Transport closed`. The UI lane has not released its
files or supplied the Finder PATH, actual-model label, and neutral pending-Stop
wording follow-up. The candidate remains internal and the PR remains draft.
Installed application hashes match the earlier baseline; no old-profile
migration or installed-app replacement was performed.

Keep the archive in the workspace and extract the app into a fresh OS temporary
directory: File Provider adds Finder metadata to raw app copies in Documents,
which makes strict signature verification fail without changing sealed file bytes.
The adjacent `READ-ME.txt` gives an explicit existing-client PATH launch command
for manual development testing and states the unresolved UI gates.
