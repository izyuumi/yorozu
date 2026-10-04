# Assembled harness host proof

`scripts/harness-host-proof.mjs` exercises the assembled production `serveSecretary`
entry through `local.sock`. The pinned Hermes TUI gateway owns its model/tool loop,
delegation, child execution and result continuation. A loopback Responses provider
supplies deterministic function calls and text; it does not emulate the gateway or
move orchestration into Yorozu.

Every run requires a new output directory. The fixture sets explicit state, memory,
project, plugin-profile and provider paths. Its host subprocess receives a small
environment without ambient credentials. Ordinary Codex execution is replaced with
a runner that refuses execution; no Claude/Codex process is launched. No installed
profile, account, subscription, scheduler, persistent permission or release is used.

```sh
node scripts/harness-host-proof.mjs \
  --candidate /absolute/path/to/assembled-candidate \
  --source /absolute/path/to/pinned-hermes \
  --python /absolute/path/to/task-python \
  --host-core /absolute/path/to/yorozu-host-core \
  --output /absolute/path/to/new-proof-directory
```

Use the task's Node 26 executable. `--candidate` must contain built
`packages/runtime/dist`, the Hermes adapter and `internal-source.json` declaring
Hermes 0.21.5. The adapter verifies source commit
`f97608f178d1ffeca59860195ab7da295f7c8e5f`. `--host-core` supplies the existing
lease helper when the candidate has not yet bundled that binary; it is not a new
backend requirement. Loopback and Unix socket binding must have execution approval
when the managed sandbox disallows them. Stop if approval is rejected.

## Default acceptance checks

The fixture checks these observable behaviors:

- The main user event is on disk before the first inference request.
- Real Hermes writes and reads a harmless artifact, then returns its final reply.
- An input admitted behind that turn is withdrawn through the native queue. It
  never enters bootstrap context or inference.
- Real delegated children become visible task subthreads in the common event
  contract. An A correction returns `queued` while A remains running; A's later
  file contains the correction. The correction is absent from B's inference.
- An exact B Stop returns `requested`, then the actual child reaches `stopped`
  without producing its artifact. It does not become a generic native-runner Stop.
- The main conversation responds while A runs. Hermes initiates its result
  continuation after the child finishes.
- A real upstream approval reaches the native approval-card path. A refusal
  leaves the fixture file unchanged.
- Seeded ordinary history and settings remain unchanged. Old main and ordinary
  native session metadata remain intact. Japanese context and final reply bytes
  survive the plugin route.
- A process-group crash occurs after a once-only append. On restart the host
  ledger reports `unknown`, admits no new inference, and refuses a fresh input
  while the previous outcome is unconfirmed. The append remains exactly once.

`evidence.json` records candidate/base SHAs, assertions, local inference metadata
and local-socket events. Harmless artifact files and bounded host stderr remain in
the new output directory. Requests omit a priority/fast/ultrafast tier; all
inference is synthetic loopback inference.

The successful development run used candidate source
`9a49c5234698f513aa2d6afdbfd16a8e90fd638c`, production baseline
`5be369c8d50833a626c8c0ca3e8fc262c150e8de` and 18 loopback requests. Evidence is
retained in the task workspace at `host-proof-evidence-2/evidence.json`.

## Native UI provider mode

`--ui-provider-only` prepares a new fixture profile and a generated
`launch-fixture-host.mjs`, prints its paths and keeps only the loopback provider
alive. It does **not** start the host. The native app must own that host through
`YOROZU_RUNTIME_CMD`; sharing an existing host would conflict with the app's
socket cleanup and lease ownership. The generated wrapper imports the same
assembled entry, seeds only fictional history, refuses ordinary native execution,
and handles the app's `MINT` input.

The app owner must separately isolate native preferences, cache, log and Keychain
namespaces. This script does not authorize access to installed native state. The
provider recognizes these scripted, harmless prompts:

1. `Please create and verify a harmless note.`
2. `Please create two harmless notes using two independent specialists.`
3. `Can we keep talking while specialists work?`

The scripted task-A correction is
`YOROZU_HOST_STEER_A_ONLY: write A: steered instead of A: original.` Child tools
wait 20 seconds in UI-provider mode to allow native control inspection. Close
stdin or signal the provider to finish and retain evidence. Native UI observation
and acceptance belong to the UI owner, not this provider fixture.

Provider-only mode was syntax-checked but **not executed**: automatic approval
review rejected its process launch, generated-launcher writes and provider
keepalive, citing the earlier read-only instruction. No retry through another
route was attempted. A supported approval is required before running that mode.

`--interactive` instead runs the regular host proof through the preservation
phase and keeps its host/provider alive until stdin closes. It explicitly skips
crash/restart checks and is unsuitable for an app that needs to launch its own
host.

## Limits

This is production host/runtime proof with synthetic inference, not live
subscription authentication or native SwiftUI/iOS acceptance. Language coverage
means seeded history/settings and reply bytes; it does not establish live native
preference synchronization. Isolating a runtime profile does not establish an OS
sandbox. Tools are hardcoded harmless operations under the new workspace. The
fixture does not install a plugin, alter an installed app, grant permission,
publish or release anything.
