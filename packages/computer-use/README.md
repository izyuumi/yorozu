# Independent computer-use slice

Standalone Rust package based on signed alpha `1673b2e0a099ff4329292309b1b66af4430da9e3`.
It neither imports nor changes host-core or the paused migration. No app install, release,
storage migration, process-interposition fixture, live model inference, or live input is part
of the automated checks.

## Implemented

- Provider-neutral Serde batch/actions and goal/control/outcome types. Required task,
  parent, origin and attempt IDs preserve worker ancestry. Unknown fields/actions fail
  closed; custom-function adapters should use the 64 KiB `decode_batch` boundary.
- One bounded Tokio mailbox (8 pending batches) feeding one desktop thread. Actions
  execute in order; the first failure stops the batch, with indexed completed/rejected/
  unknown-effect/skipped results. Completion means OS dispatch acknowledgement, not
  proof that the app performed the intended task.
- Trusted-host grants bound IDs, PID/window/display, allowed actions, lifetime (at most
  120 seconds) and total action budget (at most 128 across batches). Models cannot
  deserialize or issue grants. Batches have at most 32 actions, 2 screenshots and a
  30-second deadline measured from submission, including queue time.
- Fresh random observation IDs belong to a task/attempt and expire after 10 seconds.
  Any desktop input consumes the observation. Pointer coordinates must be inside the
  observed image; transforms preserve negative display origins and image-to-logical
  scaling. Changed native window/display geometry rejects input before dispatch.
- Replay ledger retains 4,096 admitted batch IDs for the queue lifetime, then rejects
  new batches. It never evicts IDs to permit replay. A fresh attempt is not permission
  to repeat an uncertain action.
- Stop tokens and dropped result receivers stop undispatched work. Native OS calls
  cannot be forcibly interrupted safely: the owner waits for them to return before
  doing anything else. A dispatched error, panic, stop or late acknowledgement halts
  all subsequent input for that session. Observation remains available for review.
  No automatic recovery/replay API is supplied.
- `WorkerContext` keeps the dedicated worker's last 16 batch results and at most two
  images. Only its provider adapter receives that history. The secretary receives a
  bounded summary/status/evidence-ID outcome with the last compact batch receipt,
  never this image history. Steering
  replaces bounded context and does not expand a grant.
- Native macOS 14+ adapter: ScreenCaptureKit window screenshots via maintained
  `screencapturekit = 11.0.0`; input via `enigo = 0.6.1` behind our own `Desktop` trait;
  documented CoreGraphics window ordering and AppKit activation/foreground APIs.
  Both existing permission checks are required; Enigo permission prompts are disabled.
  One native adapter can be constructed per process for its lifetime.

The scope is one normal visible window contained entirely on one display. Capture omits
window shadows and limits each image dimension to 1,600 pixels. Move, left/right/middle
click, bounded two-axis scroll, plain Unicode text, balanced taps of a small key set,
app focus and bounded waits are supported. Text rejects control characters (including
newlines/tabs), since Enigo may turn them into key events; use a separately authorized
key action. No shell, AppleScript, arbitrary code, clipboard or held-key tool exists.

## Ordinary-model contract and synthetic integration

`model.rs` defines an asynchronous `OrdinaryModel` adapter contract and a bounded
`run_worker` loop. No provider SDK, HTTP client, credentials route or live inference is
included. The host owns the private `WorkerContext` separately from the secretary's
model context and retains its evidence after the loop returns.

Adapters receive exactly one generated custom function, `yorozu_desktop_batch`, plus
separate PNG image blocks and text-only receipts correlated by provider call ID. Schemars
derives the JSON schema from the existing action types. Model arguments contain only
action/deadline fields; the host stamps ancestry and batch identity and supplies the
immutable grant. Unknown fields, arbitrary/native tools, duplicate call IDs and oversized
arguments stop the worker. Adapters must normalize one call per reply and reject hosted
computer-use/parallel-tool responses instead of executing them.

Each run has at most 16 model turns, a 120-second total bound and a 30-second per-turn
bound. A stop token cancels pending provider futures; queue stops retain the executor's
unknown-effect rules. Provider failures/timeouts and desktop rejections return stuck with
no retries. Compact outcomes include last batch ID/statuses/input-halted state, without
raw action payloads, transforms or images. A done claim requires an observation after the
last input; its freshness is conservatively bounded from batch submission. It is still a
model claim requiring secretary review, not independent proof of real app acceptance.

The eight synthetic-provider tests use the real queue/context/loop with an inert desktop;
they cover image/receipt delivery, scope injection, unsupported/malformed calls,
completion gating, uncertain effects, duplicate calls, turn limits, deadlines and stops.
A concrete BYO ChatGPT transport adapter is still future integration; it should implement
this ordinary image/custom-function contract without advertising native hosted tools.

Package-only CI is `.github/workflows/computer-use.yml`: feature-branch pushes affecting
this package run formatting, Clippy, tests and example compilation on Linux/macOS/Windows.
It never invokes host-core, native helpers, provider calls, repository CI or releases.
There is no PR trigger in this independent slice.

## Run local checks

```sh
cargo +1.92.0 fmt --manifest-path packages/computer-use/Cargo.toml --check
cargo +1.92.0 clippy --locked --manifest-path packages/computer-use/Cargo.toml --all-targets -- -D warnings
cargo +1.92.0 test --locked --manifest-path packages/computer-use/Cargo.toml
cargo +1.92.0 build --locked --manifest-path packages/computer-use/Cargo.toml --all-targets
cargo +1.92.0 run --locked --manifest-path packages/computer-use/Cargo.toml --example permissions
```

Tests use an inert backend. They verify admission, serialization, queue deadlines,
stopping, replay rejection, per-grant budgets, freshness/coordinate bounds, unknown
input effects, English/Japanese payload delivery and private context retention. They
cannot verify actual capture pixels, foreground checks or native Unicode entry.

The ScreenCaptureKit dependencies compile Swift bridges. Build with Xcode tools;
SwiftPM needs its normal compiler sandbox and writable compiler caches. `build.rs`
adds the standard system Swift runtime rpath for the resulting Mac executables.

## Coordinated TextEdit fixture (deferred, not yet run)

Exact helper/app identity and future permission scope are documented separately in
[NATIVE_APPROVAL.md](NATIVE_APPROVAL.md). No approval is requested now.

The permission-only probe on this Mac mini returned `screen_recording=false` and
`accessibility=false`. No TCC prompt, permission grant, app launch or input was attempted.

Before a live run, coordinate with the parent/user: Screen Recording and Accessibility
must already be approved for the actual executing binary/responsible process. Open only
this task's `fixtures/Yorozu Computer Use Fixture.txt` in TextEdit, keep its exact title,
place the caret on its blank line and foreground that document. No other actor should
use the desktop during the run. The fixture must fit inside one display. The example
requires an explicit coordination flag, verifies TextEdit bundle/title, grants only
screenshot/text/wait, and runs fixed English/Japanese text:

```sh
cargo run --locked --manifest-path packages/computer-use/Cargo.toml \
  --example textedit_fixture -- --coordinated
```

The example leaves the document unsaved and open. It does not launch, focus, save,
close or delete anything. It writes before/after PNGs only under this package's ignored
`target/textedit-fixture/<attempt-id>/`. Inspect the after image to verify the text
`Hello Yorozu — こんにちは、よろず`; dispatch acknowledgement alone is insufficient.
It returns `stuck` pending visual verification, and is not a live model agent.

## Native and integration limits

Enigo is event synthesis; delivery is asynchronous and does not confirm app acceptance.
Unicode/IME behavior, Retina scaling, window clipping, foreground changes and AppKit
activation need native fixture evidence. Geometry/foreground preflight is best effort:
OS focus can still change between checking and dispatch. The dedicated-desktop premise
is required. Focus activates the PID, not a particular document; input still rejects
unless the exact authorized window is foreground. Windows spanning displays and
arbitrary keyboard chords are deliberately unsupported in this slice.

The process-local replay ledger and native singleton do not survive restarts or exclude
other processes. The host must ensure one desktop owner across processes and reconcile
uncertain effects before starting any new session. This package does not implement a
durable recursive scheduler or a concrete live-provider adapter. The hierarchy/control
types are its contract only;
Queue/Steer/Stop must be routed by that scheduler, with the StopToken used for stops.

A BYO ChatGPT adapter should provide images and custom functions to an ordinary model;
it must not advertise a native hosted computer-use tool. Keep provider adapters outside
this package. Jev and Playwright are deferred.

Finite remaining integration work:

1. Coordinate existing native permissions and the isolated foreground TextEdit fixture;
   record English/Japanese, capture and display-transform evidence.
2. Implement an authorized BYO ChatGPT transport adapter for the tested ordinary-model
   contract and connect host grant admission; no live/paid calls until authorized.
3. Wire durable recursive task/parent/origin/attempt records and steering/queue/stop
   routing into an approved scheduler, including restart reconciliation and a single
   desktop owner across processes. Do not overlap paused host-core files now.
4. Coordinate alpha app/scheduler integration and broader CI after scope review. The
   separate package CI is implemented. Existing repository PR CI runs host-core recovery
   tests, so this work remains on the feature branch without opening a PR.

## Dependencies and licenses

Dependency versions/checksums are retained in the standalone Cargo.lock. This package
uses the repository MIT license. Enigo is MIT; ScreenCaptureKit, its apple-cf/apple-metal
bridges, CoreGraphics/CoreFoundation and PNG are MIT OR Apache-2.0; objc2/AppKit is
MIT OR Apache-2.0 OR Zlib. Tokio, Serde/serde_json, Schemars and UUID use permissive upstream
licenses recorded in their Cargo manifests. No upstream source was copied into the
module. Preserve upstream notices/license texts when packaging dependencies for release.

Primary API references: [ScreenCaptureKit bindings](https://docs.rs/screencapturekit/11.0.0/),
[Enigo settings](https://docs.rs/enigo/0.6.1/enigo/struct.Settings.html),
[Enigo permission behavior](https://github.com/enigo-rs/enigo/blob/main/Permissions.md).
