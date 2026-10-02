# First slice validation — 2026-10-02

Environment: Yumis-Mac-mini, arm64 macOS; Rust 1.92.0; Xcode 27.0 (27A266a).
Remote `v0.6.0-alpha` verified at
`1673b2e0a099ff4329292309b1b66af4430da9e3`, with a good ED25519 Git signature.
Feature branch: `computer-use-alpha`.

## Proof actually run

All commands below target only `packages/computer-use/Cargo.toml`:

- `cargo fmt --check`: passed.
- `cargo clippy --offline --locked --all-targets -- -D warnings`: passed.
- `cargo test --offline --locked`: 12 integration tests passed, zero failed.
- `cargo build --offline --locked --all-targets`: passed, including macOS adapter,
  permission probe and the opt-in TextEdit fixture executable.
- `cargo run --offline --locked --example permissions`: ran only permission queries;
  `screen_recording=false, accessibility=false`.
- `git diff --check`: passed.

Cargo dependency downloads and the initial Swift bridge compile passed ordinary
approval review. SwiftPM's compiler sandbox required a build-only escalation after
nested compiler sandbox/cache failures. No live desktop actions were included in it.
Later package tests/builds ran within the workspace sandbox using those compiled bridges.
No normal review denied this independent scope.

## Tests and independent contracts

The inert `Desktop` fixture records dispatch and can delay/deny preflight or lose
acknowledgement. It never operates the real desktop. Tests exercise the public queue,
wire decoder, transform and private worker-context APIs, with no test-only production
seams:

1. Wire rejects code actions, unknown fields, arbitrary keycodes and oversized JSON.
2. Coordinates respect negative origins, image scaling, fractional rounding and bounds.
3. English/Japanese payloads reach the adapter once using fresh observations.
4. Identity, authorization, text/control-character and deadline bounds reject before dispatch.
5. Batch replay and total grant budgets span multiple submissions.
6. Foreign observation IDs/out-of-image clicks reject; subsequent actions are skipped.
7. Preflight denial stops before effect without halting the input session.
8. Lost input acknowledgement becomes unknown-effect and halts later input; capture remains available.
9. A blocked native call prevents concurrent execution; queued deadlines and in-flight stop are enforced.
10. Stopped workers and expired grants cannot start.
11. Worker context retains 16 results/two images; secretary outcome contains only evidence IDs and summary.
12. Observation expiry during delayed native preflight rejects immediately before input.

Three meaningful defects were demonstrated and repaired during implementation: internally
tagged Serde unit variants accepted extra fields despite `deny_unknown_fields`, and a
slow preflight could outlive the observation TTL. The retention check also caught
cleared image vectors retaining their backing allocation; eviction now releases the
buffers. The wire/preflight/retention regression tests failed for those intended reasons
before their fixes and pass afterward.

## Unverified and next scope

Native screen pixels, input delivery, TextEdit Unicode/IME behavior and actual display
transforms are not verified. The compiled TextEdit example was not run. No app was
launched or altered; no OS permission/security/network setting was changed. There was
no live or paid model inference, no purchase/send/delete, no Yorozu install/release,
and no execution or retest of host-core or the paused migration fixture.

Parent coordination needed for the native fixture: authorize/arrange existing Screen
Recording and Accessibility access for the executing process, foreground only the
fresh task-owned `Yorozu Computer Use Fixture.txt` TextEdit document with caret on its
blank line, and keep the desktop idle during fixed text entry and before/after capture.
The executable never grants permissions. Scope is that document only, fixed
`Hello Yorozu — こんにちは、よろず`, and task-local PNG evidence; no save/close.

This is a compiled standalone executor and worker contract/context, not a verified
end-to-end model agent or durable hierarchy. The four finite follow-ups in README cover
native proof, model adapter, approved durable scheduler/control integration and package
CI/alpha integration. A draft PR is intentionally deferred: existing PR CI automatically
runs host-core recovery tests outside this task's boundary. Only the isolated feature
branch is to be pushed, leaving main/alpha and the paused checkout untouched.
