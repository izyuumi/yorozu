# 0009. Live Activity pushes from the host

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

While the app is suspended, only the host knows a turn moved on. The plugin keeps each device's Live Activity, computes counts-only states, and asks the relay to push them to APNs. Restarts, token rotation and racing reports must never replay a dead token or lose a row.

## Decision

- Wire (`live_activity`, client → plugin, capability `liveActivityPush`): `pushToken` (hex) is the activity's ActivityKit token, absent once the activity ended. `jobs` is the whole content state with times in epoch milliseconds. `turns` maps each running turn job's token to its conversation, so the plugin can count the turn's steps and end it while the app is suspended. With `activityId` but no `pushToken` the report is pending; a legacy report without `pushToken` means ended.
- Content (`liveactivity.ts`, the pure part, no runtime imports so `node --test` runs it as is):
  - The plugin changes only the turn jobs it can map to a conversation and passes every other job (recording, transcribing) unchanged.
  - `cleanJobs` keeps only known fields, so nothing else reaches the relay; a job of an unknown kind or state is dropped.
  - Content dates follow `YorozuActivityState` as Swift's default `JSONDecoder` reads it: seconds since 2001-01-01. Wire timestamps (`timestamp`, `staleDate`, `dismissalDate`) are epoch seconds; a value of 1e11 or more is rejected as milliseconds.
  - `LIMIT`, `LINGER_MS` and `STALE_MS` are the same numbers as `YorozuJobs` in the app. Sort order matches `YorozuJobs.sorted`: needs you, recording, running, then finished; newest first within each. Finished rows leave once they lingered and at most `LIMIT` stay, as `YorozuJobs.apply` does.
  - `MAX_STEPS` must match the relay's: the relay refuses a job above it and drops the host.
  - Step counts go at most every `STEP_INTERVAL_MS` per activity (the 15 s throttle), at priority 5. A row that finished, left or now needs the owner is urgent: Apple's immediate priority.
  - `plan` sends nothing when nothing shows differently. With nothing running the activity ends, dismissed once the last row lingered, since the suspended app runs no timer (as `show` with `endWhenIdle` does in the app).
  - A step has no time-dependent job fields; `staleDate` is bounded by the real clock.
  - The extension writer of needs-you rows stays: removing it would lose needs-you rows absent from the app's report.
  - `activityTurn`: when a turn moves on, devices whose activity shows it get a counts-only push.
- Watch (`ActivityWatch`):
  - Live Activities are kept by device key across sessions: the app is suspended while they matter.
  - `pairedDevices` is the same list the relay allowlist announces; records of unlisted devices are tombstoned at load.
  - One file holds all devices; its writes are serialized, as are each device's reservations.
  - The store format carries an immutable generation on active, pending and terminal records (v3). Older formats lack it, so load refuses them rather than overwrite them. Terminal records have exactly five fields and keep their requested generation.
  - The store's lock uses the SDK's file lock through a structural type, so standalone modules need no runtime SDK import. When the SDK has refused recovery, there is no PID probing or sidecar mutation.
  - After a load failure (`lockBlocked`), the next `relayRegistered()` retries the whole restore. A failed reconcile save after load degrades through `write()`; the load itself stands.
  - `forget` before load is recorded and applied to the loaded records, not to the empty pre-load map. Revocation keeps the redacted ordering tombstone.
  - A Mode H report before load would be discarded by the swap, so it is dropped, token included; the app re-reports.
  - `relayRegistered` can still register in one step for standalone callers; relay sockets announce devices between the steps. It sends a held change at the next allowed opportunity.
  - Closing the relay leaves its last `liveActivity` gate and watches intact. The capability gate applies only to reports; existing watches still push.
  - Reservation burns `kLast` before awaiting, since a throw may happen after the file's rename.
  - END goes to the activity's latest token, even one rotated during the save, and belongs to the record generation even when token rotation replaced its watch.
  - The token taken right before a push binds it to this record, whatever the relay slot held.
  - A saved END whose send check failed (`unsentEnd`) is sent once at the next registration, even after a newer activity replaced its tombstone. It is kept until `forget()`, `stop()` or a later END for the device. The flush at registration empties the entry before a new activity can reserve.
  - Activity ids are UUIDs and compare case-insensitively. Validation never trims or coerces wire fields.
  - Token rotation invalidates in-flight sends. Pending keeps content and clears only transport; pending reports revoke transport until a token-bearing report arrives. An admitted token cannot be rebound to another activity, and an ended activity's token is never replayed. Token loss persists the held snapshot too.
  - Legacy reports keep their original token clearing and snapshot behaviour; switching to legacy removes the durable rows.
  - Mode H row ownership (owner decision, 2026-11-08): pending keeps bindings, host rows and sent state; undelivered host steps survive rotation and pending; a restored host already owns its steps.
  - A host done row is saved, with its steps and finish time, before a stale app report can overwrite it; any pushed token stays host-done. Report rows advance only 15 s after done, inside the 120 s linger.
  - A restart clears only throttle time; the same live owner and disk remain. The device's last reported step snapshot and its binding survive a restart.
  - Admission tombstones a conversation whose real owner is absent.
  - `stop` deliberately suppresses pending sends.
- Relay:
  - The relay stores only a device's Live Activity push token, registered by the host, never the activity's content. The token lives in the same APNs environment as the device's own token.
  - `parseActivityState` rebuilds the content state from known fields only: opaque tokens, kinds, states, counts, times.
  - Activity pushes queue apart from the frame queue (`activityTail`), in the order the host sent them, so APNs never delays a frame.
  - The relay reads the slot's token on arrival and queues the send; the send starts by dropping the push if the slot no longer holds that token. A delivered END clears the slot only if it still holds the sent token. When the relay drops a token, it has already deleted it before emitting `activityGone`.
  - A push goes to the app's topic with Apple's Live Activity suffix and is signed by the same token key. It has no alert: the activity changes silently and its own view is the notice.
  - A token is dead when it is unregistered, expired, or bad in both environments after the retry.

## Consequences

- The plugin is the writer while the app sleeps; the app is the writer while it runs. Both agree on limits and order because the numbers are shared.
- A plugin restart resumes pushing from disk without replaying ended activities.

## Where in the code

- `plugins/openclaw-yorozu/src/liveactivity.ts` — `WireJob`, `ActivityReport`, `ContentJob`, `LIMIT`, `LINGER_MS`, `STALE_MS`, `STEP_INTERVAL_MS`, `MAX_STEPS`, `validStamp`, `cleanJobs`, `sorted`, `tidy`, `urgent`, `plan`
- `plugins/openclaw-yorozu/src/activitywatch.ts` — `ActivityWatchOptions.pairedDevices`, `ActivityWatch` and its `activities`, `writes`, `unsentEnd`, `forgottenBeforeLoad`, `relayRegistered`, `relayDown`, `forget`, `sendPush`, `report`
- `plugins/openclaw-yorozu/src/activitystore.ts` — `FileLock`, load
- `plugins/openclaw-yorozu/src/relay.ts` — `activityTurn`
- `plugins/openclaw-yorozu/test/activitywatch.test.ts`, `activitystore.test.ts`, `liveactivity.test.ts`, `relay-integration.test.ts`, `relay-registration.test.ts`
- `apps/relay/src/worker.ts` — `activityPrefix`, `Room.activityTail`, activity token registration
- `apps/relay/src/protocol.ts` — `parseActivityState`, `activityPayload`, `MAX_STEPS`
- `apps/relay/src/apns.ts` — `topic`, `dead`
- `apps/relay/src/protocol.test.ts` — activity content-state fixture
