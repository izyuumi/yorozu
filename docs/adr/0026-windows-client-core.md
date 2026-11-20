# 0026. Windows client core: keys, state machines and trust boundaries

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

The Windows client is a Tauri app over a platform-neutral Rust core (`apps/windows/core`). The core holds the relay wire, pairing and connection machines; the web view only draws. Its spec sections are cited by number below.

## Decision

- Key isolation:
  - The driver executes machine effects; all socket, timer and cryptographic state stays in it, and keys stay out of the UI.
  - The core owns the state; the web view renders a `Snapshot` (spec section 3).
  - The distributed client stores keys with Windows DPAPI. Other targets compile only for shell checks (`UnsupportedProtector`).
  - The test-only plaintext key store (`PlainProtector`) sits behind the `insecure-plaintext-store` feature, which stays off in the app.
  - Saving is best effort, but a failed write must not leave the keys behind in the temp file.
- Memory-only state: chat rows, the outbox and read cursors live in memory only. Frame signatures belong to one session. The last notice is kept in the snapshot so one sent before the web view listens isn't lost; `seq` tells a new notice from the one before.
- Connection machine:
  - Flow ack (C0) precedes all payload handling, including foreign and malformed frames. The driver acks at the relay layer before decoding or touching handshake or session state.
  - On a new pairing, socket and timer generations carry over, so events queued by the old pairing stay stale. A timer from an earlier backoff is stale in a later one: only its generation stops C1.
  - Backoff (7.4): the attempt never resets at joined, only after 10 s Open.
  - The state/event grid test uses 0 for an explicit default; each nonzero cell names the spec row, not implementation output.
- Outbox retry: a retried failed row moves to a new id, so a second Retry on the old id finds nothing. The driver's diff removes the old item before adding the new one.
- Read cursors: pending cursors in a pure machine; acknowledgements are cumulative by conversation. `reset` forgets the pairing's cursors and session; the window's focus outlives a pairing.
- History sync: a pure single-flight machine with the open-conversation model.
  - When the newest page arrives, queued requests are dropped: their `before` was computed from items this page replaces.
  - After `run_started` it refetches: a page already in flight may predate the run.
  - `ConvList::raw` counts the rows the answer carried before invalid ones were dropped; the 2,000-row cap counts these.
- Pairing link validation: malformed percent escapes are rejected rather than read as literal input. The store reuses pairing-link validation at the disk trust boundary. The token is dropped at the first joined and the secret at Open, so a placeholder stands in for whichever is absent.

## Consequences

- The web view cannot reach keys or sockets even if compromised.
- The machines are pure and tested against the spec's rows.

## Where in the code

- `apps/windows/core/src/lib.rs` — crate
- `apps/windows/core/src/driver.rs` — `Driver`, new pairing, `frame` handling, outbox diff
- `apps/windows/core/src/snapshot.rs` — `Snapshot`, `Notice`
- `apps/windows/core/src/store.rs` — `Store::save`, `Pairing` validity check
- `apps/windows/core/Cargo.toml` — `insecure-plaintext-store`
- `apps/windows/app/src-tauri/src/lib.rs` — `UnsupportedProtector`
- `apps/windows/core/src/model.rs` — `Conversation`, `Item`
- `apps/windows/core/src/outbox.rs` — `outbox::Machine`, `Event::Retry`
- `apps/windows/core/src/connection.rs` — `connection::step`
- `apps/windows/core/src/reads.rs` — `reads::Machine`, `Machine::reset`
- `apps/windows/core/src/sync.rs` — `sync::Machine`
- `apps/windows/core/src/events.rs` — `ConvList::raw`
- `apps/windows/core/src/link.rs` — `Link::parse`
- `apps/windows/core/tests/machines.rs`, `apps/windows/core/tests/vectors.rs`
