# Sync restart durability (S1, S1b, S2, S4; shape A1(b))

- **Status:** draft v2 (EGM round 1 addressed; T0 and T0b answered; Yorozu's T0 decisions recorded 2026-11-19 11:21 JST)
- **Brief:** box handover `inbox/coder/20261119-1104-yorozu-yorozu-sync-restart-durability.md` (Tier: feature). The box is the shared Linux machine the bots use; its handover folder is `/home/box/handover`.
- **Source spec:** box handover `transfers/20261119-yorozu-sync-stability-spec.md` (v4 with §9 decisions 5 and 6) and its EGM round 4 report.
- **Baseline:** `origin/main` at `8a278a5c`.
- **Roles:** the *owner* is Yumi, who uses the app. *Yorozu* in this spec means the product unless written "Yorozu (the agent)": the agent that owns the product's decisions and wrote the brief. *Coder* is the agent that wrote this spec and runs the implementation.

## Problem

The OpenClaw Gateway on the owner's Mac mini restarted five times between Nov 2 and Nov 12. Yorozu's host plugin runs inside it. Parked retries survive a restart; everything else the plugin keeps about messages and turns is in memory and is lost. No double run or lost message has been traced to a restart yet; this fix is preventive, for the cases the source spec found by reading the code:

- **S1.** A message can run twice. The host answers `delivered` and then drops repeats with an in-memory list of message ids. A restart clears the list. A device that never got `delivered` resends the message in its next session, and the agent runs it again.
- **S1b.** A message the host accepted just before a restart can get no reply and no error. The device already shows ✓✓, so it never resends it. Either the restart cut its turn off, or the message was still waiting in OpenClaw's queue behind another turn, which a restart empties (T0b answer B2). Nothing tells the device.
- **S2.** A turn the restart cut off ends on the devices only when the app's 10-minute awaiting window runs out (the app gives up waiting for a reply 10 minutes after the last sign of progress), unless OpenClaw resumes it. Nothing offers to send the message again.
- **S4.** A device that opens a session in the middle of a turn learns about it late: only from the next typing keepalive (every 8 s) or the next event.

S3 (the source spec's history-gap case) and S5–S8 are a later spec.

## Goals

1. A message the host accepted runs at most once across restarts, within the bounds in "Promises and their limits".
2. Every run a restart cut off, that OpenClaw is not resuming, ends on each device at that device's next session open within 24 h, with a Resend the owner can tap.
3. Nothing reruns without the owner's tap; nothing runs twice because of OpenClaw's own restart recovery.
4. A device that connects mid-turn shows the turn as running at once.
5. Shipped apps, the Windows app and older hosts keep working with no new wire.

Non-goals: see Out of scope. The measures that check these goals are in Further notes.

## Solution

- The host keeps a durable **run ledger**: one record per message id, written when the message is accepted. A repeat of a recorded message id does not run again, after a restart too, and still gets `delivered`.
- Once per process, at start-up, the host looks at every message an earlier process accepted and never settled. It leaves alone what the owner's auto-retry rule still holds, and what OpenClaw's own restart recovery is resuming or may resume. It marks the rest **interrupted**. When the host can't tell, it marks nothing: at-most-once wins over liveness, and the app's 10-minute window still ends a stuck "working…".
- The next time each device opens a session, the host tells that device, once, about each interrupted run of the last 24 hours, newest first, at most 100 runs: `typing false` for its conversation and the existing `error run_failed` event with a fixed reason text, for the run's last user message. It also sends `run_started` for each run executing right now.
- The app shows that error as an **Interrupted** row with a **Resend** button. The wait ends at once. Resend sends the original's text, attachments and quoted message again as a new message with a new id. Nothing is resent without the owner's tap.
- Shipped apps, the Windows app and older hosts keep working: an older iOS app shows the event as a "The agent run failed: interrupted by a host restart" row, the Windows app flags the message as failed (which ends its wait), and an older host never sends it.

## Promises and their limits

At-most-once (goal 1) holds for a message id within 24 h and the latest 10,000 messages, once its ledger write has landed (a few milliseconds after `delivered`). It does not hold:

- in degraded mode (the ledger store can't be read at start-up): the transcript check can't see a message still queued, and a failed transcript read runs the message;
- for a write that failed (logged, target 0).

A turn OpenClaw resumes gets no Interrupted row, so the owner can't cause a double run by tapping Resend on it. A turn the host can't classify gets no Interrupted row either; the device waits out the 10-minute window. Details in Risks.

## User stories

1. As the owner, I want a message the host already accepted to run at most once even if the Gateway restarts, so that the agent doesn't do the same work twice.
2. As the owner, I want a device that resends a message after a restart (because it never got ✓✓) to get ✓✓ again without the message running a second time, so that a flaky connection costs nothing.
3. As the owner, I want a run that a restart cut off to end on each of my devices that opens a session within 24 h with an "Interrupted" row instead of "working…", so that I know the reply is not coming.
4. As the owner, I want a message that a restart caught while it was still waiting in the queue behind another turn to show an "Interrupted" row too, so that nothing I sent vanishes silently.
5. As the owner, I want a turn that OpenClaw resumes by itself after a restart to just deliver its reply, with no Interrupted row and no Resend, so that I can't cause a double run.
6. As the owner, I want one Interrupted row per cut-off run, even when several of my messages were folded into that run, with Resend sending the last of them, so that the chat isn't flooded with rows for one cut-off answer.
7. As the owner, I want a Resend button on that row that sends the same text, attachments and quoted message as a new message, so that I can get the answer with one tap.
8. As the owner, I want nothing resent unless I tap Resend, so that the agent never repeats an action on its own after a restart.
9. As the owner, I want the row to say "Resent" with no button after I tap Resend on this device, so that I don't send it twice by accident.
10. As the owner, I want a run that fails for a temporary reason (a plugin reload, an overloaded or rate-limited model) before any reply or tool call to be retried automatically after 5, 15, 30, 60 and 120 s, as before this change, including across a restart, so that brief outages fix themselves.
11. As the owner, I want a device that connects in the middle of a run this host process started to show it as running right away, so that I don't send the message again.
12. As the owner, I want the Interrupted row to keep its state after relaunching the app, and if the same interrupted error arrives again, so that rows don't pile up or come back after I resent.
13. As the owner using an older iOS build or the Windows app, I want an interrupted run to end my wait the way any failed run does, so that those apps need no update.
14. As the owner, I want a plugin reload (a `channels.yorozu` config change) to mark nothing interrupted, because a reload is not a restart: a run it breaks is retried or reported by the existing path, and the start-up sweep runs once per process.
15. As the owner, I want the host to keep working when its local store can't be read or written: it logs the failure and never fails a turn because of it; if the store can't be read at start-up it uses the transcript to tell a repeat from a new message, and queued or cut-off runs get the pre-change behaviour while degraded.
16. As Yorozu (the agent), I want the log lines listed in Further notes, so that I can check the targets there for two weeks after it ships.

## Implementation decisions

### Referenced decisions

| Label | Who and where | What it says |
|---|---|---|
| A1(b) | Yorozu (the agent), brief | Report cut-off runs with the existing `error run_failed`; no new event, field or capability; no `resendOf`. |
| Decision 1 | Owner, source spec v4 §9 | The host tells devices which turns were interrupted and which are running. Its app-side "unlisted" half is deferred (Further notes). |
| Decision 3 | Owner, source spec v4 §9 | Dedupe falls back to the transcript when the store fails. |
| Decision 5 | Owner, source spec v4 §9 | No automatic rerun after a restart; the auto-retry rule (`retry` store) is unchanged. |
| Q1 (b) | Yorozu (the agent), 2026-11-19 11:21 JST, final | Skip turns OpenClaw is resuming or has queued for recovery; fail safe toward at-most-once on an unknown shape; pin the fields with a test against OpenClaw 2026.9.8. |
| Q3 | Yorozu (the agent), 2026-11-19 11:21 JST, final | One Interrupted row per cut-off run, keyed by run, for the run's last user message. |
| Accepted choices | Yorozu (the agent), 2026-11-19 11:21 JST | The fixed message; Resend only on interrupted rows; `typing false` plus the error once per device on its next session open; the once-per-process sweep marker; the 100-run cap; skipping the sweep when the retry store can't be read; the constant kept in each side's code. |
| K3 | Source spec EGM round 4 | A per-entry process id races with reloads; use one sweep marker. |
| T0, T0b | Coder, read-only reads of OpenClaw 2026.9.8 | Answers in Further notes. |

### How a message flows (context)

- **Device → relay or direct path → Hub.** The Hub (plugin module) decrypts each device event; for a `message` it broadcasts `delivered` (✓✓) and hands the message to the conversation module.
- **Conversation module → OpenClaw.** It resolves the conversation's OpenClaw session (one session per conversation: the `per-channel-peer` route with the conversation id as thread id), calls OpenClaw's inbound dispatch, and turns OpenClaw's callbacks into `typing`, `run_started`, `tool`, `reply` and `error` events.
- **OpenClaw** runs one agent run per session at a time. A message arriving while a run is active is, by queue mode, *steered* into the active run (default) or put in a per-process *follow-up queue* that runs later (T0b B1). On a restart, OpenClaw marks the sessions whose run was cut off and may resume them itself ("restart recovery", T0 answer 1); its follow-up queue is lost (T0b B2).

### Glossary

| Term | Meaning |
|---|---|
| Restart | The Gateway process stops and starts (an update, `openclaw gateway restart`, or a crash). A plugin reload (`startAccount` again in the same process) is not a restart. |
| Boot id | `"<pid>:<Math.round(performance.timeOrigin)>"`: the same across plugin reloads, new after a restart. |
| Run | One OpenClaw agent run. Its **run key** is the message id whose `onAgentRunStart` fired for it. A message steered into a running run takes that run's key. A message that never started or joined a run is its own run. "Turn" below means the host's handling of one message. |
| Run ledger | The host's record of accepted messages, keyed by message id. In memory, loaded once per process, written through to keyed-store namespace `runs`. |
| Ledger states | `open`: claimed, preparing, running, steered into a running run, or parked for retry. `queued`: OpenClaw put it in its follow-up queue and it has not started. `settled`: the host will not run or report it again (answered, failed, gone, started from the follow-up queue, left to OpenClaw's recovery, or not classifiable). `interrupted`: the start-up sweep found it cut off by a restart. |
| Retry store | The existing keyed-store namespace `retry` (the owner's auto-retry rule): a run that failed for a temporary reason before any reply or tool call waits there for its next attempt. |
| Recovery pending | OpenClaw's restart recovery has, or may take, custody of the conversation's session (classifier below). |
| Start-up sweep | The one pass per process that settles or interrupts entries an earlier process left `open` or `queued`. |
| Session-open report | What the host sends one device right after its `peer_info`: read cursors (existing), then interrupted runs that device hasn't been told about, then `run_started` for executing runs. |
| Interrupted error | `error {code: "run_failed", message: "interrupted by a host restart", convId, messageId}`. The `message` is a fixed constant each side keeps in its own code. |
| Interrupted row, Resend | The app's row for an interrupted error, and the owner's tap on it that sends the original again as a new message. |
| Awaiting window, stall banner | The app's 10-minute limit on waiting for a reply, and the banner it shows when a turn makes no progress. |

### Host: run ledger (ticket 01)

- **Record.** Per message id: `{convId, state, at, run?, interruptedAt?}`. `at` is the host's receipt time in ms (never sent to devices, never adjusted). `run` is the run key once known. `interruptedAt` is the sweep's time, set with `interrupted`.
- **Storage.** A new ledger module with module-level state. Loaded once per process: a second `startAccount` (reload) keeps the map, so pending writes are never overwritten by a reload. Store: `openKeyedStore({namespace: "runs", maxEntries: 10_000, overflowPolicy: "evict-oldest"})`, like the replies store; unlike it, the ledger serialises writes per id (one promise chain per id), logs failures (`yorozu: run ledger write failed: <error>`) and prunes. Pruning: on load, entries older than 24 h are dropped from the map and deleted from the store; on each claim, the map drops entries older than 24 h and the oldest beyond 10,000, as the Hub's id list does now. A write failure never fails a turn.
- **Claim (synchronous), on every `message` event in the Hub, before `delivered`.**
  1. The Hub calls the injected `claim(message)`.
  2. Unknown id: a new `open` entry goes into the map, the store write starts without being awaited, and `claim` returns "fresh".
  3. Known id: `claim` logs `yorozu: duplicate message skipped (<state>)` and returns the events for the sending device only (below).
  4. The Hub broadcasts `delivered` in both cases, then runs a fresh message (`onMessage`) or sends the duplicate's events to that device.
- **Events for a duplicate.** `open` and its run executing now (the conversation module's `runningTurns` names that run key): `run_started`. `interrupted`: `typing false` (unless a run is executing in that conversation) and the interrupted error for its run's last message (the same one the report names), so a duplicate never creates a second row. `queued`, `settled`, or `open` but not executing: nothing.
- **Writers** (the only places that change state; the sweep and report are in ticket 02):
  1. **Claim:** `open`.
  2. **Run start** (`onAgentRunStart` for message X): if X's inbound dispatch is still awaiting, X becomes `open` with `run = X`, even if it was `queued` (reopen rule). If X's dispatch already returned (X came from the follow-up queue), X becomes `settled`, and so does every earlier `queued` entry of that conversation (a collected batch starts with its last item's callback; T0b B1). A follow-up that starts is settled at once because the host gets no end signal for it.
  3. **Dispatch returns** for X, by OpenClaw's `dispatchResult.deferredToActiveRun`: `"steer"`: X stays `open` with `run` = the conversation's executing run key; if none, `settled`. `"followup"`: X becomes `queued`, unless its run already started (writer 2). Missing: no change here (writer 4 settles it). Any other value: `settled`, with a warning.
  4. **Outer `finally`** for X, when not parked: X becomes `settled` (reply, reported failure, pre-run failure, or gone), unless X is `open` with another run key (steered) or `queued`. Settling X also settles every `open` entry whose `run` is X.
  5. **Parked:** X and the entries steered into its run stay `open`. The rerun starts X again (writer 2) and settles them together. A steered message's text is replayed only if it reached the transcript before the failure (T0b B1: a steer returns after its transcript commit).
- **Run log line.** Each run start logs `yorozu: run started <messageId> attempt <n> boot <bootId>`; the first attempt is 0.
- **Degraded ledger (decision 3).** If the store can't be read at start-up, the host logs `yorozu: run ledger unavailable: <error>`, starts with an empty map, and doesn't sweep (ticket 02). The claim checks the map first; on a miss it asks a new history lookup for a user event in that conversation's session with that transport message id: found → duplicate (`settled`); missing → fresh; read failed → fresh, logged `yorozu: run ledger transcript check failed: <error>`. The transcript read is synchronous. New entries still go into the map and the store. The fallback exists because dedupe protects at-most-once; the deferred "unlisted" rule only protected liveness.
- **Wiring.** The plugin entry loads the ledger and passes `claim` and a running-run lookup through the relay host options to the Hub. Without `claim`, the Hub keeps its in-memory id list, so the existing Hub tests and the legacy plugin sequence tests run unmodified. The Hub stays importing only Node built-ins and wire files (standalone typecheck).

### Host: start-up sweep and session-open report (ticket 02)

- **When.** In `startAccount`, in this order: load the existing stores; load the ledger; sweep; `watchSessions`; the retry loop (`runParked`); the gateway notice; the relay host. Nothing is broadcast at start-up: no device has a session yet.
- **Once per process.** A persisted marker (namespace `run-sweep`, `maxEntries: 1`, key `last`) holds the boot id of the last sweep. The sweep runs only when it differs, then writes it after the entry writes. If the marker can't be read, or the ledger is degraded, there is no sweep and no marker write (logged `yorozu: restart sweep skipped: <reason>`).
- **Sweep procedure.**
  1. Read the message ids the retry store holds (new export). If that read fails, skip the sweep as above.
  2. Take the `open` and `queued` entries. Leave alone any whose id, or whose run key, the retry store holds.
  3. `queued` entries become `interrupted`: OpenClaw's follow-up queue does not survive a restart (T0b B2).
  4. Group the remaining `open` entries by conversation and read that conversation's OpenClaw session entry once (classifier below):
     - **Recovery pending:** the entries become `settled`, logged `yorozu: turn left to OpenClaw recovery <messageId>`. No report. If OpenClaw resumes, its reply arrives through the outbound path; if it doesn't, the device waits out the awaiting window.
     - **Nothing pending:** the entries become `interrupted`, logged `yorozu: turn interrupted by restart <messageId>`.
     - **Unknown:** the entries become `settled`; one warning `yorozu: restart recovery state unreadable, not marking interrupted: <reason>`.
  5. Write the marker.
- **No automatic rerun (decision 5).** The sweep never queues, parks or runs anything.
- **Recovery classifier.** One adapter function, the only code that knows OpenClaw's field names. Input: the conversation's session entry from the SDK's `getSessionEntry` (a plugin projection that strips private fields such as `mainRestartRecovery`). Checked in this order; the first match wins:
  1. **Unknown** if the read throws, or a field below is present with another type than listed.
  2. **Nothing pending** if there is no entry.
  3. **Recovery pending** if `abortedLastRun` is true or `status` is `"interrupted"`. OpenClaw's start-up marking sets these when it takes custody of a cut-off run, and it runs before any channel starts (T0b B3). Custody then often shows only in the private field, so these two public fields are the signal that covers "queued for recovery".
  4. **Recovery pending** if a `restartRecoveryRuns` run id is not in `restartRecoveryTerminalRunIds`, or `restartRecoveryDeliveryRunId` is set, or `pendingFinalDelivery` is set: OpenClaw is resuming or delivering (its own claim check, minus the private field).
  5. Otherwise **nothing pending**.
  This leans toward at-most-once: a session OpenClaw marked but will not resume (retry budget spent, or tombstoned) also reads as pending, and its device waits out the awaiting window.
- **Session-open report.** In the per-device `peer_info` hook, after the read cursors, to that device only:
  1. Interrupted runs: group `interrupted` entries by run key (own id when none). Keep runs with `interruptedAt` within 24 h and later than this device's watermark. Newest first by `interruptedAt`, then `at`; at most 100 runs; older ones are dropped for this device. For each run: `typing {convId, active: false}`, left out when a run is executing in that conversation, then one interrupted error whose `messageId` is the run's last user message (latest `at`). Resend in the app therefore sends that message (Q3).
  2. `run_started` for each conversation with a run executing in this process (`runningTurns`; not parked, not preparing).
  3. Set this device's watermark (namespace `run-told`, key = the device's public signing key as the allowlist stores it, value = the newest `interruptedAt` considered) and write it through.
- **Once per device.** Interruptions come only from sweeps, so one watermark per device replaces per-entry device lists. A lost send (the session drops at that moment) leaves the device on the awaiting window. A repeat, from the duplicate path or a failed watermark write, is harmless: the app's error row has a fixed id per message.
- **Live Activity.** No change.

### Module interfaces (sketch; names may change, shapes may not)

```ts
// ledger.ts (new, imports node built-ins, envelope types and the runtime store)
type RunState = "open" | "queued" | "settled" | "interrupted";
type RunRecord = { convId: string; state: RunState; at: number; run?: string; interruptedAt?: number };
export function loadLedger(store?: Keyed<RunRecord>): Promise<"loaded" | "degraded">;
export function claim(message: Message): "fresh" | Event[];   // Event[]: send to that device only
export function runStarted(messageId: string, awaiting: boolean): void;
export function dispatchReturned(messageId: string, deferred: unknown, runningKey: string | undefined): void;
export function turnEnded(messageId: string, parked: boolean): void;
export function sweep(opts: { parked: () => Promise<Set<string>>; recovery: (convId: string) => Recovery; bootId: string }): Promise<void>;
export function report(deviceKey: string, executing: (convId: string) => boolean): Promise<Event[]>;
// recovery.ts (new): type Recovery = "pending" | "none" | { unknown: string };
export function classifyRecovery(entry: unknown): Recovery;
// retry.ts: export function parkedMessages(): Promise<Set<string>>;   // rejects when unreadable
// history.ts: export function findUserMessage(agentId: string, sessionKey: string, messageId: string): "found" | "missing" | "unreadable";
// hub.ts HubOptions: claim?: (message: Message) => "fresh" | Event[];
// relay.ts RelayHostOptions: claim?: HubOptions["claim"]; sessionOpen?: (deviceKey: string) => Promise<Event[]>;
```

The Hub and relay modules don't import the ledger or the conversation module; `startAccount` passes the callbacks. Hub tests inject a fake store the way the card store tests do.

### Wire (contract docs only; no new kind, field or capability)

- `run_failed` gains one documented reason: `message` exactly `interrupted by a host restart` means a restart cut the run off and it will not run again by itself. A client may show its own text and offer Resend for it. Every other `run_failed` keeps its meaning.
- This is not "new behaviour" under the capability rule (`OWNER_DECISIONS.md`): every event sent is an existing kind used with its existing meaning (the run for that message failed; a run started; typing stopped), which every shipped client already handles. Only the iOS app's new row reads the text, and an older host never sends it.
- The dedupe promise changes from "24 h, up to 10,000, in memory" to the same bounds across restarts, with the limits in "Promises and their limits".
- The session-open report is documented next to the read cursors that already follow `peer_info`.
- Old peers: an older iOS app shows "The agent run failed: interrupted by a host restart"; the Windows app flags the user message as failed, which ends its wait.

### App: Interrupted row and Resend (ticket 03)

- **Recognising it.** An `error` with code `run_failed`, `message` equal to the constant, a conversation id and a message id. The existing error path still runs: the message is marked rejected if below `delivered`, the row `error:<messageId>` is appended once, and typing stops (which clears the stall banner and the awaiting state).
- **Unknown conversation.** An interrupted error for a conversation the app doesn't hold is ignored, so a late report never recreates a conversation deleted on another device.
- **Row state.** `ChatItem` gains one persisted optional field `resend: ResendState?` with `offered`, `sent` and `unavailable`. `offered` when the row is made and the app holds the original user message; `unavailable` when it doesn't (another device sent it and history hasn't reached this one). Rows with any `resend` value are kept by the stray-error cleanup that runs on cache load. Older builds ignore the field.
- **Row text.** `item.text` holds "Interrupted: the host restarted during this reply." (Siri and older builds read `text`). The row shows a Resend button while `offered`, and "Resent" with no button once `sent`. New strings go into `Localizable.xcstrings` in all nine shipped languages (en, ja, zh-Hans, zh-Hant, ko, es, fr, de, pt-BR).
- **Resend.** A model method takes the row: it appends a new user item with a fresh id, the original's text, its stored `replyTo`, and its attachments that uploaded (`uploaded = true`; ones with a failure are dropped; shared ids are protected from discard), sends it through the normal outbox, and sets the row to `sent`. A second tap does nothing. Nothing is sent without the tap. The existing `send` gains an overload that takes a stored `ReplyTo`.
- **Other devices.** Each device shows its own Resend; two devices can each resend once (two deliberate taps; accepted).
- **Unchanged.** Siri's wait ends on an `.error` item; `needsAttention` turns on, as for any failed turn.
- **Cost of Q3.** Resend sends only the run's last message; an earlier message folded into the same run is not resent. Accepted by Q3.

## Testing decisions

- **Seams, highest first.**
  - Hub: the existing fake host and Noise device harness (`hub-host`), with an optional injected `claim`. A restart is a new Hub over a ledger reloaded from the same fake keyed store.
  - Conversation and ledger writers: the existing stand-in host for OpenClaw (`genui-hooks` mapping runtime and friends to `genui-host.js`). Extend its fake keyed store, don't copy it: no eviction when `maxEntries` is undefined (today it would wipe the retained `retry` store), an `entries` failure mode, a write recorder, a slow mode, and reopen. Clock and boot id are injected. The stub's dispatch gains a way to return `dispatchResult.deferredToActiveRun` and to fire `onAgentRunStart` after the dispatch returned (a follow-up).
  - Retry interplay: a resolve hook scoped to the module under test that loads the **real** retry module while runtime stays the stub, with `node:test` mock timers for the 5 s tick. (`prerun-error` stubs the retry module; this extends that precedent.)
  - Start order: recording stubs for the retry and relay modules on the existing `startAccount` test base in `presentations.test.ts`.
  - Recovery classifier: plain unit tests on entry objects, plus one pin test against the real OpenClaw 2026.9.8 SDK (runs when `YOROZU_OPENCLAW_SDK` points at an installed package, as `conversation-owner` does; skipped in CI; Coder runs it locally and quotes the output in the PR).
  - App: `ModelHarness` with `ScriptedTransport`. `ScriptedTransport.send(_ message:)` records nothing today; ticket 03 adds a `sentMessages` list.
- **What a good test checks:** events each device receives, whether `onMessage` ran, log lines, the store's rows after a reload, the app's items and sent messages. Not private maps.
- **Prior art:** `hub-events`, `hub-session` (Hub); `genui-golden`, `prerun-error` (conversation); `activitywatch` U6/U7 (Live Activity restore); `AppModelSyncTests` (app); `presentations.test.ts` (`startAccount`).
- **Red tests, ticket 01** (the PR's first code commit holds only red tests; the PR body names each and its failure on the parent):
  1. A new Hub over a reloaded ledger gets M again: `onMessage` ran once; `delivered` went out both times; one `duplicate message skipped (settled)`.
  2. A duplicate of M while M's run executes sends `run_started` once, to that device only.
  3. Degraded ledger, transcript holds M: M doesn't run.
  4. Degraded ledger, transcript read fails: M runs; `run ledger transcript check failed` logged.
  5. Writer table: park leaves `open`; the outer `finally` writes `settled`; a pre-run failure writes `settled`.
  6. Steer: M1 starts, M2's dispatch returns `deferredToActiveRun: "steer"`: M2 is `open` with run M1; M1's end settles both.
  7. Follow-up: M2's dispatch returns `"followup"`: M2 is `queued`; M2's later `onAgentRunStart` settles it and earlier queued entries of that conversation.
  8. Follow-up whose start fires before its dispatch returns stays `settled`.
  9. Writes for one id land in call order with a slow store; a failed write logs and the turn completes.
  10. Entries older than 24 h are dropped on load; the map stays within 24 h and 10,000 on claims.
  11. Degraded ledger: a second copy of M in the same process is a duplicate without a transcript read.
  12. Guards: relay and direct copies of M arriving together run once; without `claim` the Hub behaves as before; the legacy plugin sequence tests run unmodified.
- **Red tests, ticket 02:**
  1. An `open` entry from an earlier process, not parked, nothing pending: `interrupted`, logged once.
  2. A parked id, and an entry steered into a parked run, stay `open`; the real retry loop still reruns the parked one on its schedule.
  3. A second `startAccount` in the same process sweeps nothing.
  4. A retry-store read failure, a marker read failure, and a degraded ledger each skip the sweep and write no marker.
  5. Start order: stores → ledger → sweep → `watchSessions` → retry loop → relay host.
  6. A run cut off by a simulated restart gives each of two devices exactly one `typing false` and one interrupted error, after the read cursors, to that device only; a reconnect and a second simulated restart send that device nothing more.
  7. At most 100 runs per report; runs older than 24 h are skipped.
  8. A run executing now gets `run_started` in the report, after the errors; a parked or preparing turn does not.
  9. A duplicate of an `interrupted` message gets `delivered` and the interrupted error for its run's last message, and doesn't run.
  10. Recovery pending, one test each: `abortedLastRun: true`; `status: "interrupted"`; a non-terminal `restartRecoveryRuns` run; a `pendingFinalDelivery`. Entries become `settled`, `left to OpenClaw recovery` is logged, nothing is reported.
  11. Nothing pending: no entry, and an entry with only terminal recovery runs: `interrupted`.
  12. Unknown shape: `restartRecoveryRuns` as a string, and a throwing read: `settled`, one warning, nothing reported.
  13. Two steered messages, one run: M1 starts, M2 steered into it, restart: each device gets exactly one `run_failed`, for M2, and one `typing false`.
  14. Queued follow-up M2 behind M1, restart, recovery pending for the conversation: M1 `settled`, M2 `interrupted`; each device gets one error, for M2.
  15. Pin test (OpenClaw 2026.9.8, SDK-gated): the real `getSessionEntry` returns `abortedLastRun`, `status`, `restartRecoveryRuns`, `restartRecoveryTerminalRunIds`, `restartRecoveryDeliveryRunId` and `pendingFinalDelivery` with the types the classifier expects, and the real dispatch result type carries `deferredToActiveRun` (also checked by the full plugin typecheck).
  16. Guards: an interrupted turn's Live Activity job still ends on restore; a device with no interrupted runs gets only the read cursors.
- **Red tests, ticket 03:**
  1. An interrupted error appends one Interrupted row with Resend and clears typing, stall and awaiting for that conversation.
  2. The same error again adds no row and keeps a `sent` state.
  3. Resend sends exactly one new message (new id; same text, `replyTo` and uploaded attachment ids); the row shows "Resent" with no button; a second tap sends nothing.
  4. Nothing is sent without the tap, across a reconnect.
  5. The row state survives a relaunch (store round trip), including an `unavailable` row whose message the app doesn't hold.
  6. An interrupted error for an unknown conversation creates nothing.
  7. A `run_failed` with any other message keeps the old row with no Resend.
  8. The new strings exist in all nine languages (a test that loads `Localizable.xcstrings` and checks the keys).
- **Acceptance commands** (Node 26, as CI):
  - `node --test 'plugins/openclaw-yorozu/test/*.test.ts'` from the repo root.
  - `tsc -p plugins/openclaw-yorozu/tsconfig.standalone.json` (as `plugin-typecheck.yml`), and the full plugin typecheck against the OpenClaw checkout with no errors in plugin files.
  - `node apps/mcp/scripts/generate.ts` then `--check` (the `@yorozu/help-mcp` `check` script) whenever a top-level docs file or the plugin README changes.
  - App: `tuist generate --no-open --path apps/ios`, then `xcodebuild test -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuTests -destination 'platform=macOS'` (as `checks.yml`), and `swift test --package-path packages/YorozuWire`.

## Alternatives considered

- **The v4 shape: a new `turn_state` event, a `turnState` capability, a `resendOf` field and a host-side Resend guard.** Not taken (A1(b)). `error run_failed` already ends the wait on every shipped client.
- **Automatic requeue after a restart.** Withdrawn by decision 5.
- **T0 option (c): opt Yorozu turns out of OpenClaw's restart recovery.** Not available: OpenClaw 2026.9.8 has no per-channel or per-run opt-out (T0b B4). Q1 (b) was chosen instead.
- **T0 option (d): measure first, build later.** Not taken: the owner chose to fix S1–S4 now (brief).
- **Relying on OpenClaw's own message dedupe.** Not possible: it is memory-only (T0 answer 2).
- **A per-entry boot id instead of one sweep marker.** Not taken (K3).
- **Waiting for the store write before `delivered`.** Not taken: it changes ✓✓ from "received and decrypted" (`OWNER_DECISIONS.md`) and adds an async step to close a gap of milliseconds.
- **A new distinguishing field on `error`.** Not taken: tolerant readers would ignore it, but it is still a wire change the brief rules out (A1(b), "no YorozuWire change").
- **A complete "still running" listing with the app's unlisted rule.** Deferred (Further notes).
- **Transcript only, no store.** Not taken: queued messages aren't in the transcript. Kept as the degraded fallback (decision 3).
- **Removing the Hub's in-memory list and requiring a ledger.** Not taken: the legacy sequence tests must run unmodified, and they build a Hub without one.

## Risks

| Risk | Mitigation or check |
|---|---|
| A restart in the milliseconds between the claim and its store write loses the entry | Accepted: that message behaves as before the change. Measured by `duplicate message skipped` against restarts. |
| A failed `settled` write leaves an `open` entry the next restart marks interrupted | Logged; target 0. The owner sees a row for an answered run and need not resend. |
| The store can't be read at start-up | Degraded mode with the transcript fallback; no sweep; logged. |
| OpenClaw resumes a cut-off run (T0 answer 1) | The classifier reads OpenClaw's markers and stays silent (Q1 (b)). |
| OpenClaw marks a session it then won't resume (budget spent, tombstone) | No Interrupted row; the device waits out the awaiting window (fail-safe direction). |
| OpenClaw renames or reshapes the fields | The shape check fails safe with a warning; the pin test fails against the new version. |
| A follow-up starts and the restart cuts it off | It was settled at its start, so no row; OpenClaw's marking usually covers it as a normal run. Accepted for at-most-once. |
| OpenClaw drops a queued follow-up over its queue cap | Settled when a later queued message starts; no row (same as before the change). |
| A steered message whose run is parked and whose text didn't reach the transcript | Not replayed by the rerun; settled with the run. Accepted, rare (a steer returns after its transcript commit). |
| Rollback, then re-deploy | Entries the old plugin finished stay `open`; the re-deployed plugin's first sweep classifies them (most read as settled through recovery markers or a reply). Accepted. |
| A session reset between the message and a degraded transcript check | The check reads the new session and answers "missing": the message runs. Degraded mode only. |
| Message ids stored on disk | Ids, conversation ids, states and times; no message text. |
| Two devices both tap Resend | Accepted (two deliberate taps). |
| Report size | At most 100 errors and 100 `typing` events, about 200 bytes each. |

## Out of scope

- S3 and S5–S8; relay, pairing, timestamp and Live Activity format changes; Windows sync tests.
- Automatic rerun after a restart; typing for queued turns from other devices.
- Release, TestFlight and merges: draft PRs only.

## Further notes

- **Deferred (Yorozu (the agent), 2026-11-19 11:21 JST): decision 1's app-side "unlisted" rule.** A run the app shows as running but the host doesn't list is not marked interrupted: A1(b) has no listing event. The host side of decision 1 stays. The case it covered keeps the awaiting window and is measured by `run ledger unavailable` (target 0).
- **Owner-confirmed items:** the accepted choices in "Referenced decisions" were accepted by Yorozu (the agent) under the brief's delegation; none changes an owner rule.
- **T0 answers** (OpenClaw 2026.9.8, read only):
  1. Can OpenClaw resume a cut-off Yorozu turn after a restart? Yes, through main-session restart recovery, delivering through the outbound adapter.
  2. Is OpenClaw's message dedupe durable? No, memory-only.
  3. Does each message get its own run? No: `steer` (default) folds into the active run; a follow-up queue runs later.
  4. Does a parked rerun append the user message twice? No.
  5. Does a `channels.yorozu` reload reload the module? No, it reuses it.
  6. Does `onToolStart` fire before the tool runs? No guarantee (unused here).
  7. Keyed store API? `register`/`delete`/`entries`/`lookup`, `evict-oldest` or `reject-new`, awaited transactional writes.
- **T0b answers** (OpenClaw 2026.9.8, read only, asked after EGM round 1):
  - B1. Steer: the dispatch returns after the transcript commit with `deferredToActiveRun: "steer"` and no own run start. Follow-up and collect: it returns at enqueue with `"followup"`; the message's own `onAgentRunStart` fires later, possibly after the dispatch returned; a collected batch fires only its last item's; the reply goes through the outbound adapter.
  - B2. The follow-up queue is per process and lost at a restart; a committed steer is part of the resumed transcript.
  - B3. Start-up marking finishes before any channel's `startAccount`. It sets the private custody field plus `abortedLastRun = true` and usually `status = "interrupted"`, without a public run fence; so custody can show only privately apart from those two fields. No SDK helper reports custody.
  - B4. No opt-out from restart recovery for a channel or run.
  - B5. `runningTurns` names the executing run per conversation; a parked turn is not in it.
- **Measures (Yorozu (the agent), for 2 weeks after the Release Mac build that ships ticket 02):** `rg 'yorozu: (run started|duplicate message skipped|turn interrupted by restart|turn left to OpenClaw recovery|restart recovery state unreadable|run ledger|restart sweep)' ~/.openclaw/logs/`.

| Log line | Target |
|---|---|
| `run started <id> attempt 0` for one id under two boot ids | 0 |
| `run ledger write failed` | 0 |
| `run ledger unavailable`, `run ledger transcript check failed` | 0 |
| `restart sweep skipped` | 0 |
| `restart recovery state unreadable` | 0 (any line: the classifier needs an update) |
| `turn left to OpenClaw recovery` | each followed by a reply in that conversation within 10 minutes |
| `turn interrupted by restart` | each within a minute after a line in `~/.openclaw/logs/gateway-restart.log` (an unmatched one is a bug) |

- **Release triggers:** the docs PR triggers nothing. The plugin PR (tickets 01 and 02) starts Release Mac, and Deploy website if the contract, a top-level doc or the plugin README changes the help bundle. The app PR (ticket 03) starts Release Mac and Release iOS.
- **Rollback:** revert the PR. An older plugin ignores the `runs`, `run-sweep` and `run-told` namespaces; an older app shows interrupted errors as plain failed-run rows.
