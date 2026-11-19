# Sync restart durability (S1, S1b, S2, S4; shape A1(b))

Status: draft (T0 answered; Yorozu decisions on T0 recorded 2026-11-19 11:21 JST)
Brief: box handover `inbox/coder/20261119-1104-yorozu-yorozu-sync-restart-durability.md` (Tier: feature)
Source spec: box handover `transfers/20261119-yorozu-sync-stability-spec.md` (v4 with §9 decisions 5 and 6), and its EGM round 4 report (`transfers/20261119-yorozu-sync-spec-egm/r4-20261119-103309/consolidated_review_report.md`)
Baseline: `origin/main` at `8a278a5c`

## Problem

The OpenClaw Gateway on the owner's Mac mini restarted five times between Nov 2 and Nov 12. Yorozu's host plugin runs inside it and forgets everything on each restart. So, today:

- **S1.** A message can run twice. The host answers `delivered` and then drops repeats with an in-memory list of message ids. A restart clears the list. A device that never got `delivered` resends the message in its next session, and the agent runs it again.
- **S1b.** A message the host accepted just before a restart can vanish. The device already shows ✓✓ (`delivered`), so it never resends; the restart killed the turn (or the message was still waiting behind another turn), and nothing tells the device.
- **S2.** A turn the restart cut off never ends on the devices. No `typing false` and no `error` arrives. The app shows "working…" for up to 10 minutes and nothing offers to send the message again.
- **S4.** A device that opens a session in the middle of a turn learns about it late: only from the next typing keepalive (every 8 s) or the next event.

## Solution

- The host keeps a durable **run ledger**: one record per message id, written when the message is accepted. A repeat of a recorded message id never runs again, across restarts, and still gets `delivered`.
- Once per process, at start-up, the host marks every run that an earlier process accepted but never finished as **interrupted**, unless the owner's auto-retry rule still holds it or OpenClaw's own restart recovery is resuming it. When OpenClaw is resuming a turn, its reply arrives by itself and the host says nothing. When the host can't tell, it says nothing either: a stuck "working…" that the app's 10-minute window ends is better than a double run.
- The next time each device opens a session, the host tells that device, once, about each interrupted turn of the last 24 hours: `typing false` for its conversation and the existing `error run_failed` event carrying a fixed reason text. It also re-sends `run_started` for each turn that is running right now.
- The app shows an interrupted turn as an **Interrupted** row with a **Resend** button. The wait ends at once: typing, the stall banner and "working…" clear. Resend sends the original's text, attachments and quoted message again as a new message with a new message id. Nothing is resent without the owner's tap.
- Old apps, the Windows app and older hosts keep working: an old app shows the same event as today's "The agent run failed: …" row, and an old host never sends it.

## User stories

1. As the owner, I want a message the host already accepted to run at most once even if the Gateway restarts, so that the agent never does the same work twice.
2. As the owner, I want a device that resends a message after a restart (because it never got ✓✓) to get ✓✓ again without the message running a second time.
3. As the owner, I want a turn that a restart cut off to end on every device with an "Interrupted" row instead of "working…" for 10 minutes, so that I know the reply is not coming.
4. As the owner, I want a message that a restart caught while it was still waiting behind another turn to show the same "Interrupted" row, so that nothing I sent vanishes silently.
4a. As the owner, I want a turn that OpenClaw resumes by itself after a restart to just deliver its reply, with no Interrupted row and no Resend, so that I never cause a double run.
4b. As the owner, I want one Interrupted row per cut-off run, even when several of my messages were folded into that run, with Resend sending the last of them.
5. As the owner, I want a Resend button on that row that sends the same text, attachments and quoted message as a new message, so that I can get the answer with one tap.
6. As the owner, I want nothing resent unless I tap Resend, so that the agent never repeats an action on its own after a restart.
7. As the owner, I want the row to say "Resent" with no button after I tap Resend on this device, so that I don't send it twice by accident.
8. As the owner, I want a run that fails for a moment (a plugin reload, an overloaded or rate-limited model) before any reply or tool to keep running again by itself for about four minutes, exactly as today, even across a restart.
9. As the owner, I want a device that connects in the middle of a turn to show the turn as running right away.
10. As the owner, I want the Interrupted row to keep its state after relaunching the app and after the next session open repeats the same report, so that rows don't pile up or come back after I resent.
11. As the owner using an older app build or the Windows app, I want the interrupted turn to show as today's "The agent run failed: interrupted by a host restart" row, so that the wait still ends there.
12. As the owner, I want a plugin reload (a `channels.yorozu` config change) to mark nothing interrupted, because a reload doesn't kill running turns.
13. As the owner, I want the host to keep working when its local store fails: it logs the failure, never fails a turn because of it, and falls back to the transcript to tell a repeat from a new message.
14. As Yorozu (the agent), I want log lines for every duplicate, interruption and store failure, so that I can measure the fix for two weeks after it ships.

## Implementation decisions

### Glossary (terms used in this spec)

| Term | Meaning |
|---|---|
| Restart | The Gateway process stops and starts (an update, `openclaw gateway restart`, or a crash). A plugin reload (`startAccount` again in the same process) is not a restart. |
| Process id (boot id) | `"<pid>:<rounded performance.timeOrigin>"`: the same across plugin reloads, new after a restart. |
| Run ledger | The host's record of accepted messages, keyed by message id: conversation id, state, host receipt time, and the devices already told about an interruption. In memory, loaded at account start, written through to a bounded keyed-store namespace. |
| Ledger states | `open` (accepted, queued or running, joined to a running run, or parked for retry), `ended` (the turn finished, failed or was answered; also an entry the sweep left to OpenClaw's recovery or couldn't classify), `interrupted` (an earlier process accepted it and never ended it, neither the retry store nor OpenClaw's recovery holds it). |
| Run key | The message id of the message whose agent run started (its `onAgentRunStart`). A message folded into a running run (queue mode `steer` or `collect`) gets that run's key. A message that never started or joined a run is its own run. |
| Recovery pending | OpenClaw's own restart recovery holds custody of the conversation's session: read from the plugin-visible session entry fields (below). |
| Retry store | The existing keyed-store namespace `retry`, where a run that failed for a temporary reason before any reply or tool waits for its next attempt (5, 15, 30, 60, 120 s). The owner's auto-retry rule. |
| Start-up sweep | The one pass per process that turns `open` entries from an earlier process into `interrupted`. |
| Session-open report | What the host sends one device right after that device's `peer_info`: read cursors (today), then, for each interrupted turn that device hasn't been told about, `typing false` and the interrupted error, and `run_started` for each running turn (new). |
| Interrupted error | `error {code: "run_failed", message: "interrupted by a host restart", convId, messageId}`. The `message` text is a fixed constant both sides share. |
| Interrupted row | The app's error row for an interrupted error, with Resend. |
| Resend | The owner's tap on an interrupted row: a new user message with a new message id and the original's text, attachments and quoted message (`replyTo`). |

### Host: run ledger (ticket 01)

- **Record.** `{convId, state: open | ended | interrupted, at, run?, told?}` per message id. `run` is the run key once known. `at` is the host's receipt time in ms; it is never sent to devices and never adjusted. `told` lists the device keys (the device's public signing key, as the allowlist stores it) already sent the interrupted error; ticket 02 writes it.
- **Storage.** A module-level map in a new ledger module, loaded at account start next to the other bounded stores, written through to keyed-store namespace `runs` with `maxEntries: 10_000` and `overflowPolicy: "evict-oldest"`, the same pattern as the replies store. On load, entries older than 24 h are dropped from the map and deleted from the store. Writes for one message id go through one promise chain so they land in call order. A failed write logs `yorozu: run ledger write failed: <error>` and never fails the turn. Module-level state means a plugin reload reuses the map (T0 answer 5).
- **Claim, on every `message` event, in the Hub, before `delivered`.**
  1. A second copy of a message id whose claim is still in flight (relay and direct can race) waits for the first claim's result.
  2. The ledger answers `new` or `duplicate(state)`. The normal path is synchronous: the map is checked and, for an unknown id, a new `open` entry is put in the map before `delivered` is broadcast. The store write follows without being awaited (see Risks: durability gap).
  3. `delivered` is broadcast, as today, in both cases.
  4. `new`: the message runs (`onMessage`). `duplicate`: the host logs `yorozu: duplicate message skipped (<state>)` and does not run it. If that message's turn is running in this process, it also sends `run_started` for it to that device only. If the state is `interrupted`, it sends that device the interrupted error for it.
- **Degraded ledger (decision 3, transcript fallback).** If the store can't be read at account start, the host logs `yorozu: run ledger unavailable: <error>` and starts with an empty map ("degraded"). In degraded mode the claim still checks the map first. Only on a miss does it ask the transcript, through a new history export that looks for a user event of that conversation whose transport message id matches, telling "found", "missing" and "read failed" apart. Found is `duplicate(ended)`. Missing is `new`. A failed read is `new` and logs `yorozu: run ledger unavailable: <error>`. New entries are still kept in the map and written through, so a repeat within the same process is caught by the map.
- **Writers.** `open` at claim. `run` = own message id when its agent run starts. When a message's inbound call returns without its own run start while another run is running in the same conversation (it was steered or collected into that run; T0 answer 3), the entry stays `open` and takes that run's key. `ended` when a turn's outer `finally` runs and the run was not parked: a reply, a reported failure, a pre-run failure, or "gone"; ending a run also ends every `open` entry that carries its run key. A parked run stays `open`: the retry store owns it, and the rerun ends it. Nothing else writes the ledger.
- **Run log line.** Each run start logs `yorozu: run started <messageId> attempt <n>`, so the measures can find a message id that ran twice across processes.
- **Wiring.** The plugin entry creates and loads the ledger, and passes it through the relay host options to the Hub (`ledger` option). The conversation module reaches it through a module-level getter; with no ledger set, every call is a no-op. The Hub keeps today's in-memory 24 h id list when no ledger is given (the direct-path end-to-end test and existing unit tests).
- **Boundaries.** The Hub module keeps importing only Node built-ins and the wire files: the claim types live in the Hub module, and the ledger module imports them from there. The relay module doesn't import the ledger or the conversation module; the plugin entry passes callbacks.

### Host: start-up sweep and session-open report (ticket 02)

- **Sweep once per process.** At account start, after the ledger loads and before the retry loop (`runParked`) and the relay host start. A persisted marker (keyed-store namespace `run-sweep`, one row) holds the process id of the last sweep; the sweep runs only when the marker differs from the current process id, then writes it. So a plugin reload never sweeps, even if the module were re-imported.
- **Sweep rule.** The sweep reads the message ids the retry store holds (a new async export of the retry module). `open` entries the retry store holds are left alone. The rest are grouped by conversation, and each conversation's session entry is classified once (T0 decision Q1 (b)):
  - **Recovery pending** (OpenClaw is resuming the turn or has queued it for recovery): every such entry becomes `ended`, logged `yorozu: turn left to OpenClaw recovery <messageId>`. No report, no Resend; OpenClaw's reply arrives on its own.
  - **Nothing pending:** every such entry becomes `interrupted`, logged `yorozu: turn interrupted by restart <messageId>`.
  - **Unknown shape** (a field the classifier reads is present with an unexpected type, or the read throws): every such entry becomes `ended` and the host logs one warning `yorozu: restart recovery state unreadable, not marking interrupted: <reason>`. Fail safe toward at-most-once: no Interrupted, no Resend; the app's 10-minute awaiting window ends the turn on the device.
- **The classifier** (one small adapter function, the only place that knows OpenClaw's field names), against OpenClaw 2026.9.8's plugin projection of the session entry (`getSessionEntry`, which strips private fields such as `mainRestartRecovery` but keeps these):
  - unknown if any of `restartRecoveryRuns` (array of `{runId: string}`), `restartRecoveryTerminalRunIds` (array of strings), `restartRecoveryDeliveryRunId`, `restartRecoveryDeliverySourceRunId`, `restartRecoveryDeliveryRequestFingerprint` (strings), `restartRecoveryDeliveryContext` (object), `pendingFinalDelivery` (object), `status` (string), `abortedLastRun` (boolean) is present with another type;
  - nothing pending if the entry is missing, or it is OpenClaw's "retryable unadopted chat claim" (status `failed` or `killed`, not `abortedLastRun`, no delivery context, delivery run id equal to the source run id, a request fingerprint, no pending final delivery, no non-terminal recovery run: OpenClaw's startup skips these and leaves them to a client retry);
  - recovery pending if a recovery run is not in the terminal list, or a delivery run id is set, or a final delivery is pending (OpenClaw's `hasMainSessionRecoveryClaim` minus the private field);
  - otherwise nothing pending. Entries the retry store holds stay `open`; the retry loop reruns them as today, and their rerun ends them. If the retry store can't be read, the sweep is skipped for this process (log `yorozu: restart sweep skipped: <error>`, marker not written), so it never marks a message the retry loop may still run.
- **No automatic rerun (decision 5).** The sweep never queues, parks or runs a message. The owner's auto-retry rule is unchanged: a parked message keeps its schedule across a restart, as today.
- **Session-open report.** In the existing per-device `peer_info` hook, after the read cursors, the host sends that device only:
  - for each interrupted **run** (its `interrupted` entries grouped by run key) whose newest `at` is within the last 24 h and whose entries' `told` doesn't list this device, newest first, at most 100 runs: `typing {convId, active: false}` (left out when that conversation has a turn running in this process now) and one interrupted error whose `messageId` is the run's last user message (newest `at`); then the device key is added to `told` on every entry of that run and written through. Resend therefore applies to that last message (T0 decision Q3);
  - `run_started` for each turn that is running in this process now (the conversation module's running turns, passed in by the plugin entry).
  Nothing is broadcast at start-up: no device has a session then.
- **Once per device.** `told` makes each device get each interrupted error once, across reconnects and later restarts. If that one send is lost (the session drops at that moment), the device falls back to today's 10-minute wait; accepted. A repeat would still be harmless: the app's error row has a fixed id per message. `run_started` for a turn the device already shows changes nothing.
- **Live Activity.** No change. A turn that is not live when the relay host starts already has its Live Activity turn job ended by today's restore path; a parked message keeps today's behaviour.

### Wire (contract docs only, no new kind, field or capability)

- `run_failed` gains one documented reason: `message` exactly `interrupted by a host restart` means a restart cut the turn off and it will not run again by itself. A client may show its own text and offer Resend for it. Every other `run_failed` keeps its meaning.
- The dedupe promise changes from "remembered 24 h, up to 10,000" in memory to the same bounds kept across restarts.
- The session-open report is documented next to the read cursors that already follow `peer_info`.
- Old peers: an older app shows the error as "The agent run failed: interrupted by a host restart", which already ends its wait. An older plugin never sends it. Windows needs no change.

### App: Interrupted row and Resend (ticket 03)

- **One row per run.** The host sends one interrupted error per cut-off run, for the run's last user message, so the app needs no grouping.
- **Recognising it.** An `error` whose code is `run_failed`, whose `message` equals the shared constant and that carries a conversation id and message id is an interrupted error. Everything today's error path does still happens: messages below `delivered` are marked rejected, the error row with id `error:<messageId>` is appended once, and typing stops for the conversation (which also clears the stall banner). Because the newest item is now the error row, the conversation stops awaiting a reply.
- **Row state.** The error item gains one persisted optional field, the Resend state: `offered` or `sent`. It is set to `offered` when the row is made from an interrupted error. Older builds ignore the field and show the row's text.
- **Row text.** Localised: "Interrupted: the host restarted during this reply." with a **Resend** button while the state is `offered` and the original user message is still in the conversation; "Resent" and no button once the state is `sent`. Strings go into the String Catalog for every shipped language.
- **Resend.** A new model method takes the error row: it appends a new user item with a fresh id, the original's text, its `replyTo` as stored, and its attachments (already uploaded, reused by id with no re-upload), sends it through the normal outbox, and sets the row's state to `sent`. It never runs without the tap, and a second tap on the same row does nothing.
- **Other devices.** Each device shows its own Resend. Two devices can each resend once; that takes two deliberate taps, like typing the message twice (accepted; see Alternatives).
- **Unchanged.** Siri's wait already ends on an `.error` item. `needsAttention` becomes true for the conversation, as for any failed turn.

## Testing decisions

- **Seams, highest first.**
  - Hub: the existing fake host and Noise device harness, extended with optional `ledger` and `log` parameters. Restart = a new Hub over a ledger reloaded from the same fake keyed store.
  - Conversation and ledger writers: the existing stand-in host for OpenClaw (the genui hooks and host stub), extended with a fake keyed store that can be reopened, made to throw and slowed, and that records writes; clock and process id are injected.
  - Retry interplay: a test-local resolve hook that loads the **real** retry module for the module under test while the runtime module stays the stub (the precedent `prerun-error` stubs the retry module, so it is extended this way, not copied). This answers report item A4.
  - Start-up order: recording stubs for the retry and relay modules, so the order load → sweep → retry loop → relay host is asserted.
  - App: `ModelHarness` with `ScriptedTransport`, which records sent messages; a model-level predicate tells whether a conversation is awaiting and what state a row's Resend is in.
- **What a good test checks:** behaviour at the seam: events each device receives, whether `onMessage` ran, log lines, the store's rows after a reload, the app's items and sent messages. Not private maps.
- **Prior art:** `hub-events` and `hub-session` tests (Hub), `genui-golden` and `prerun-error` (conversation), `activitywatch` U6/U7 (Live Activity restore), `AppModelSyncTests` (app).
- **Red tests per ticket** (each PR's first code commit holds only these; the PR body names each with its failure on the parent):
  - 01: (1) a new Hub over a reloaded ledger gets message M again: `onMessage` ran once, `delivered` went out both times, the log has one `duplicate message skipped (ended)`; (2) a duplicate of a running M sends `run_started` once, to that device only; (3) degraded ledger and the transcript holds M: M doesn't run; (4) degraded ledger and the transcript read fails: M runs and the log has `run ledger unavailable`; (5) writes follow the writer table: a park leaves `open`, the outer `finally` writes `ended`, a pre-run failure writes `ended`; (6) writes for one id land in order with a slow store; (7) a failed write logs and the turn still completes; (8) entries older than 24 h are dropped on load; (9) degraded ledger: a second copy of M in the same process is a duplicate without a transcript read. Guards: relay and direct copies of M arriving together run once; without a ledger the Hub behaves as today; the legacy plugin sequence tests stay unmodified.
  - 02: (1) an `open` entry from an earlier process, not parked, becomes `interrupted` and logs once; (2) a parked id stays `open` and the real retry loop still reruns it with today's delays; (3) a second start in the same process (reload) sweeps nothing; (4) a retry-store read failure skips the sweep and writes no marker; (5) the start order is load → sweep → retry loop → relay host; (6) a turn cut off by a simulated restart produces, for each of two devices, exactly one `typing false` and one interrupted error, after the read cursors and to that device only; reconnecting, and a second simulated restart, send that device nothing more; (7) the report holds at most 100 errors and skips entries older than 24 h; (8) a running turn gets `run_started` in the session-open report; (9) a duplicate of an `interrupted` message gets `delivered` and the interrupted error, and doesn't run; (10) recovery pending: a session entry with a non-terminal `restartRecoveryRuns` run (and, separately, a `pendingFinalDelivery`) leaves its entries `ended`, logs `left to OpenClaw recovery` and reports nothing; (11) nothing pending: no recovery fields (and, separately, a retryable unadopted chat claim) marks interrupted; (12) unknown shape: `restartRecoveryRuns` as a string leaves the entries `ended`, logs the warning once and reports nothing; (13) two steered messages and one run: M1 starts the run, M2's inbound call returns without a start while M1 runs, a restart cuts the run off: each device gets exactly one interrupted error, for M2, and one `typing false`; (14) pin test against OpenClaw 2026.9.8 (runs when `YOROZU_OPENCLAW_SDK` points at an installed package, as `conversation-owner` does; skipped in CI): an entry written through the real session store with these fields is returned by the real `getSessionEntry` with every field the classifier reads, with the types it expects. Guards: an interrupted turn's Live Activity job still ends on restore; a message under the auto-retry rule still retries as today; a device with no interrupted entries gets only today's read cursors.
  - 03: (1) an interrupted error appends one Interrupted row with Resend, clears typing, stall and awaiting for that conversation; (2) the same error again (next session open) adds no row and keeps a `sent` state; (3) Resend sends exactly one new message with a new id and the same text, `replyTo` and attachment ids, and the row shows "Resent" with no button; (4) a second tap sends nothing; (5) nothing is sent without the tap, across a reconnect; (6) the row state survives a relaunch (store round trip); (7) a `run_failed` with any other message keeps today's row with no Resend; (8) the new strings exist in every shipped language.
- **Acceptance commands.**
  - Plugin suite, as CI runs it: `node --test 'plugins/openclaw-yorozu/test/*.test.ts'` with the Node version CI pins, from the repo root.
  - Plugin typecheck, per the plugin README (`plugin-typecheck` workflow), including the standalone config.
  - Help bundle: `pnpm --filter @yorozu/help-mcp check` (repo-pinned pnpm) after regenerating it whenever a top-level docs file or the plugin README changes.
  - App: the `checks.yml` iOS compile-and-test job (`YorozuTests` on a simulator) and `swift test --package-path packages/YorozuWire`.

## Alternatives considered

- **The v4 shape: a new `turn_state` event, a `turnState` capability, a `resendOf` field and a host-side Resend guard.** Not taken (decision 5, A1(b)). `error run_failed` already ends the wait, clears typing, fails Siri's wait, survives relaunch and is idempotent by row id, and it works on shipped builds and Windows. The guard only protected against two deliberate taps.
- **Automatic requeue after a restart (v4 decision 2).** Withdrawn by decision 5; a possible later spec. The owner's auto-retry rule is unchanged.
- **A per-entry process id instead of one sweep marker.** Not taken: it causes the reload race the round-4 review found (K3) and every write would need to restamp it.
- **Waiting for the store write before `delivered`.** Not taken: an async step before every ✓✓; the gap it closes is a restart within milliseconds of a message (Risks).
- **A new distinguishing field on `error` instead of a fixed `message` text.** Not taken: it would be new wire (contract, both decoders, Windows). The fixed text is documented in the contract and asserted on both sides by tests.
- **A complete "still running" listing with the app's unlisted rule (decision 1's second half).** Deferred, see Further notes: it needs a new listing event, which A1(b) rules out where `run_failed` suffices.
- **Transcript only, no store.** Not taken: queued messages aren't in the transcript yet. Kept as the degraded fallback (decision 3).

## Risks

| Risk | Mitigation or check |
|---|---|
| Durability gap: the entry is in memory before `delivered`, but its store write lands a few ms later; a restart in between loses it | Accepted: that message then behaves as today (it may run again if resent, or wait 10 min). Measured: `duplicate message skipped` vs restarts. |
| A failed `ended` write leaves an `open` entry that the next restart marks interrupted although the turn finished | Accepted: `run ledger write failed` is logged and its target is 0 in the measures; the owner sees an Interrupted row for an answered turn and need not resend. |
| A store that can't be read at start-up | Degraded mode with the transcript fallback; nothing is marked interrupted from an empty map; logged. |
| Message ids stored on disk | Only ids, conversation ids, states and times; no message text (the v4 stored bodies are gone with the requeue). |
| Two devices both tap Resend | Accepted (two deliberate taps). |
| Report size at session open | At most 100 errors and 100 `typing` events, about 200 bytes each. |
| A false Interrupted mark after a reload | A reload never sweeps (marker), tested. |
| OpenClaw itself resumes a cut-off turn after a restart (T0 answer 1: yes) | The sweep reads OpenClaw's recovery fields and stays silent for those turns (decision Q1 (b)). |
| OpenClaw renames or reshapes those fields in an update | The classifier's shape check fails safe (no Interrupted, warning logged), and the SDK pin test fails when run against the new version. |
| Recovery custody that only OpenClaw's private field shows (`mainRestartRecovery`, stripped from the plugin projection) | Accepted residual: such a turn could be marked interrupted while OpenClaw also resumes it. Ticket 02's before-code step checks in the 2026.9.8 source whether startup marking can clear the public fields before the channel starts, and records the answer in the PR. |
| OpenClaw decides after the sweep that nothing is eligible and drops custody | That turn gets no Interrupted row; the app's 10-minute window ends it (the fail-safe direction). |

## Out of scope

- S3 and S5–S8 (later spec), any relay change, any pairing change, any timestamp adjustment, any Live Activity format change, Windows sync tests (S8).
- Automatic rerun after a restart; typing for queued turns from other devices (v4 T3b).
- Release, TestFlight or merges: draft PRs only.

## Further notes

- **Deferred (Yorozu, 2026-11-19 11:21 JST): decision 1's app-side "unlisted" rule.** A turn the app shows as running but the host doesn't list is not marked interrupted: shape A1(b) has no listing event. The host side of decision 1 stays (the session-open report tells each device which runs were interrupted and which turns are running). The case it covered (the host lost its ledger) keeps today's 10-minute wait and is measured by `run ledger unavailable` (target 0). A later spec can add a capability-gated listing.
- **Accepted by Yorozu (11:21 JST):** Resend only on interrupted rows; the fixed message; `typing false` plus the error once per device on its next connect; the once-per-process sweep marker; the 100-run cap; skipping the sweep when the retry store can't be read; the shared constant kept in each side's code (no YorozuWire change).
- **Yorozu T0 decisions (11:21 JST, final):** Q1 (b): skip turns OpenClaw is resuming or has queued for recovery, fail safe on an unknown shape, pin the fields with a test against 2026.9.8. Q3: one Interrupted row per cut-off run, keyed by run, for the run's last user message.
- **Measures (Yorozu, the agent, for 2 weeks after the Release Mac build that ships ticket 02):** `rg 'yorozu: (run started|duplicate message skipped|turn interrupted by restart|turn left to OpenClaw recovery|restart recovery state unreadable|run ledger|restart sweep)' ~/.openclaw/logs/`. Targets: `restart recovery state unreadable`: 0 (any line means the classifier needs an update for the running OpenClaw); each `turn left to OpenClaw recovery` followed by a delivered reply in that conversation within 10 minutes; `run started` twice for one message id with attempt 0 in different processes: 0; `run ledger write failed`: 0; `run ledger unavailable`: 0; `restart sweep skipped`: 0; every `turn interrupted by restart` within a minute after a line in `~/.openclaw/logs/gateway-restart.log` (an unmatched one is a bug, reported to Coder as a fix brief).
- **Verification** is in CI and on simulators only, as the owner answered (grill Q5); no real-device run is needed.
- **T0 answers** (OpenClaw 2026.9.8, read only; box handover `transfers/20261119-coder-sync-t0-answers.md`): 1 yes (OpenClaw's main-session restart recovery can resume a cut-off Yorozu thread turn and deliver through the outbound adapter); 2 no (its `MessageSid` dedupe is memory-only); 3 not one (queue mode `steer` by default; `collect` merges); 4 no second transcript append on a parked rerun; 5 a `channels.yorozu` reload reuses the loaded module; 6 `onToolStart` has no before-execution guarantee (moot: no `acted`); 7 keyed store `register`/`delete`/`entries`/`lookup`, `evict-oldest` or `reject-new`, awaited transactional writes. T0 now runs before spec review rounds (process note agreed by Yorozu).
- **Release triggers, per PR:** the docs PR (spec and tickets) triggers nothing; the plugin PR (tickets 01 and 02) starts Release Mac, and Deploy website because the contract, architecture doc and plugin README change and the help bundle is regenerated; the app PR (ticket 03) starts Release Mac and Release iOS.
- **Rollback:** revert the PR. An older plugin ignores the `runs` and `run-sweep` namespaces and keeps today's behaviour; an older app shows interrupted errors as plain failed-run rows.
