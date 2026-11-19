# Sync restart durability (S1, S1b, S2, S4; shape A1(b))

- **Status:** draft v3. EGM rounds 1 and 2 addressed, except CA-6 and CA-7, which wait for their decision owners ("Pending decisions" in Further notes). T0 and T0b answered. Yorozu (the agent)'s T0 decisions recorded 2026-11-19 11:21 JST.
- **Brief:** box handover `inbox/coder/20261119-1104-yorozu-yorozu-sync-restart-durability.md` (Tier: feature). The box is the shared Linux machine the bots use; its handover folder is `/home/box/handover`.
- **Source spec:** box handover `transfers/20261119-yorozu-sync-stability-spec.md` (v4, with §9 owner decisions 1–6) and its EGM round 4 report.
- **Baseline:** `origin/main` at `8a278a5c`.
- **Roles:** the *owner* is the person who uses the app. *Yorozu* means the product unless written "Yorozu (the agent)": the agent that holds the product's delegated decisions and wrote the brief. *Coder* is the agent that wrote this spec and runs the implementation. *The OpenClaw agent* is the model run that answers the owner's messages. Owner decisions live in `OWNER_DECISIONS.md`; Yorozu (the agent) decides only what the brief delegates.
- **Review terms:** *EGM* is the multi-stage spec review this draft went through; its findings are cited as CA-n (action items) and CN-n (nits). *T0* and *T0b* are Coder's read-only source readings of OpenClaw 2026.9.8, answered in Further notes.

## Problem

The OpenClaw Gateway on the owner's Mac mini restarted five times between Nov 2 and Nov 12 (count from the source spec). Yorozu's host plugin runs inside it. Several plugin stores survive a restart (`retry`, `replies`, `reactions`, `attachments`, `message-times`, `read`, `devices`, and the upload spool). What the plugin knows about which messages it accepted and which turns are running is in memory only, and a restart loses it. No double run or lost message has been traced to a restart yet. This fix is preventive, for cases the source spec found by reading the code:

- **S1. A message can run twice.** The host answers `delivered` and drops repeats with an in-memory list of message ids. A restart clears the list. A device that never got `delivered` resends the message in its next session, and the OpenClaw agent runs it again.
- **S1b. A queued message can vanish.** A message that was waiting in OpenClaw's follow-up queue behind another turn is lost when the Gateway restarts (T0b B2). The device already shows ✓✓, so it never resends it, and nothing tells it.
- **S2. A cut-off turn ends late.** A turn the restart cut off ends on the devices only when the app's 10-minute awaiting window runs out, unless OpenClaw resumes it. Nothing offers to send the message again.
- **S4. A late joiner doesn't see "working…".** A device that opens a session in the middle of a turn shows nothing until the next typing keepalive (up to 8 s) or the next event.

**What stays unsolved in S2.** In the common case OpenClaw marks a cut-off run for its own restart recovery (T0b B3). This design then sends no Interrupted row: the turn ends with OpenClaw's recovery reply or, if OpenClaw doesn't resume it, with the 10-minute window, as today. Only cut-off runs that the host reads as not held by OpenClaw get a row.

S3 (the source spec's history-gap case) and S5–S8 are a later spec.

## Goals

1. A message the host accepted runs at most once across restarts, within the bounds in "Promises and their limits".
2. A run a restart cut off, that the host reads as not held by OpenClaw's restart recovery, ends with an Interrupted row and a Resend button on each device at that device's next session open, if that open is within 24 h of the restart. Exclusions are listed in "Promises and their limits".
3. The host adds no new rerun. After a restart it reruns only what the existing auto-retry rule parked. A Resend runs only on the owner's tap, and it is offered only for runs the host read as not held by OpenClaw.
4. A device that opens a session while a run started by this host process is executing shows that run as running at once. Exclusions are listed in "Promises and their limits".
5. Shipped apps, the Windows app and older hosts keep working without a new event kind, field or capability.

Non-goals: S3 and S5–S8; automatic rerun after a restart; typing for queued turns; relay, pairing and Live Activity changes (full list in Out of scope).

## Solution

- **Run ledger.** The host keeps a durable record per message id, written when the message is accepted. A repeat of a recorded message id gets `delivered` and does not run again, also after a restart.
- **Start-up sweep.** Once per process, at start-up, the host looks at every message an earlier process accepted and never settled. It leaves alone what the auto-retry rule holds, what OpenClaw's restart recovery holds or may hold, and conversations with no OpenClaw session. It marks the rest **interrupted**. When it can't tell, it marks nothing: at-most-once wins over liveness.
- **Session-open report.** When a device opens a session, the host sends that device each interrupted run it hasn't been told about (last 24 h, newest first, at most 100). It re-reads OpenClaw's session state for each run just before sending and drops runs OpenClaw now holds. For each run it sends `typing false` and the existing `error run_failed` event with a fixed reason text, for the run's last user message. It then sends `run_started` for each run executing now.
- **App.** The app shows that error as an **Interrupted** row with a **Resend** button and stops waiting. Resend sends the original's text, attachments and quoted message again as a new message with a new id. Nothing is resent without the tap.
- **Older peers.** An older host never sends the report. An older iOS app shows a plain failed-run row; the Windows app flags the message only if its conversation is open or the message is in its outbox. "Older clients" below has the full list, including the costs.

## Promises and their limits

**Goal 1 (at-most-once)** holds for a message id within 24 h and the latest 10,000 messages, once its ledger write has landed. The write starts right after `delivered`; it normally lands within milliseconds but can queue behind other store writes (`docs/openclaw-channel.md:49`); this is not measured. It does not hold:

- in degraded mode (the ledger store can't be read at start-up): a message still in OpenClaw's queue is not in the transcript, and a failed transcript read runs the message;
- for a claim whose store write failed (logged, target 0);
- for a restart between `delivered` and the write landing.

**Goal 2 (Interrupted row) excludes** the cases below. The first two apply to runs that had started or were preparing; a message lost from OpenClaw's queue gets its row in both.

| Case | What the device gets instead |
|---|---|
| OpenClaw marked the session for recovery (the common case), whether or not it then resumes | OpenClaw's recovery reply, or the 10-minute window |
| The session state can't be read or has an unknown shape | The 10-minute window |
| The conversation has no OpenClaw session entry (deleted, or never recorded) | Nothing (deleted) or the 10-minute window |
| A follow-up that started from OpenClaw's queue and was then cut off | The 10-minute window (settled at its start; no end signal) |
| Runs beyond the newest 100 for that device | The 10-minute window |
| Degraded mode, a skipped sweep, or a failed `interrupted` write | The 10-minute window |
| The report's send is lost (the session drops at that moment) | The 10-minute window |
| The device doesn't hold the original message yet | An `unavailable` row; Resend appears once history brings the message |
| The device opens its first session more than 24 h after the restart | Nothing |

**Goal 4 (run_started at session open) excludes:** follow-up runs (started after their dispatch returned), runs OpenClaw's restart recovery started, parked turns waiting for a retry, and turns still preparing (attachments, media) before their run starts. These keep today's behaviour: the device learns from the next event.

**Resend** can still cause a double run when OpenClaw recovers a run after the host marked it interrupted and the report's re-check didn't see it (Risks). This is measured.

## User stories

1. As the owner, I want a message the host already accepted to run at most once even if the Gateway restarts, so that the OpenClaw agent doesn't do the same work twice.
2. As the owner, I want a message my device resends after a restart (because it never got ✓✓) to get ✓✓ and not run again, so that a flaky connection costs nothing.
3. As the owner, I want a run that a restart cut off, and that OpenClaw is not holding for its own recovery, to show an "Interrupted" row instead of "working…" on each device that opens a session within 24 h, so that I know the reply is not coming.
4. As the owner, I want a message the restart caught while it waited in OpenClaw's queue to show an "Interrupted" row too, so that nothing I sent vanishes silently.
5. As the owner, I want a turn that OpenClaw resumes by itself to just deliver its reply, with no Interrupted row, so that I can't cause a double run.
6. As the owner, I want one Interrupted row per cut-off run, even when several of my messages were folded into that run, with Resend sending the last of them. The earlier folded messages reached the transcript, so the OpenClaw agent sees them when it answers the resent one.
7. As the owner, I want a Resend button on that row that sends the same text, attachments and quoted message as a new message, so that I can get the answer with one tap.
8. As the owner, I want the host never to rerun a cut-off message by itself, beyond the existing auto-retry rule, so that the OpenClaw agent never repeats an action without my tap.
9. As the owner, I want the row to say "Resent" with no button after I tap Resend on this device, so that I don't send it twice by accident.
10. As the owner, I want a run that fails for a temporary reason (a plugin reload, an overloaded or rate-limited model) before any reply or tool call to be retried after 5, 15, 30, 60 and 120 s, as before, including across a restart, so that brief outages fix themselves.
11. As the owner, I want a device that connects while a run this host process started is executing to show it as running at once, so that I don't send the message again.
12. As the owner, I want an Interrupted row to keep its state across app relaunches, and a repeat of the same error to change nothing, so that rows don't pile up or come back after I resent.
13. As the owner using an older iOS build or the Windows app, I want an interrupted run to end my wait where that app can show it, so that those apps need no update.
14. As the owner, I want a plugin reload (a `channels.yorozu` config change) to mark nothing interrupted, so that a reload, which is not a restart, never offers a Resend for a running turn.
15. As the owner, I want the host to keep working when its store fails, falling back to the transcript to spot repeats, so that a store failure never fails a turn.
16. As Yorozu (the agent), I want the log lines listed in Further notes, so that I can check the targets for two weeks after release.

## Implementation decisions

### Referenced decisions

| Label | Who and where | What it says |
|---|---|---|
| A1(b) | Yorozu (the agent), brief | Report cut-off runs with the existing `error run_failed`; no new event, field or capability; no `resendOf`. Under review: CA-7 (Pending decisions). |
| Decision 1 | Owner, source spec v4 §9 | The host tells devices which turns were interrupted and which are running. Its app-side "unlisted" half is deferred (Further notes). |
| Decision 3 | Owner, source spec v4 §9 | Dedupe falls back to the transcript when the store fails. |
| Decision 5 | Owner, source spec v4 §9 | No automatic rerun after a restart; the auto-retry rule (`retry` store) is unchanged. |
| Q1 (b) | Yorozu (the agent), 2026-11-19 11:21 JST, final | Skip turns OpenClaw is resuming or has queued for recovery; fail safe toward at-most-once on an unknown shape; pin the fields with a test against OpenClaw 2026.9.8. |
| Q3 | Yorozu (the agent), 2026-11-19 11:21 JST, final | One Interrupted row per cut-off run, keyed by run, for the run's last user message. |
| Agent-accepted choices | Yorozu (the agent), 2026-11-19 11:21 JST | The fixed message; Resend only on interrupted rows; `typing false` plus the error once per device on its next session open; the once-per-process sweep marker; the 100-run cap; skipping the sweep when the retry store can't be read; the reason constant kept in each side's code. |
| K3 | Source spec EGM round 4 | A per-entry process id races with reloads; use one sweep marker. |

### How a message flows (context)

- **Host, plugin, Hub.** The *host* is the owner's Mac running the OpenClaw *Gateway* (the OpenClaw process). Yorozu's *plugin* (`plugins/openclaw-yorozu`) runs inside it. Its *Hub* (`src/hub.ts`) holds one encrypted *device session* per connected device.
- **Relay and direct paths.** A device reaches the Hub through the relay (`apps/relay`) or, on the same network, through the plugin's direct listener. A device can have both open for a moment, so one message can arrive twice, once on each path.
- **Device → Hub.** A device session starts with the device's `peer_info` event (its name and capabilities). The Hub then answers the device with read cursors. For each `message` event it broadcasts `delivered` (✓✓) and hands the message to the conversation module (`src/conversation.ts`).
- **Conversation module → OpenClaw.** For each message (`handleMessage`) it resolves the conversation's OpenClaw session (one per conversation, with the conversation id as thread id), awaits OpenClaw's inbound dispatch (`runChannelInboundEvent`), and turns OpenClaw's callbacks into `typing`, `run_started`, `tool`, `reply` and `error` events.
- **OpenClaw** runs one agent run per session at a time. A message arriving during a run is, by the session's queue mode, either *steered* into the running run (the default; the dispatch returns once the message is in the transcript) or put in OpenClaw's per-process *follow-up queue* (the dispatch returns at once; the run starts later). *Collect* mode merges several queued messages into one later run (T0b B1). On a restart, OpenClaw marks sessions whose run was cut off and may resume them itself ("restart recovery", T0 answer 1). Its follow-up queue is lost (T0b B2).

### Glossary

| Term | Meaning |
|---|---|
| Restart | The Gateway process stops and starts (an update, `openclaw gateway restart`, or a crash). A plugin reload (`startAccount` again in the same process) is not a restart. |
| Boot id | `"<pid>:<Math.round(performance.timeOrigin)>"`: the same across plugin reloads and module re-imports, new after a restart. |
| Turn | The host's handling of one message: one `handleMessage` call. |
| Run | One OpenClaw agent run. Several turns can share a run (steer, collect). Its **run key** is the message id whose `onAgentRunStart` fired for it. A message steered into an executing run takes that run's key. A message that never started or joined a run is its own run. |
| Executing | A run is executing only while the turn whose `onAgentRunStart` started it is still awaiting its dispatch. It stops in that turn's `finally`. A follow-up run is never executing (its start fires after its dispatch returned, or its dispatch returns while it runs on). |
| Run ledger | The host's record of accepted messages, keyed by message id. In memory, loaded once per process, written through to keyed-store namespace `runs`. |
| Ledger states | `open`: claimed, preparing, executing, steered into an executing run, or parked. `queued`: OpenClaw put it in its follow-up queue and it hasn't started. `settled`: the host will neither run nor report it (answered, failed, gone, started from the follow-up queue, steered into a run that isn't executing, left to OpenClaw, or not classifiable). `interrupted`: the start-up sweep found it cut off by a restart. |
| Parked | A turn that failed for a temporary reason before any reply or tool call and waits in the `retry` store for its next attempt (the owner's auto-retry rule). |
| Recovery pending | OpenClaw's restart recovery has, or may take, custody (ownership) of the conversation's session (classifier below). |
| Tombstoned | OpenClaw's end state for a session whose recovery it gave up on. |
| Start-up sweep | The one pass per process that settles or interrupts entries an earlier process left `open` or `queued`. |
| Sweep sequence | A number each sweep that marks anything takes, one higher than any before. Stored with the marker and on each entry it marks. |
| Session-open report | What the host sends one device right after its `peer_info`: read cursors (existing), then interrupted runs that device hasn't been told about, then `run_started` for executing runs. |
| Interrupted error | `error {code: "run_failed", message: "interrupted by a host restart", convId, messageId}`. The `message` string is a constant each side keeps in its own code. |
| Interrupted row, Resend | The app's row for an interrupted error, and the owner's tap on it that sends the original again as a new message. |
| Awaiting window, stall banner | The app's 10-minute limit on waiting for a reply, and the banner it shows when a running turn makes no progress for 5 minutes. |
| Degraded mode | The ledger store couldn't be read at start-up; the transcript check stands in for it. |
| Transcript check | A synchronous read of the conversation's OpenClaw transcript for a user message with that transport message id. |
| Target 0 | The measure's target: the log line should never appear. |

### Host: run ledger (ticket 01)

**Record** (`RunRecord`), per message id:

| Field | Meaning |
|---|---|
| `convId` | The conversation. |
| `state` | `open`, `queued`, `settled` or `interrupted`. |
| `at` | Host receipt time, ms. Never sent to devices. |
| `run?` | The run key, once known. |
| `interruptedAt?` | Wall-clock time of the sweep that marked it. |
| `sweep?` | The sweep sequence that marked it. |
| `queued?` | `true` on an `interrupted` entry that was `queued` when swept. OpenClaw's recovery can't hold such a message (T0b B2). |

**Store.** Namespace `runs`, `{maxEntries: 10_000, overflowPolicy: "evict-oldest"}`, like `replies`. Each id's writes go through one promise chain, so they land in call order. A failed write logs `yorozu: run ledger write failed: <error>` and never fails a turn.

**Pruning.** On load, entries are dropped from the map and deleted from the store when older than 24 h, measured from `interruptedAt` for `interrupted` entries and from `at` for the rest. On each claim the map drops entries past the same age and the oldest beyond 10,000, as the Hub's id list does now. The store's `defaultTtlMs` is not used: it counts from the last write, and every state change rewrites the entry, so it can't express "24 h from receipt" or "24 h from marking".

**Claim (synchronous)**, on every `message` event in the Hub, before `delivered`:

1. The Hub calls the injected `claim(message)`.
2. Unknown id: a new `open` entry goes into the map, its store write starts without being awaited, and `claim` returns `"fresh"`.
3. Known id: `claim` logs `yorozu: duplicate message skipped (<state>)` and returns `"duplicate"`.
4. The Hub broadcasts `delivered` in both cases. It runs a fresh message (`onMessage`) and does nothing more for a duplicate, as `hub.ts` does today. The device catches up from the session-open report and from history.

**Writers.** These are the only places that change state. A writer for an id the map lacks (a parked message whose entry was pruned) first inserts it `open` with `at` = now.

| # | When | Change |
|---|---|---|
| 1 | Claim | `open`. |
| 2 | `onAgentRunStart` for X, while X's turn is awaiting its dispatch | X `open`, `run = X` (also when it was `queued`). The run is executing from here. |
| 2b | `onAgentRunStart` for X after X's dispatch returned (a follow-up from the queue) | X `settled`, and every earlier `queued` entry of that conversation too (a collected batch fires only its last item's start; T0b B1). Not executing. No end signal comes for it. |
| 3 | X's dispatch returns `deferredToActiveRun: "steer"` | If a run R ≠ X is executing in X's conversation: X `open`, `run = R`. Otherwise `settled` (it joined a follow-up run or one that already ended). |
| 3b | X's dispatch returns `"followup"` | If X's run already started (writer 2 ran): `settled` (it runs on detached). Otherwise `queued`. |
| 3c | X's dispatch returns no `deferredToActiveRun` | No change (writer 4 settles it). |
| 3d | Any other value | `settled`; warns `yorozu: unknown dispatch deferral <value>, settled <messageId>`. |
| 4 | X's outer `finally`, when X isn't parked | X `settled` (reply, reported failure, pre-run failure, or gone), unless X is `open` with another run key (steered) or `queued`. Settling X also settles every `open` entry whose `run` is X. |
| 5 | X parked | X and the entries steered into its run stay `open`. The rerun starts X again (writer 2) and its `finally` settles them together. A steered message is replayed by the rerun only if it reached the transcript before the failure. A steer's dispatch ordinarily returns after its transcript commit (T0b B1), but this is not guaranteed and is not measured. |

**Executing signal (CA-1).** `runningTurns` (`conversation.ts:81,288,308`) stays as it is: it is a start marker used to file outbound cards, and a follow-up whose start fires after its turn's `finally` leaves a stale entry there (T0b B5). The ledger uses a separate map, `executing` (`convId → messageId`):

- `handleMessage` sets a local flag `awaiting` just before `await runChannelInboundEvent(…)` and clears it right after the await.
- `onAgentRunStart` sets `executing[convId] = messageId` only while `awaiting` is set. It also calls `runStarted(messageId, awaiting)`.
- The inner `finally` deletes `executing[convId]` if it still names this message.

Every entry therefore ends in the `finally` of the call that set it. A follow-up whose start fires before its dispatch returns is executing only until that return, then never again.

**Run log line.** Each run start logs `yorozu: run started <messageId> attempt <n> boot <bootId>`. The first attempt is 0.

**Degraded mode (decision 3).** If the `runs` store can't be read at start-up, the host logs `yorozu: run ledger unavailable: <error>`, starts with an empty map, and doesn't sweep. The claim checks the map first. On a miss it runs the transcript check:

- found: duplicate, entered `settled`;
- missing: fresh;
- read failed: fresh, logged `yorozu: run ledger transcript check failed: <error>`.

New entries still go into the map and the store. The transcript check reuses history's matching (`history.ts` `itemsOf`, `:214`, which keys user items by transport message id, `:403`), so there is no second scanner. It is synchronous and runs on the event loop for every message while degraded. Moving it off the event loop and retrying the store load in the background are deferred until `run ledger unavailable` shows up in the logs.

Why this fallback exists: dedupe protects at-most-once. The deferred "unlisted" rule only protected liveness.

**Wiring.** `startAccount` opens the ledger and passes `claim` through `RelayHostOptions` to the Hub. Without `claim`, the Hub keeps its in-memory id list. So the Hubs built without one in `apps/relay/src/direct.test.ts:57` and `apps/windows/conformance/host/fake-host.ts:39` behave as before. The Hub still imports only Node built-ins and wire files (standalone typecheck).

### Host: start-up sweep and session-open report (ticket 02)

**Start order** in `startAccount`:

1. Load the existing stores (attachment index, message times, replies, reactions).
2. Open and load the ledger.
3. Sweep.
4. `watchSessions`.
5. The retry loop (`runParked`).
6. The gateway notice (`announceGatewayState`).
7. The relay host.

Nothing is broadcast during the sweep: no device has a session yet.

**Once per process.** A persisted marker (namespace `run-sweep`, `retention: "retained"`, one key `last`, value `{bootId, seq}`) holds the boot id and sweep sequence of the last sweep. The sweep runs only when the boot id differs. Why persisted rather than a module-level flag: a plugin registry reload can re-import the module in the same process, which resets module state. A flag would then sweep again and mark the current process's own live turns interrupted. The boot id survives a re-import, and one marker avoids K3's race with reloads.

If the marker can't be read, or the ledger is degraded, there is no sweep and no marker write, logged `yorozu: restart sweep skipped: <reason>`.

**Sweep procedure.**

1. Read the message ids the `retry` store holds (`parkedMessages`). If that read fails, skip the sweep as above.
2. Take the `open` and `queued` entries. Leave alone any whose id, or whose run key, the retry store holds.
3. Group the rest by conversation and classify each conversation once (classifier below):
   - **No session:** all entries become `settled`, logged `yorozu: turn settled, no session <messageId>`. This covers a conversation deleted on any device.
   - **Otherwise, `queued` entries** become `interrupted` with `queued: true`, logged `yorozu: turn interrupted by restart <messageId>`. OpenClaw's follow-up queue doesn't survive a restart (T0b B2), so its recovery can't hold them, whatever the classifier reads.
   - **Unknown:** `open` entries become `settled`, with one warning `yorozu: restart recovery state unreadable, not marking interrupted: <reason>`.
   - **Recovery pending:** `open` entries become `settled`, logged `yorozu: turn left to OpenClaw recovery <messageId>`.
   - **Nothing pending:** `open` entries become `interrupted`, logged `yorozu: turn interrupted by restart <messageId>`.
4. Marked entries get `interruptedAt` = now and `sweep` = seq, where seq is one more than the larger of the marker's seq and the highest `sweep` on any entry.
5. Await every entry's write chain, then write the marker. A failed entry write still lets the marker be written; the failure was already logged by the chain.

The sweep never queues, parks or runs anything (decision 5).

**Recovery classifier.** `classifyRecovery` in `src/recovery.ts` is the only code that knows OpenClaw's field names. It takes a read function, so it also sees a read that throws. The binding passes `() => getSessionEntry({agentId, sessionKey})`, the SDK's plugin projection, which strips private fields such as `mainRestartRecovery`. The first matching rule wins:

1. **Unknown** if the read throws, or a field below is present with a type other than the one listed.
2. **No session** if there is no entry.
3. **Recovery pending** if `abortedLastRun` (boolean) is true or `status` (string) is `"interrupted"`.
4. **Recovery pending** if a `restartRecoveryRuns` run id (array of `{runId: string}`) is not in `restartRecoveryTerminalRunIds` (array of strings), or `restartRecoveryDeliveryRunId` (string) is set, or `pendingFinalDelivery` (object) is set. This is OpenClaw's own claim check minus the private field.
5. Otherwise **nothing pending**.

Rule 3 is the signal for "queued for recovery". OpenClaw's start-up marking sets `abortedLastRun = true` and usually `status = "interrupted"` when it takes custody of a cut-off run, and custody may then show only in the private field (T0b B3). In a normal start-up that marking finishes before any channel's `startAccount`. It can also be skipped on a suppressed start-up, fail with only a warning, or happen later when a store scan is retried. In those cases the sweep reads "nothing pending", and the report's re-check below is the only further guard.

OpenClaw clears these two fields at the next run start in that session, and when a new turn claims the session (Further notes, B6). A conversation is therefore not stuck as "pending": each restart's sweep reads it afresh.

The classifier leans toward at-most-once. A session OpenClaw marked but will not resume (retry budget spent, or tombstoned) also reads as pending, and its device waits out the awaiting window.

**Session-open report**, in the per-device `peer_info` hook (`relay.ts` `onPeer`), after the read cursors, to that device only:

1. **Pick runs.** Group `interrupted` entries by run key (own id when none). Keep runs whose `sweep` is above this device's watermark and whose `interruptedAt` is within 24 h. Order newest first, by `sweep`, then `at`. Take at most 100; older ones are dropped for this device.
2. **Re-check each run.** Classify its conversation again (once per conversation per report). The run is withdrawn when the conversation now reads no session, or, for a run with no `queued: true` entry, recovery pending or unknown. A withdrawn run's entries become `settled`, logged `yorozu: interrupted run withdrawn <messageId> (<pending|no session|unreadable>)`, and nothing is sent for it. Unknown withdraws for the same at-most-once reason as in the sweep.
3. **Send each remaining run:** `typing {convId, active: false}`, left out while a run is executing in that conversation, then one interrupted error whose `messageId` is the run's last user message (latest `at`). Resend in the app therefore sends that message (Q3).
4. **Executing runs:** `run_started {convId, messageId}` for each entry of `executing`.
5. **Watermark.** Set this device's watermark to the highest `sweep` considered in step 1, including dropped and withdrawn runs. Store: namespace `run-told`, `retention: "retained"` like every per-device store, key = the device's public signing key as the allowlist stores it, value `{seq}`. Written through, not awaited by the report.

**Why `typing false` (CN-4).** The Windows app clears typing only on a `typing` event, a `reply`, or its own 30 s expiry (`apps/windows/core/src/sync.rs:321-323`, `:295-296`, `:194-195`); its `run_failed` handling doesn't touch typing (`sync.rs:253-265`). The current iOS error path already stops typing (`apps/ios/Sources/Client/AppModel.swift:842`). Whether every older iOS build does is unverified. Agent-accepted; kept.

**Once per device.** Interruptions come only from sweeps, so one sequence watermark per device replaces per-entry device lists. A sequence number can't hide runs when the wall clock steps back (CN-2); only the 24 h window still uses the wall clock. A lost send leaves the device on the awaiting window. A repeat, after a failed watermark write, is harmless: the app's error row has a fixed id per message.

**Forgetting a device.** The relay host's `forget` (`relay.ts:322-328`), which unpair (`relay.ts:130-134`), device removal and pairing eviction all reach, also calls `deviceForgotten(deviceKey)`, which deletes that device's watermark. A re-paired device starts with no watermark and gets the runs of the last 24 h once.

**Live Activity.** No change.

### Module interfaces (frozen)

`src/ledger.ts` is a pure factory. It imports only Node built-ins, `envelope.ts` types and the `Keyed` type from `cards.ts`, and it is added to `tsconfig.standalone.json`. `src/runs.ts` is a thin runtime binding, as `presentations.ts` binds `cardStore` (`cards.ts:133`).

```ts
// src/ledger.ts
export type RunState = "open" | "queued" | "settled" | "interrupted";
export type RunRecord = { convId: string; state: RunState; at: number; run?: string; interruptedAt?: number; sweep?: number; queued?: true };
export type SweepMarker = { bootId: string; seq: number };
export type Told = { seq: number };
export type Store<T> = Keyed<T> & { entries(): Promise<{ key: string; value: T }[]> };
export type Recovery = "pending" | "none" | "no-session" | { unknown: string };
export type LedgerDeps = {
  runs: () => Store<RunRecord>;          // namespace "runs"
  marker: () => Keyed<SweepMarker>;      // namespace "run-sweep"
  told: () => Keyed<Told>;               // namespace "run-told"
  now: () => number;
  bootId: string;
  log: { info(line: string): void; warn(line: string): void };
  inTranscript: (convId: string, messageId: string) => "found" | "missing" | "unreadable";
  parked: () => Promise<Set<string>>;    // rejects when the retry store can't be read
  recovery: (convId: string) => Recovery;
  executing: () => ReadonlyMap<string, string>;   // convId → messageId of the executing run
};
export function createLedger(deps: LedgerDeps): Ledger;
export type Ledger = {
  load(): Promise<"loaded" | "degraded">;          // once per instance; later calls return the first result
  claim(message: Message): "fresh" | "duplicate";
  runStarted(messageId: string, convId: string, awaiting: boolean): void;
  dispatchReturned(messageId: string, convId: string, deferred: unknown): void;
  turnEnded(messageId: string, convId: string, parked: boolean): void;
  sweep(): Promise<void>;
  report(deviceKey: string): Promise<Event[]>;
  forgetDevice(deviceKey: string): Promise<void>;
  idle(): Promise<void>;                           // resolves when every pending write chain has settled (tests, sweep)
};

// src/recovery.ts (pure)
export function classifyRecovery(read: () => unknown): Recovery;

// src/runs.ts (binding; imports runtime.ts, history.ts, retry.ts, conversation.ts)
export function openLedger(ctx: { cfg: OpenClawConfig; agent: string; log?: ChannelGatewayContext["log"] }): Promise<Ledger>;
//   First call: creates the ledger with the runtime stores and boot id, loads it. Later calls (reloads) update the
//   bound cfg, agent and log and return the same instance.
export function currentLedger(): Ledger | undefined;

// src/conversation.ts: export function executingRuns(): ReadonlyMap<string, string>;
// src/retry.ts:        export function parkedMessages(): Promise<Set<string>>;
// src/history.ts:      export function findUserMessage(cfg: OpenClawConfig, agent: string, convId: string, messageId: string): "found" | "missing" | "unreadable";
// src/hub.ts HubOptions:       claim?: (message: Message) => "fresh" | "duplicate";
// src/relay.ts RelayHostOptions: claim?: HubOptions["claim"]; sessionOpen?: (deviceKey: string) => Promise<Event[]>; deviceForgotten?: (deviceKey: string) => void;
```

The Hub and relay modules don't import the ledger or the conversation module; `startAccount` passes the callbacks. `runtime.ts:1` imports `openclaw/plugin-sdk/runtime-store`, which isn't installed in CI, so Hub tests build a ledger with `createLedger` over fake stores and inject its `claim`. They never import `runs.ts`.

**Restart seam for tests.** A restart is a new `createLedger` over the same fake store objects with a new `bootId`, plus a new Hub. A module re-import is a new `createLedger` with the same `bootId`. A reload is a second `load()` on the same instance.

### Wire (contract docs only; no new kind, field or capability)

- `run_failed` gains one documented reason: `message` exactly `interrupted by a host restart` means a restart cut the run off and the host will not run it again by itself. A client may show its own text and offer Resend for it. Every other `run_failed` keeps its meaning. The contract's error table carries the exact string; the plugin and the app each keep it as a constant in their own code, with a test on each side (CN-5, agent-accepted; no YorozuWire change).
- The capability rule (`OWNER_DECISIONS.md:128`): every event sent is an existing kind with its existing meaning (the run for that message failed; a run started; typing stopped). That this is not "new behaviour" is Yorozu (the agent)'s ruling, not the owner's. It is under review as CA-7 (Pending decisions).
- The dedupe promise (`docs/ios-relay-contract.md:433`, "remembered 24 h, up to 10,000") keeps its bounds and now holds across restarts, with the limits in "Promises and their limits".
- `docs/ios-relay-contract.md:435` says "Nothing is queued for a device without a session: it catches up through `history`." The report changes that rule for interrupted runs: they are held for up to 24 h and sent at the device's next session open. The contract line is rewritten to say so.
- The session-open report is documented next to the read cursors that already follow `peer_info`.

**Older clients** (corrected after CA-7):

| Client | What it does with the report | Cost |
|---|---|---|
| Older iOS builds | Every `error` goes to `append` (`AppModel.swift:841`, `:1049-1057`). A conversation the app doesn't hold is created; an existing one gets `updatedAt` = now and moves to the top of the list. The row reads "The agent run failed: interrupted by a host restart". | A report of up to 100 runs can move up to 100 conversations to the top, against `OWNER_DECISIONS.md:84` (list ordered by last message time). A conversation deleted on another device is recreated only if its OpenClaw session still exists: the sweep and the report settle runs with no session. |
| Windows app | Flags `run_failed` only on a user message in the open conversation (`apps/windows/core/src/sync.rs:253-265`) or in its outbox (`outbox.rs:166-176`). | A run in any other conversation is not flagged; its typing indicator, if shown, clears on its own 30 s expiry. |
| Older hosts | Never send the report. | None. |

### App: Interrupted row and Resend (ticket 03)

**Recognising it.** An `error` with code `run_failed`, `message` equal to the constant, a valid conversation id and a message id.

**Unknown conversation.** In `case .error` (`AppModel.swift:832`), an interrupted error for a conversation the app doesn't hold is dropped first, before `reject` and `append`. `append` would otherwise create the conversation. Other errors keep today's path.

**Making the row.** A new private method `interrupted(convId:messageId:)` replaces the `append` call for this error:

- The message is marked rejected if below `delivered` (existing `reject`), and typing stops (existing `setTyping(convId, false)`, which also clears the stall banner).
- No row `error:<messageId>` yet: append one, kind `.error`, `text` = the localized Interrupted text, `resend` = `offered` if the conversation holds the user item `<messageId>`, else `unavailable`.
- A row with any `resend` value already exists: nothing changes (a repeat keeps `sent`).
- A row without `resend` already exists (an earlier `attachment_missing` or plain `run_failed` row for the same message): it is replaced in place, same id, position and `ts`, by the Interrupted row.

The awaiting state ends because the error row is now the conversation's last non-tools item (`awaitingReply`, `AppModel.swift:1126-1133`), and typing is off.

**Row state.** `ChatItem` gains one persisted optional field `resend: ResendState?` (`offered`, `sent`, `unavailable`). Older builds ignore it. The stray-error cleanup on cache load (`withoutStrayErrors`, `Store.swift:24-32`) keeps rows with any `resend` value, so an `unavailable` row survives a relaunch without its message.

**Upgrade.** In `Conversation.merge` (`Store.swift:58-86`), when a merged history page brings user item X, an `error:X` row that is `unavailable` becomes `offered`.

**Row look** (`apps/ios/Sources/YorozuIOS/Chat.swift`, the `.error` row, `:422-429`): the existing warning label with `item.text`, plus:

| State | Below the label |
|---|---|
| `offered` | A bordered "Resend" button. |
| `sent` | "Resent" in secondary text, no button. |
| `unavailable` | "Resend appears once this message loads." in secondary text, no button. |

`item.text` holds the Interrupted text, so Siri and older builds read it.

**Strings** (`apps/ios/Resources/Localizable.xcstrings`; source language en, the key is the English text):

| Key (en) | ja | zh-Hans | zh-Hant | ko | es | fr | de | pt-BR |
|---|---|---|---|---|---|---|---|---|
| Interrupted: the host restarted during this reply. | 中断: この返信の途中でホストが再起動しました。 | 已中断：回复期间主机重新启动了。 | 已中斷：回覆期間主機重新啟動了。 | 중단됨: 이 답장 중에 호스트가 다시 시작되었습니다. | Interrumpido: el anfitrión se reinició durante esta respuesta. | Interrompu : l’hôte a redémarré pendant cette réponse. | Unterbrochen: Der Host wurde während dieser Antwort neu gestartet. | Interrompido: o host reiniciou durante esta resposta. |
| Resend | 再送信 | 重新发送 | 重新傳送 | 다시 보내기 | Reenviar | Renvoyer | Erneut senden | Reenviar |
| Resent | 再送信済み | 已重新发送 | 已重新傳送 | 다시 보냄 | Reenviado | Renvoyé | Erneut gesendet | Reenviado |
| Resend appears once this message loads. | このメッセージを読み込むと再送信できます。 | 此消息加载后即可重新发送。 | 此訊息載入後即可重新傳送。 | 이 메시지를 불러오면 다시 보낼 수 있습니다. | Podrás reenviar cuando se cargue este mensaje. | Le renvoi sera possible une fois ce message chargé. | Erneutes Senden ist möglich, sobald diese Nachricht geladen ist. | Será possível reenviar quando esta mensagem carregar. |

**Resend.** `AppModel.resend(_ row: ChatItem, in convId: String)`:

1. Does nothing unless the row is `offered` and the conversation holds the original user item.
2. Calls a new `send` overload that takes a stored `ReplyTo` (`send(_:attachments:in:messageId:replyTo:)`) with a fresh id, the original's text, its `replyTo`, and its attachments that have no `failure`. The ids are reused: the host already holds those files.
3. Sets the row to `sent`. A second tap does nothing. Nothing is sent without the tap.

**Shared attachment files.** After a Resend, two items name the same attachment ids. `discard` (`AppModel.swift:1030-1037`) deletes files by attachment id (`Transfers.swift:65-67`). It now deletes a file only when no other item in any conversation still names that attachment id. Deleting a conversation still deletes all its files: both items are in it.

**Other devices.** Each device shows its own Resend; two devices can each resend once (two deliberate taps; accepted). Siri's wait ends on an `.error` item; `needsAttention` turns on, as for any failed turn.

**Cost of Q3.** Resend sends only the run's last message. An earlier message folded into the same run is in the transcript, so the OpenClaw agent sees it, but it is not resent. Accepted by Q3.

### Files by ticket

Paths are repo-relative. Tickets 01 and 02 ship in one plugin PR.

| Ticket | Action | Path | What |
|---|---|---|---|
| 01 | Create | `plugins/openclaw-yorozu/src/ledger.ts` | Pure factory: claim, writers, load, pruning, sweep, report. |
| 01 | Create | `plugins/openclaw-yorozu/src/runs.ts` | Runtime binding: stores, boot id, lookups. |
| 01 | Modify | `plugins/openclaw-yorozu/src/hub.ts` | `claim` option. |
| 01 | Modify | `plugins/openclaw-yorozu/src/relay.ts` | Pass `claim` to the Hub. |
| 01 | Modify | `plugins/openclaw-yorozu/src/conversation.ts` | `awaiting` flag, `executing` map, `executingRuns`, writer calls, run log line. |
| 01 | Modify | `plugins/openclaw-yorozu/src/history.ts` | `findUserMessage`. |
| 01 | Modify | `plugins/openclaw-yorozu/src/channel.ts` | `openLedger`, pass `claim`. |
| 01 | Modify | `plugins/openclaw-yorozu/tsconfig.standalone.json` | Add `src/ledger.ts`, `src/recovery.ts`. |
| 01 | Create | `plugins/openclaw-yorozu/test/ledger.test.ts` | Writers, claim, degraded mode, pruning, write order (pure factory). |
| 01 | Create | `plugins/openclaw-yorozu/test/hub-ledger.test.ts` | Hub with an injected claim; restart seam. |
| 01 | Create | `plugins/openclaw-yorozu/test/conversation-ledger.test.ts` | Writers and the executing signal through the stand-in host. |
| 01 | Modify | `plugins/openclaw-yorozu/test/genui-host.js` | Fake keyed store and dispatch extensions (Testing). |
| 01 | Modify | `plugins/openclaw-yorozu/test/hub-host.ts` | Optional `claim`. |
| 01 | Modify | `docs/ios-relay-contract.md` | Dedupe line (`:433`). |
| 01 | Modify | `docs/openclaw-channel.md` | `deferredToActiveRun`, follow-up start timing, the `runs` store. |
| 01 | Modify | `plugins/openclaw-yorozu/README.md` | Run ledger section. |
| 01 | Modify | `apps/mcp/src/content.json` | Regenerated help bundle. |
| 02 | Create | `plugins/openclaw-yorozu/src/recovery.ts` | `classifyRecovery`. |
| 02 | Modify | `plugins/openclaw-yorozu/src/retry.ts` | `parkedMessages`. |
| 02 | Modify | `plugins/openclaw-yorozu/src/channel.ts` | Start order, sweep, `sessionOpen`, `deviceForgotten`. |
| 02 | Modify | `plugins/openclaw-yorozu/src/relay.ts` | Report after the read cursors; `deviceForgotten` in `forget`. |
| 02 | Create | `plugins/openclaw-yorozu/test/recovery.test.ts` | Classifier rules. |
| 02 | Create | `plugins/openclaw-yorozu/test/sweep.test.ts` | Sweep, report, re-check, watermark (pure factory + Hub). |
| 02 | Create | `plugins/openclaw-yorozu/test/sweep-retry.test.ts` | Real retry module with mock timers. |
| 02 | Create | `plugins/openclaw-yorozu/test/recovery-pin.test.ts` | Pin test, SDK-gated. |
| 02 | Modify | `plugins/openclaw-yorozu/test/presentations.test.ts` | Start order. |
| 02 | Modify | `docs/ios-relay-contract.md` | `run_failed` reason row; Delivery (`:435`); session-open report. |
| 02 | Modify | `docs/openclaw-channel.md` | Recovery fields read and when they clear. |
| 02 | Modify | `plugins/openclaw-yorozu/README.md` | Sweep and report. |
| 02 | Modify | `apps/mcp/src/content.json` | Regenerated help bundle. |
| 03 | Modify | `apps/ios/Sources/Client/Store.swift` | `ResendState`, `ChatItem.resend`, stray-error rule, merge upgrade. |
| 03 | Modify | `apps/ios/Sources/Client/AppModel.swift` | Error case, `interrupted`, `resend`, `send` overload, `discard`. |
| 03 | Modify | `apps/ios/Sources/YorozuIOS/Chat.swift` | Row look. |
| 03 | Modify | `apps/ios/Resources/Localizable.xcstrings` | Four strings, nine languages. |
| 03 | Modify | `apps/ios/Tests/Support/Transports.swift` | `ScriptedTransport.sentMessages`. |
| 03 | Create | `apps/ios/Tests/AppModelInterruptedTests.swift` | Ticket 03 tests. |

No files are deleted. `apps/ios/Project.swift` needs no change: the YorozuTests target lists `"Tests/**"` (`Project.swift:250`), so the new test file is compiled, and `Store.swift`, `AppModel.swift` and `Transfers.swift` are already listed. The target has no resources, so test 03 #8 reads the strings file from the source tree: `URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../Resources/Localizable.xcstrings")`, as `YorozuActivityTests.swift:113` reads its fixture.

## Testing decisions

**Seams, highest first.**

- **Ledger:** `createLedger` over fake stores, a fake clock and boot ids. The restart seam is in "Module interfaces".
- **Hub:** the existing fake host and Noise device harness (`hub-host`), with a claim from `createLedger`.
- **Conversation and writers:** the existing stand-in host for OpenClaw (`genui-hooks` maps the runtime and Gateway-bound modules to `genui-host.js`). Extend its fake keyed store rather than copying it:
  - no eviction when `maxEntries` is undefined (today it would wipe the retained `retry` store);
  - an `entries` failure mode, a write recorder and a slow mode;
  - reopen over the same rows.

  The stub's dispatch gains a way to return `dispatchResult.deferredToActiveRun` and to fire `onAgentRunStart` before or after the dispatch returns.
- **Retry interplay:** a resolve hook scoped to the module under test loads the **real** retry module while the runtime stays the stub, with `node:test` mock timers for the 5 s tick. Precedent: `conversation-owner.test.ts:146`.
- **Start order:** recording stubs for the retry, ledger and relay modules on the existing `startAccount` test base in `presentations.test.ts`.
- **Recovery classifier:** plain unit tests on read functions, plus one pin test against the real OpenClaw 2026.9.8 SDK. It runs when `YOROZU_OPENCLAW_SDK` points at an installed package, as `conversation-owner` does, and is skipped in CI. Coder runs it locally and quotes the output in the PR.
- **App:** `ModelHarness` with `ScriptedTransport`. `ScriptedTransport.send(_ message:)` records nothing today; ticket 03 adds `sentMessages`.

**What a good test checks:** the events each device receives, whether `onMessage` ran, log lines, the store's rows after a reopen, the app's items and sent messages. Not private maps.

**Prior art:** `hub-events`, `hub-session` (Hub); `genui-golden`, `prerun-error`, `conversation-owner` (conversation); `activitywatch` U6/U7 (Live Activity restore); `AppModelSyncTests` (app); `presentations.test.ts` (`startAccount`).

**Red tests, ticket 01.** The PR's first code commit holds only red tests; the PR body names each and its failure on the parent.

1. A restart (new ledger and Hub over the same store) and M again: `onMessage` ran once; `delivered` went out both times; one `duplicate message skipped (settled)`.
2. A duplicate of M while M's run executes gets only `delivered`: no `run_started`, `typing` or `error`.
3. Degraded ledger, transcript holds M: M doesn't run.
4. Degraded ledger, transcript read fails: M runs; `run ledger transcript check failed` logged.
5. Writer table: park leaves `open`; the outer `finally` writes `settled`; a pre-run failure writes `settled`.
6. Steer: M1 starts, M2's dispatch returns `"steer"`: M2 is `open` with run M1; M1's end settles both.
7. Follow-up: M2's dispatch returns `"followup"`: M2 is `queued`; M2's later `onAgentRunStart` settles it and earlier queued entries of that conversation.
8. Follow-up whose start fires before its dispatch returns: `executingRuns` names it until the dispatch returns, then not; M2 ends `settled`.
9. Follow-up whose start fires after its turn's `finally`: `executingRuns` never names it.
10. After a follow-up has run, a new session open gets no `run_started`.
11. Steer into a running follow-up (M2 started detached, M3's dispatch returns `"steer"`): M3 is `settled` at once; a restart then marks nothing and sends no row.
12. Writes for one id land in call order with a slow store; a failed write logs and the turn completes.
13. Pruning: entries older than 24 h (by `at`, or `interruptedAt` for interrupted ones) are dropped on load; the map stays within 24 h and 10,000 on claims.
14. Degraded ledger: a second copy of M in the same process is a duplicate without a transcript read.
15. An unknown `deferredToActiveRun` value settles the entry and logs `unknown dispatch deferral`.
16. Guards: relay and direct copies of M arriving together run once; a Hub without `claim` behaves as before (`pnpm --filter @yorozu/relay test` and `bash apps/windows/ci/core.sh` pass unmodified).

**Red tests, ticket 02.**

1. An `open` entry from an earlier process, not parked, nothing pending: `interrupted`, logged once.
2. A parked id, and an entry steered into a parked run, stay `open`; the real retry loop still reruns the parked one on its schedule.
3. A second `startAccount` in the same process sweeps nothing; a new ledger with the same boot id (module re-import) sweeps nothing.
4. A retry-store read failure, a marker read failure and a degraded ledger each skip the sweep and write no marker.
5. Start order: stores → ledger → sweep → `watchSessions` → retry loop → gateway notice → relay host.
6. A run cut off by a simulated restart gives each of two devices exactly one `typing false` and one interrupted error, after the read cursors, to that device only. A reconnect and a second simulated restart send that device nothing more.
7. At most 100 runs per report; runs older than 24 h are skipped; a wall-clock step back of an hour hides nothing.
8. A run executing now gets `run_started {convId, messageId}` in the report, after the errors; a parked, preparing or follow-up turn does not.
9. A duplicate of an `interrupted` message gets only `delivered` and doesn't run.
10. Recovery pending, one test each: `abortedLastRun: true`; `status: "interrupted"`; a non-terminal `restartRecoveryRuns` run; a `pendingFinalDelivery`. `open` entries become `settled`, `left to OpenClaw recovery` is logged, nothing is reported.
11. Nothing pending (an entry with only terminal recovery runs): `interrupted`.
12. No session entry: `settled`, `turn settled, no session` logged, nothing reported.
13. Unknown shape (`restartRecoveryRuns` as a string) and a throwing read: `open` entries `settled`, one warning, nothing reported for them.
14. Re-check: an `open` entry marked `interrupted`, then the session reads pending (or has no entry) at the device's session open: no error, the run is `settled`, `interrupted run withdrawn` logged. A `queued: true` run is still reported while the session reads pending.
15. Two steered messages, one run: M1 starts, M2 steered into it, restart: each device gets exactly one `run_failed`, for M2, and one `typing false`.
16. Queued follow-up M2 behind M1, restart, recovery pending for the conversation: M1 `settled`, M2 `interrupted`; each device gets one error, for M2.
17. Unpairing a device deletes its watermark; after re-pairing it gets the runs of the last 24 h once.
18. Sweep writes: the marker is written after every entry chain settles, also when one entry write failed.
19. Pin test (OpenClaw 2026.9.8, SDK-gated): the real `getSessionEntry` returns `abortedLastRun`, `status`, `restartRecoveryRuns`, `restartRecoveryTerminalRunIds`, `restartRecoveryDeliveryRunId` and `pendingFinalDelivery` with the types the classifier expects, and the real dispatch result type carries `deferredToActiveRun`. It checks only the shape, not what the queue modes mean (CN-6: their meaning stays in writers 2 and 3, from T0b B1).
20. Guards: an interrupted turn's Live Activity job still ends on restore; a device with no interrupted runs gets only the read cursors.

**Red tests, ticket 03.**

1. An interrupted error appends one Interrupted row with Resend, and clears typing, stall and awaiting for that conversation.
2. The same error again adds no row and keeps a `sent` state.
3. Resend sends exactly one new message (new id; same text, `replyTo` and attachment ids without a failure); the row shows "Resent" with no button; a second tap sends nothing.
4. Nothing is sent without the tap, across a reconnect.
5. The row state survives a relaunch (store round trip), including an `unavailable` row whose message the app doesn't hold.
6. An `unavailable` row becomes `offered` when a history page brings its message.
7. An interrupted error for an unknown conversation creates nothing.
8. An existing `error:<id>` row without `resend` is replaced in place by the Interrupted row.
9. Discarding the queued resent message keeps the original's attachment files.
10. A `run_failed` with any other message keeps the old row with no Resend.
11. The four strings exist in all nine languages, read from `Localizable.xcstrings` as above.

**Acceptance commands** (Node 26, as CI; from the repo root):

```sh
node --test 'plugins/openclaw-yorozu/test/*.test.ts'
tsc -p plugins/openclaw-yorozu/tsconfig.standalone.json --typeRoots ~/openclaw/node_modules/@types
# Full plugin typecheck: needs plugins/openclaw-yorozu/node_modules/openclaw -> ~/openclaw.
# Zero errors in plugin files; about 484 pre-existing errors inside ~/openclaw source are ignored.
~/openclaw/node_modules/.bin/tsc -p plugins/openclaw-yorozu
pnpm --filter @yorozu/relay test
bash apps/windows/ci/core.sh
# Help bundle, whenever a top-level docs file or the plugin README changes:
node apps/mcp/scripts/generate.ts
node apps/mcp/scripts/generate.ts --check
# App:
tuist generate --no-open --path apps/ios
xcodebuild test -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuTests -destination 'platform=macOS'
swift test --package-path packages/YorozuWire
```

## Alternatives considered

- **The v4 shape: a new `turn_state` event, a `turnState` capability, a `resendOf` field and a host-side Resend guard.** Not taken (A1(b)). Reopened in part by CA-7 (Pending decisions).
- **Automatic requeue after a restart.** Withdrawn by decision 5.
- **T0 option (c): opt Yorozu turns out of OpenClaw's restart recovery.** Not available: OpenClaw 2026.9.8 has no per-channel or per-run opt-out (T0b B4). Q1 (b) was chosen instead.
- **T0 option (d): measure first, build later.** Not taken: the owner chose to fix S1, S1b, S2 and S4 now (brief). CA-6 proposes a different order of work (Pending decisions).
- **Relying on OpenClaw's own message dedupe.** Not enough. OpenClaw's `MessageSid` cache is memory-only. Its durable source-turn check does survive a restart (T0 answer 2), but only while the session keeps a matching active claim or terminal source id, and only for messages OpenClaw already received. The host still needs its own dedupe for messages it accepted and never handed over (preparing, or lost with the follow-up queue), and to avoid repeating preparation work (attachment staging, the push title, the `attachment_missing` error). How long OpenClaw keeps terminal source ids is not known; ticket 01 doesn't depend on it.
- **A per-entry boot id instead of one sweep marker.** Not taken (K3).
- **A module-level "swept" flag instead of a persisted marker.** Not taken: a module re-import in the same process would sweep again.
- **A wall-clock watermark.** Not taken: a clock step back hides runs. A sweep sequence costs one more field.
- **Waiting for the store write before `delivered`.** Not taken: it changes ✓✓ from "received and decrypted" (`OWNER_DECISIONS.md`) and adds an async step to close a short gap.
- **A new distinguishing field on `error`.** Not taken: tolerant readers would ignore it, but it is still a wire change the brief rules out (A1(b)).
- **Extra events for a duplicate (`run_started`, the interrupted error).** Dropped (CA-8). The device resends right after `peer_info`, just after the report, so they only repeated it.
- **A transcript guard before marking interrupted.** Not taken for the sweep: a reply in the transcript doesn't prove the run finished. False rows from failed writes are accepted and logged instead (Risks).
- **A complete "still running" listing with the app's unlisted rule.** Deferred (Further notes).
- **Transcript only, no store.** Not taken: queued messages aren't in the transcript. Kept as the degraded fallback (decision 3).
- **Removing the Hub's in-memory list and requiring a ledger.** Not taken: the relay and Windows conformance Hubs are built without one.

## Risks

| Risk | Mitigation or check |
|---|---|
| A restart between the claim and its store write loses the entry | Accepted: that message behaves as before the change. Measured by `run started <id> attempt 0` under two boot ids (Further notes). |
| A failed `settled` write leaves an `open` entry the next restart marks interrupted | Accepted: the owner may see a row with Resend for an answered run. Logged as `run ledger write failed`; target 0. |
| A failed `interrupted` write | The entry stays `open` on disk; the next restart's sweep classifies it again. Logged. |
| Rollback, then re-deploy | The older plugin doesn't write `runs`, so entries it handled stay as the newer plugin left them, mostly `open`. The re-deployed plugin's first sweep classifies them like any earlier process's entries: within 24 h, those in conversations with nothing pending become Interrupted rows for runs that may have been answered. Accepted; rollback is rare and the window is 24 h. |
| OpenClaw's marking is skipped (suppressed start-up), fails with a warning, or comes later than the sweep (T0b B3) | The sweep reads nothing pending and marks the run interrupted. The report's re-check withdraws it if the session reads pending by the time the device opens a session. Remaining gap: OpenClaw recovers and finishes the run between the sweep and the session open, so the session no longer reads pending; a Resend then runs it twice. Measured: an interrupted turn later followed by a recovery reply in that conversation. |
| OpenClaw marks a session it then won't resume (budget spent, tombstone) | No row; the device waits out the awaiting window (fail-safe direction). |
| OpenClaw renames or reshapes the fields | The shape check fails safe with a warning; the pin test fails against the new version. |
| A follow-up starts and the restart cuts it off | Settled at its start, so no row. OpenClaw's marking usually covers it as a normal run. Accepted for at-most-once. |
| Queued messages that collect mode would have merged into one run | Each gets its own row (CN-7). Accepted: Q3 keys rows by run, and these never became a run. |
| OpenClaw drops a queued follow-up over its queue cap | Settled when a later queued message starts; no row (as before the change). |
| A steered message whose run is parked and whose text didn't reach the transcript | Not replayed by the rerun; settled with the run. Accepted; how often is not measured. |
| A first message in a new conversation cut off before OpenClaw recorded its session | Reads as no session: settled, no row; the device waits out the window. |
| A session reset between the message and a degraded transcript check | The check reads the new session and answers "missing": the message runs. Degraded mode only. |
| Older iOS builds move reported conversations to the top | Up to 100 per report (Older clients). Pending decision CA-7. |
| Message ids stored on disk | Ids, conversation ids, states, times and sequence numbers; no message text. |
| Two devices both tap Resend | Accepted (two deliberate taps). |
| Report size | At most 100 errors, 100 `typing` events and one `run_started` per executing run, about 200 bytes each. |

## Out of scope

- S3 and S5–S8; relay, pairing, timestamp and Live Activity format changes; Windows sync tests.
- Automatic rerun after a restart; typing for queued turns from other devices.
- Release, TestFlight and merges: draft PRs only.

## Further notes

### Pending decisions

These two review items are decisions, not edits. This draft keeps the current shape until their owners rule.

**CA-6. Scope and shape.** Decision owner: Yorozu (the agent); part of it may reopen Q1 (b).

| Option | What it is | Gains | Costs |
|---|---|---|---|
| A. Current shape | This spec. | Resend for cut-off runs the host reads as unheld; one PR for tickets 01 and 02. | Four ledger states, five writers, the classifier copying part of OpenClaw's custody logic, the pin test, and the CA-5 gap. |
| B. Narrow shape | 1) Ship ticket 01 first, alone, as a durable write-once dedupe set (`claim` → fresh or duplicate; no state machine). 2) Report a message as interrupted only if the host never handed it to OpenClaw's dispatch, or OpenClaw returned it as `"followup"` and it never started. Everything handed over is OpenClaw's to resume or abandon. 3) Session-open `run_started` as a separate small change. 4) Ask OpenClaw for a public custody check or an "abandoned" notice. 5) Name the Hermes dependency (T0 answers note: the Hermes spec relies on the ledger API and sweep). | Removes the classifier, the six field reads, the pin test, steered run keys and most writers; no Resend on a run OpenClaw might resume (closes the CA-5 gap); ticket 01's logs give the first incident data. | A running turn cut off in a session OpenClaw failed to mark gets no row and waits out the window, as today. Reopens Q1 (b). |

Spec parts option B changes: Goals 2 and 4; Solution; Promises; ledger states and writers 2–5; the classifier and its glossary entries; sweep step 3; the report's re-check; the module interfaces; red tests 01 #6–#11 and 02 #10–#16 and #19; Risks rows on marking and reshaping; the file table (no `recovery.ts`, no pin test).

**CA-7. Older clients and the capability rule.** Decision owners: Yorozu (the agent) for A1(b); the owner for the reading of `OWNER_DECISIONS.md:128`.

The corrected facts are in "Older clients". The mitigation already in this draft: runs in conversations with no OpenClaw session are settled at the sweep and at the report, so a conversation deleted on any device is not recreated.

| Option | What it is | Costs |
|---|---|---|
| A. Ungated (A1(b), current) | Send the report to every client. | Older iOS builds move up to 100 conversations to the top of the list, against `OWNER_DECISIONS.md:84`; Windows flags only open-conversation or outbox messages; the contract's "nothing is queued for a device without a session" changes; the "not new behaviour" ruling under `:128` is the agent's, not the owner's. |
| B. Capability-gated | A new `peer_info` capability (for example `interrupted`); the host sends the report only to clients that list it. Others keep today's behaviour (the awaiting window). | A wire addition A1(b) rules out: a capability constant in YorozuWire and the plugin, a contract row, and tests on both sides. Windows and older iOS get no Interrupted signal at all. |

Spec parts option B changes: Goal 5; Wire; Older clients; the report (gate check); A1(b) in Referenced decisions; ticket 03 (sends the capability); the file table (`packages/YorozuWire`).

### Other notes

- **Deferred (Yorozu (the agent), 2026-11-19 11:21 JST): decision 1's app-side "unlisted" rule.** A run the app shows as running but the host doesn't list is not marked interrupted: A1(b) has no listing event. The host side of decision 1 stays. The case it covered keeps the awaiting window and is measured by `run ledger unavailable` (target 0).
- **Agent-accepted items:** the choices in "Referenced decisions" were accepted by Yorozu (the agent) under the brief's delegation. None changes an owner rule; CA-7 asks whether the capability-rule reading does.
- **T0 answers** (OpenClaw 2026.9.8, source reading only):
  1. Can OpenClaw resume a cut-off Yorozu turn after a restart? Yes, through main-session restart recovery, delivering through the outbound adapter.
  2. Is OpenClaw's message dedupe durable? Its `MessageSid` cache is memory-only (20 min, 5,000 entries). A separate source-turn check survives a restart while the session keeps a matching active claim or terminal source id (`src/auto-reply/reply/dispatch-from-config.prepare-context.ts:325-345`).
  3. Does each message get its own run? No: `steer` (default) folds into the running run; a follow-up queue runs later.
  4. Does a parked rerun append the user message twice? No.
  5. Does a `channels.yorozu` reload reload the module? No, it reuses it.
  6. Does `onToolStart` fire before the tool runs? No guarantee (unused here).
  7. Keyed store API? `register`/`delete`/`entries`/`lookup`, `evict-oldest` or `reject-new`, awaited transactional writes.
- **T0b answers** (OpenClaw 2026.9.8, source reading only, after EGM round 1):
  - B1. Steer: the dispatch returns after the injection settles, ordinarily after the transcript commit, with `deferredToActiveRun: "steer"` and no start of its own. Follow-up and collect: it returns at enqueue with `"followup"`; the message's own `onAgentRunStart` fires later, possibly after the dispatch returned and possibly before; a collected batch fires only its last item's; the reply goes through the outbound adapter.
  - B2. The follow-up queue is per process and lost at a restart; a committed steer is part of the resumed transcript.
  - B3. In a normal start-up, marking finishes before any channel's `startAccount`. It can be skipped on a suppressed start-up or fail with a warning, and later store scans can overlap the account's lifetime. It sets the private custody field plus `abortedLastRun = true` and usually `status = "interrupted"`. Custody can show only privately apart from those two fields. No SDK helper reports custody.
  - B4. No opt-out from restart recovery for a channel or run.
  - B5. `runningTurns` is a start marker per conversation, set by `onAgentRunStart` and cleared only by the matching turn's `finally`; a follow-up that starts after its turn's `finally` leaves a stale owner. A parked turn is not in it once its attempt returns.
  - B6 (Coder, read 2026-11-19). OpenClaw clears `abortedLastRun` and `status` when a new run starts in the session: the lifecycle "start" snapshot sets `status: undefined` and `abortedLastRun: false` (`~/openclaw/src/gateway/session-lifecycle-state.ts:174-186`). A new source turn's recovery claim also sets `abortedLastRun: false` (`~/openclaw/src/auto-reply/reply/restart-recovery-claim.ts:421-423`). So "pending" lasts until OpenClaw's recovery run or the owner's next message starts a run in that session. The pin test checks the field types only; this timing is from the source reading and is not pinned.
- **Measures (Yorozu (the agent), for 2 weeks after the Release Mac build that ships ticket 02):** `rg 'yorozu: (run started|duplicate message skipped|turn interrupted by restart|turn left to OpenClaw recovery|turn settled, no session|interrupted run withdrawn|restart recovery state unreadable|unknown dispatch deferral|run ledger|restart sweep)' ~/.openclaw/logs/`.

| Log line | Target |
|---|---|
| `run started <id> attempt 0` for one id under two boot ids | 0 |
| `run ledger write failed` | 0 |
| `run ledger unavailable`, `run ledger transcript check failed` | 0 |
| `restart sweep skipped` | 0 |
| `restart recovery state unreadable`, `unknown dispatch deferral` | 0 (any line: the code needs an update) |
| `turn left to OpenClaw recovery` | Each followed by a reply in that conversation within 10 minutes |
| `turn interrupted by restart` followed by a recovery reply ("continuing your interrupted request") in that conversation | 0 (each one is a run Resend could double) |
| `interrupted run withdrawn` | Counted; each is a late OpenClaw marking the re-check caught |
| `turn interrupted by restart` | Each within a minute after a restart. `~/.openclaw/logs/gateway-restart.log` records planned restarts; whether a crash writes to it is unverified, so an unmatched line is checked against the Gateway's start-up lines before being called a bug. |

- **Release triggers (on merge to `main`):**
  - The docs PR edits only `docs/designs/` and `docs/tickets/`. The help bundle reads only top-level `docs/*.md` and the READMEs (`apps/mcp/scripts/generate.ts:61-63`), and no workflow watches those paths, so its merge starts nothing.
  - The plugin PR (tickets 01 and 02) edits the contract, `docs/openclaw-channel.md` and the plugin README, and regenerates `apps/mcp/src/content.json`. Its merge starts Release Mac (`plugins/**`) and Deploy website (`apps/mcp/src/**`).
  - The app PR (ticket 03) starts Release Mac and Release iOS (`apps/ios/**`) on merge.
- **Rollback:** revert the PR. An older plugin ignores the `runs`, `run-sweep` and `run-told` namespaces; an older app shows interrupted errors as plain failed-run rows. Re-deploying after a rollback is in Risks.

## Review dispositions (round 2)

| Id | Disposition | Reason |
|---|---|---|
| CA-1 | FIXED | "Executing" defined with a known end (awaiting dispatch, cleared in that turn's `finally`); follow-ups never executing; B5 restated; red tests 01 #8–#10. |
| CA-2 | FIXED | (a) Writer 3 settles a steer into a non-executing run, test 01 #11; (b) rollback row rewritten; (c) false rows from failed writes accepted and logged. |
| CA-3 | FIXED | "Files by ticket" table, names frozen, `Project.swift` needs no change, strings read via `#filePath`. |
| CA-4 | FIXED | Goals 2–4 and stories 3, 8, 11 restated; exclusion tables in Promises; unsolved part of S2 in Problem; clearing timing as B6. |
| CA-5 | FIXED | "Can" ordering wording; report re-check; Risks row; measure "interrupted turn later followed by a recovery reply". |
| CA-6 | PENDING | Decision for Yorozu (the agent); stated neutrally in Pending decisions. |
| CA-7 | PENDING (facts FIXED) | Old-client facts and contract line 435 corrected; no-session settle and re-check added; A1(b) and the capability ruling go to their owners. |
| CA-8 | FIXED | `claim` returns fresh or duplicate; a duplicate gets only `delivered`; tests 01 #2 and 02 #9 converted; no running-run lookup in the Hub. |
| CA-9 | FIXED | T0 answer 2 and the alternative now give the source-turn check and the real reason for own dedupe. |
| CA-10 | FIXED | Pure factory with injected deps, `runs.ts` binding, restart seam, report shape, `classifyRecovery(read)`, Hub tests inject the claim. |
| CA-11 | FIXED | Full store options and value types; watermark deleted on forget; await-then-marker rule; pruning timestamps; why not `defaultTtlMs`. |
| CA-12 | FIXED | Unavailable look and upgrade, existing-row replacement, shared-file reference check, unknown conversation dropped first, nine-language strings, awaiting reason. |
| CA-13 | FIXED | Real guard files, relay and Windows commands, exact typecheck and bundle commands, start order matches test 02 #5. |
| CA-14 | FIXED | Surviving stores named, restart count sourced, write latency and steer commit qualified, line-269 risk points to the boot-id measure, contract quote fixed, size includes `run_started`, crash log unverified. |
| CA-15 | FIXED | Roles and glossary cover host, plugin, Hub, Gateway, paths, device session, `peer_info`, turn, run and the agents; status line fixed; "Agent-accepted items". |
| CA-16 | FIXED | Triggers phrased "on merge"; plugin PR edits contract and docs; docs PR touches only paths nothing ingests. |
| CA-17 | FIXED | S1b limited to a queued message lost at restart. |
| CN-1 | FIXED | Transcript check reuses `itemsOf`; sync cost stated; async lookup and background retry deferred until the log line appears. |
| CN-2 | FIXED | Watermark is a sweep sequence stored with the marker and on entries. |
| CN-3 | FIXED | Reason for a persisted marker (module re-import, K3) stated. |
| CN-4 | FIXED | `typing false` kept; Windows reason cited; older iOS behaviour marked unverified. |
| CN-5 | FIXED | Constant stays in each side's code (agent-accepted); exact string in the contract table; a test on each side. |
| CN-6 | FIXED | Pin test scope stated: shape only; queue meaning stays in writers from T0b B1. |
| CN-7 | FIXED | Cut-off follow-ups and collect-mode rows accepted in Risks. |
| CN-8 | FIXED | Promise chain moved to the store paragraph; fake-store internals listed as test seams. |
| CN-9 | FIXED | T0/T0b, EGM, parked, transcript check, queue mode, collect, tombstoned, custody, target 0 defined. |
| CN-10 | FIXED | Stories 2, 6, 12, 14–16 reworded; S1b/S4 clarified; "no new wire" replaced; repeats trimmed; rationale out of mechanism bullets. |
| CN-11 | FIXED | Non-goals listed under Goals. |
| CN-12 | FIXED | Warning text `unknown dispatch deferral` fixed, tested (01 #15) and measured. |
| CN-13 | FIXED | Precedent is `conversation-owner.test.ts:146`. |
