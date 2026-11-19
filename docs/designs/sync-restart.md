# Sync restart durability (S1, S1b, S2, S4)

- **Status:** draft v4. EGM rounds 1 and 2 addressed. CA-6 and CA-7 decided by Yorozu (the agent), 2026-11-19 12:57 JST ("Referenced decisions"). T0 and T0b answered. Yorozu (the agent)'s T0 decisions recorded 2026-11-19 11:21 JST.
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

**What stays unsolved in S2.** Once a message has reached OpenClaw (its run started, it was steered into a run, or OpenClaw took it without deferring it), OpenClaw owns it: its restart recovery may resume the run (T0b B3). The host never marks such a message interrupted. Its turn ends with OpenClaw's recovery reply or with the 10-minute window, as today (CA-6). Only messages OpenClaw never held get a row: those the host was still preparing, and those lost with OpenClaw's follow-up queue.

S3 (the source spec's history-gap case) and S5–S8 are a later spec.

## Goals

1. A message the host accepted runs at most once across restarts, within the bounds in "Promises and their limits".
2. A message the restart caught before OpenClaw held it (still being prepared, or waiting in OpenClaw's follow-up queue and never started) ends with an Interrupted row and a Resend button on each device that lists the `session-report` capability, at that device's next session open within 24 h of the restart.
3. The host adds no new rerun. After a restart it reruns only what the existing auto-retry rule parked. A Resend runs only on the owner's tap, and it is offered only for messages OpenClaw never held.
4. A device that lists `session-report` and opens a session while a run started by this host process is executing shows that run as running at once.
5. Shipped apps, the Windows app and older hosts keep working unchanged: the new behaviour goes only to peers that list the new capability; there is no new event kind or field.

Non-goals: S3 and S5–S8; automatic rerun after a restart; marking runs OpenClaw may resume; typing for queued turns; relay, pairing and Live Activity changes (full list in Out of scope).

## Solution

- **Run ledger (ticket 01, ships alone).** The host keeps a durable record per message id, written when the message is accepted. A repeat of a recorded message id gets `delivered` and does not run again, also after a restart. When the store can't be read, the host checks the transcript instead.
- **Lost-message tracking (ticket 02).** The ledger also records whether OpenClaw holds each message: a message is *accepted* until the host hands it to OpenClaw's dispatch, *queued* when OpenClaw deferred it as a follow-up that hasn't started, and *settled* otherwise.
- **Start-up sweep (ticket 02).** Once per process, the host marks every `accepted` or `queued` message an earlier process left behind as **interrupted**, unless the auto-retry rule holds it or its conversation has no OpenClaw session. It never looks at what OpenClaw might resume.
- **Session-open report (ticket 02).** A device whose `peer_info` lists `session-report` gets, right after its read cursors, the existing `error run_failed` event with a fixed reason text for each interrupted message it hasn't been told about (last 24 h, newest first, at most 100). Messages whose conversation's OpenClaw session is gone are dropped. Other devices get nothing new.
- **`run_started` at session open (ticket 03).** The same report then adds `run_started` for each run executing now.
- **App (ticket 04).** The app lists `session-report` and shows the error as an **Interrupted** row with a **Resend** button. Resend sends the original's text, attachments and quoted message again as a new message with a new id. Nothing is resent without the tap.

## Promises and their limits

**Goal 1 (at-most-once)** holds for a message id within 24 h and the latest 10,000 messages, once its ledger write has landed. The write starts right after `delivered`; it normally lands within milliseconds but can queue behind other store writes (`docs/openclaw-channel.md:49`); this is not measured. It does not hold:

- in degraded mode (the ledger store can't be read at start-up): a message still in OpenClaw's queue is not in the transcript, and a failed transcript read runs the message;
- for a claim whose store write failed (logged, target 0);
- for a restart between `delivered` and the write landing.

**Goal 2 (Interrupted row) excludes:**

| Case | What the device gets instead |
|---|---|
| The message reached OpenClaw: its run started, it was steered into a run, or the dispatch took it without deferring it | OpenClaw's recovery reply, or the 10-minute window |
| A follow-up that started from OpenClaw's queue and was then cut off | The 10-minute window |
| A parked message (the auto-retry rule holds it) | The retry rule's rerun |
| The conversation has no OpenClaw session entry (deleted, or a new conversation's first message cut off before OpenClaw recorded it), or the session read throws | Nothing (deleted) or the 10-minute window |
| A device that doesn't list `session-report` (older iOS builds, the Windows app) | The 10-minute window |
| Messages beyond the newest 100 for that device | The 10-minute window |
| Degraded mode, a skipped sweep, or a failed ledger write | The 10-minute window |
| The report's send is lost (the session drops at that moment) | The 10-minute window |
| The device doesn't hold the original message yet | An `unavailable` row; Resend appears once history brings the message |
| The device opens its first session more than 24 h after the restart | Nothing |

**Goal 4 (run_started at session open) excludes:** devices without `session-report`, follow-up runs (started after their dispatch returned), runs OpenClaw's restart recovery started, parked turns waiting for a retry, and turns still preparing. These keep today's behaviour: the device learns from the next event.

**Resend** can cause a double run only when a ledger write that moves a message out of `accepted` or `queued` failed or hadn't landed before the restart (Risks). The handing write is awaited before the dispatch call to keep that window closed in the normal case.

## User stories

1. As the owner, I want a message the host already accepted to run at most once even if the Gateway restarts, so that the OpenClaw agent doesn't do the same work twice.
2. As the owner, I want a message my device resends after a restart (because it never got ✓✓) to get ✓✓ and not run again, so that a flaky connection costs nothing.
3. As the owner, I want a message the restart caught while the host was still preparing it to show an "Interrupted" row on each device that opens a session within 24 h, so that I know the reply is not coming.
4. As the owner, I want a message the restart caught while it waited in OpenClaw's queue to show an "Interrupted" row too, so that nothing I sent vanishes silently.
5. As the owner, I want a turn OpenClaw already had to get no Interrupted row, so that I can't cause a double run on a turn OpenClaw may resume.
6. As the owner, I want one Interrupted row per lost message, so that each Resend sends exactly that message.
7. As the owner, I want a Resend button on that row that sends the same text, attachments and quoted message as a new message, so that I can get the answer with one tap.
8. As the owner, I want the host never to rerun a lost message by itself, beyond the existing auto-retry rule, so that the OpenClaw agent never repeats an action without my tap.
9. As the owner, I want the row to say "Resent" with no button after I tap Resend on this device, so that I don't send it twice by accident.
10. As the owner, I want a run that fails for a temporary reason (a plugin reload, an overloaded or rate-limited model) before any reply or tool call to be retried after 5, 15, 30, 60 and 120 s, as before, including across a restart, so that brief outages fix themselves.
11. As the owner, I want a device that connects while a run this host process started is executing to show it as running at once, so that I don't send the message again.
12. As the owner, I want an Interrupted row to keep its state across app relaunches, and a repeat of the same error to change nothing, so that rows don't pile up or come back after I resent.
13. As the owner using an older iOS build or the Windows app, I want nothing to change, so that those apps need no update and no conversation jumps to the top of my list.
14. As the owner, I want a plugin reload (a `channels.yorozu` config change) to mark nothing interrupted, so that a reload, which is not a restart, never offers a Resend for a running turn.
15. As the owner, I want the host to keep working when its store fails, falling back to the transcript to spot repeats, so that a store failure never fails a turn.
16. As Yorozu (the agent), I want the log lines listed in Further notes, so that I can check the targets for two weeks after release.

## Implementation decisions

### Referenced decisions

| Label | Who and where | What it says |
|---|---|---|
| A1(b) | Yorozu (the agent), brief | Report lost messages with the existing `error run_failed`; no new event or field; no `resendOf`. Its "no capability, send to every client" part is replaced by CA-7. |
| Decision 1 | Owner, source spec v4 §9 | The host tells devices which turns were interrupted and which are running. Its app-side "unlisted" half is deferred (Further notes). |
| Decision 3 | Owner, source spec v4 §9 | Dedupe falls back to the transcript when the store fails. |
| Decision 5 | Owner, source spec v4 §9 | No automatic rerun after a restart; the auto-retry rule (`retry` store) is unchanged. |
| Q1 (b) | Yorozu (the agent), 2026-11-19 11:21 JST, final | Leave to OpenClaw what its restart recovery may resume; fail safe toward at-most-once. Its "nothing pending → Interrupted" branch is replaced by CA-6. |
| Q3 | Yorozu (the agent), 2026-11-19 11:21 JST, final | One Interrupted row per cut-off run, for the run's last user message. How it applies after CA-6 is below. |
| CA-6 | Yorozu (the agent), 2026-11-19 12:57 JST, final | Mark a message interrupted only when (a) the host claimed it but never handed it to OpenClaw's dispatch, or (b) OpenClaw returned it as `deferredToActiveRun: "followup"` and it never started. Everything else gets no row; the app's awaiting window ends it. No recovery classifier, no `abortedLastRun`/`status`/recovery-field reads, no pin test. Parked messages are never interrupted. Ticket 01 (dedupe only) ships alone first. "T1 ships with T2" is withdrawn. |
| CA-7 | Yorozu (the agent), 2026-11-19 12:57 JST, final | A new capability `session-report`. The plugin lists it and sends the interrupted report only to a device session whose `peer_info.capabilities` lists it, only in that session's session-open report, and never for a conversation whose OpenClaw session is gone. Peers without it get nothing new. The iOS app lists it; the Windows app doesn't until it shows the failure outside the open conversation too. |
| Agent-accepted choices | Yorozu (the agent), 2026-11-19 11:21 JST | The fixed message; Resend only on interrupted rows; the error once per device on its next session open; the once-per-process sweep marker; the 100-message cap; skipping the sweep when the retry store can't be read. |
| K3 | Source spec EGM round 4 | A per-entry process id races with reloads; use one sweep marker. |

**Q3 after CA-6.** A steered or folded message is part of a started run, so it gets no row. The only rows left are for messages that never became part of a run: one row per message. In follow-up mode each queued message would have been its own later run, so this is exactly one row per run. In collect mode several queued messages would have merged into one run; they still get one row each. Reason: the batch forms only when the queue drains, which the restart prevented, so the host can't know which messages would have merged; and each row resends its own message, so nothing is lost and nothing is sent twice. Cost: the owner may see several rows and tap several Resends, each a separate run. Accepted.

### How a message flows (context)

- **Host, plugin, Hub.** The *host* is the owner's Mac running the OpenClaw *Gateway* (the OpenClaw process). Yorozu's *plugin* (`plugins/openclaw-yorozu`) runs inside it. Its *Hub* (`src/hub.ts`) holds one encrypted *device session* per connected device.
- **Relay and direct paths.** A device reaches the Hub through the relay (`apps/relay`) or, on the same network, through the plugin's direct listener. A device can have both open for a moment, so one message can arrive twice, once on each path.
- **Device → Hub.** A device session starts with the device's `peer_info` event (its name and capabilities). The Hub then answers the device with read cursors. For each `message` event it broadcasts `delivered` (✓✓) and hands the message to the conversation module (`src/conversation.ts`).
- **Conversation module → OpenClaw.** For each message (`handleMessage`) it prepares attachments and media, resolves the conversation's OpenClaw session (one per conversation, with the conversation id as thread id), awaits OpenClaw's inbound dispatch (`runChannelInboundEvent`), and turns OpenClaw's callbacks into `typing`, `run_started`, `tool`, `reply` and `error` events.
- **OpenClaw** runs one agent run per session at a time. A message arriving during a run is, by the session's queue mode, either *steered* into the running run (the default; the dispatch returns once the message is in the transcript) or put in OpenClaw's per-process *follow-up queue* (the dispatch returns at once; the run starts later). *Collect* mode merges several queued messages into one later run (T0b B1). On a restart, OpenClaw may resume a cut-off run itself ("restart recovery", T0 answer 1). Its follow-up queue is lost (T0b B2).

### Glossary

| Term | Meaning |
|---|---|
| Restart | The Gateway process stops and starts (an update, `openclaw gateway restart`, or a crash). A plugin reload (`startAccount` again in the same process) is not a restart. |
| Boot id | `"<pid>:<Math.round(performance.timeOrigin)>"`: the same across plugin reloads and module re-imports, new after a restart. |
| Turn | The host's handling of one message: one `handleMessage` call. |
| Handed | The host has called OpenClaw's dispatch for the message. |
| Executing | A run is executing only while the turn whose `onAgentRunStart` started it is still awaiting its dispatch. It stops in that turn's `finally`. A follow-up run is never executing after its dispatch returned (CA-1). |
| Run ledger | The host's record of accepted messages, keyed by message id. In memory, loaded once per process, written through to keyed-store namespace `runs`. |
| Ledger states (ticket 02) | `accepted`: claimed, not handed yet. `queued`: OpenClaw deferred it as a follow-up and it hasn't started. `settled`: the host will never report it. `interrupted`: the start-up sweep found it lost. An entry without a state (written by ticket 01 alone) reads as `settled`. |
| Parked | A turn that failed for a temporary reason before any reply or tool call and waits in the `retry` store for its next attempt (the owner's auto-retry rule). |
| Start-up sweep | The one pass per process that marks `accepted` and `queued` entries of an earlier process `interrupted` or `settled`. |
| Sweep sequence | A number each sweep that marks anything takes, one higher than any before. Stored with the marker and on each entry it marks. |
| `session-report` | The new `peer_info` capability: "send me interrupted messages and executing runs at session open". |
| Session-open report | What the host sends one device right after its `peer_info`: read cursors (existing), then, only if the device listed `session-report`, the interrupted errors it hasn't been told about, then `run_started` for executing runs. |
| Interrupted error | `error {code: "run_failed", message: "interrupted by a host restart", convId, messageId}`. |
| Interrupted row, Resend | The app's row for an interrupted error, and the owner's tap on it that sends the original again as a new message. |
| Awaiting window, stall banner | The app's 10-minute limit on waiting for a reply, and the banner it shows when a running turn makes no progress for 5 minutes. |
| Degraded mode | The ledger store couldn't be read at start-up; the transcript check stands in for it. |
| Transcript check | A synchronous read of the conversation's OpenClaw transcript for a user message with that transport message id. |
| Target 0 | The measure's target: the log line should never appear. |

### Ticket 01: run ledger as a durable dedupe set

**Record:** `{convId, at}` per message id (`at` = host receipt time, ms; never sent to devices).

**Store.** Namespace `runs`, `{maxEntries: 10_000, overflowPolicy: "evict-oldest"}`, like `replies`. Each id's writes go through one promise chain, so they land in call order (ticket 02 adds more writes). A failed write logs `yorozu: run ledger write failed: <error>` and never fails a turn.

**Pruning.** On load, entries older than 24 h are dropped from the map and deleted from the store (from `at`; from `interruptedAt` for `interrupted` entries once ticket 02 lands). On each claim the map drops entries past the same age and the oldest beyond 10,000, as the Hub's id list does now. The store's `defaultTtlMs` is not used: it counts from the last write, and ticket 02 rewrites entries, so it can't express "24 h from receipt" or "24 h from marking".

**Claim (synchronous)**, on every `message` event in the Hub, before `delivered`:

1. The Hub calls the injected `claim(message)`.
2. Unknown id: a new entry goes into the map, its store write starts without being awaited, and `claim` returns `"fresh"`.
3. Known id: `claim` logs `yorozu: duplicate message skipped <messageId>` and returns `"duplicate"`.
4. The Hub broadcasts `delivered` in both cases. It runs a fresh message (`onMessage`) and does nothing more for a duplicate, as `hub.ts` does today (CA-8).

**Degraded mode (decision 3).** If the `runs` store can't be read at start-up, the host logs `yorozu: run ledger unavailable: <error>` and starts with an empty map. The claim checks the map first. On a miss it runs the transcript check:

- found: duplicate, entered in the map;
- missing: fresh;
- read failed: fresh, logged `yorozu: run ledger transcript check failed: <error>`.

New entries still go into the map and the store. The transcript check reuses history's matching (`history.ts` `itemsOf`, `:214`, which keys user items by transport message id, `:403`), so there is no second scanner. It is synchronous and runs on the event loop for every message while degraded. Moving it off the event loop and retrying the store load in the background are deferred until `run ledger unavailable` shows up in the logs (CN-1). Why the fallback exists: dedupe protects at-most-once.

**Run log line.** Each run start logs `yorozu: run started <messageId> attempt <n> boot <bootId>`. The first attempt is 0; a parked rerun counts up.

**Wiring.** `startAccount` opens the ledger and passes `claim` through `RelayHostOptions` to the Hub. Without `claim`, the Hub keeps its in-memory id list, so the Hubs built without one in `apps/relay/src/direct.test.ts:57` and `apps/windows/conformance/host/fake-host.ts:39` behave as before. The Hub still imports only Node built-ins and wire files (standalone typecheck).

### Ticket 02: lost-message tracking, sweep and gated report

**Record fields added:** `state` (`accepted`, `queued`, `settled`, `interrupted`), `interruptedAt?` (wall-clock time of the sweep that marked it), `sweep?` (that sweep's sequence). No run keys: Q3 now needs none.

**Writers.** These are the only places that change state. A writer for an id the map lacks (a parked message whose entry was pruned) first inserts it with `at` = now.

| # | When | Change |
|---|---|---|
| 1 | Claim | `accepted`. |
| 2 | Just before `await runChannelInboundEvent(…)` | `settled`. This write is awaited before the dispatch call, so a restart after OpenClaw got the message never finds it `accepted`. A failed write logs and the dispatch still runs. |
| 3 | The dispatch returns `deferredToActiveRun: "followup"` and the message's own `onAgentRunStart` hasn't fired | `queued`. |
| 3b | It returns `"steer"`, no deferral, or `"followup"` after the start fired | No change. |
| 3c | Any other value | No change; warns `yorozu: unknown dispatch deferral <value> <messageId>` (CN-12). |
| 4 | `onAgentRunStart` for X after X's dispatch returned (a follow-up started from the queue) | X `settled`, and every earlier `queued` entry of that conversation too: a collected batch fires only its last item's start (T0b B1). |
| 5 | X's outer `finally`, X not parked, X still `accepted` (failed in preparation; the error was already sent) | `settled`. |

A parked message keeps its state; the retry store holds it, its rerun passes writer 2 again, and the sweep never touches it.

**Start order** in `startAccount`:

1. Load the existing stores (attachment index, message times, replies, reactions).
2. Open and load the ledger.
3. Sweep.
4. `watchSessions`.
5. The retry loop (`runParked`).
6. The gateway notice (`announceGatewayState`).
7. The relay host.

Nothing is broadcast during the sweep: no device has a session yet.

**Once per process.** A persisted marker (namespace `run-sweep`, `retention: "retained"`, one key `last`, value `{bootId, seq}`) holds the boot id and sweep sequence of the last sweep. The sweep runs only when the boot id differs. Why persisted rather than a module-level flag (CN-3): a plugin registry reload can re-import the module in the same process, which resets module state, and a flag would then mark the current process's own preparing turns interrupted. The boot id survives a re-import, and one marker avoids K3's race with reloads.

If the marker can't be read, the retry store can't be read, or the ledger is degraded, there is no sweep and no marker write, logged `yorozu: restart sweep skipped: <reason>`.

**Sweep procedure.**

1. Read the message ids the `retry` store holds (`parkedMessages`).
2. Take the `accepted` and `queued` entries, leaving out parked ids.
3. Check each conversation's OpenClaw session once (`sessionState`, below):
   - **gone:** its entries become `settled`, logged `yorozu: turn settled, no session <messageId>`. This covers a conversation deleted on any device.
   - **unreadable:** its entries become `settled`, one warning `yorozu: session unreadable, not marking interrupted: <reason>`.
   - **exists:** its entries become `interrupted`, logged `yorozu: turn interrupted by restart <messageId>`, with `interruptedAt` = now and `sweep` = seq, where seq is one more than the larger of the marker's seq and the highest `sweep` on any entry.
4. Await every entry's write chain, then write the marker. A failed entry write still lets the marker be written; the chain already logged it.

The sweep never queues, parks or runs anything (decision 5). It reads only whether the session entry exists: `getSessionEntry({agentId, sessionKey})` returning `undefined` is gone (as `history.ts:216` and `sessions.ts:50` already read it). No OpenClaw recovery field is read.

**Session-open report**, in the per-device `peer_info` hook (`relay.ts` `onPeer`, `:302`), after the read cursors, to that device only:

0. **Gate.** If the device's `peer_info.capabilities` doesn't list `session-report`, send nothing more and leave its watermark alone. A device that later upgrades gets, once, the messages of the last 24 h it was never told about.
1. **Pick.** `interrupted` entries whose `sweep` is above this device's watermark and whose `interruptedAt` is within 24 h, newest first (by `sweep`, then `at`), at most 100.
2. **Re-check.** Check each conversation's session again (once per conversation per report). Gone or unreadable: its entries become `settled`, logged `yorozu: interrupted message withdrawn <messageId> (<no session|unreadable>)`, and nothing is sent for them.
3. **Send** one interrupted error per remaining message.
4. **Watermark.** Set this device's watermark to the highest `sweep` considered in step 1, including dropped and withdrawn ones. Store: namespace `run-told`, `retention: "retained"` like every per-device store, key = the device's public signing key as the allowlist stores it, value `{seq}`. Written through, not awaited by the report.

Nothing is queued for a device without a session: the report goes out only when a session opens, so `docs/ios-relay-contract.md:435` stays as it is.

**No `typing false` (CN-4 revisited).** v3 sent `typing false` for the Windows app, which doesn't clear typing on `run_failed` (`apps/windows/core/src/sync.rs:253-265`). Only devices listing `session-report` get the report now, and the iOS app stops typing on an interrupted error itself (ticket 04, existing `setTyping(convId, false)`), so it is dropped.

**Once per device.** Interruptions come only from sweeps, so one sequence watermark per device replaces per-entry device lists. A sequence number can't hide messages when the wall clock steps back (CN-2); only the 24 h window uses the wall clock. A lost send leaves the device on the awaiting window. A repeat, after a failed watermark write, is harmless: the app's error row has a fixed id per message.

**Forgetting a device.** The relay host's `forget` (`relay.ts:322-328`), which unpair (`relay.ts:130-134`), device removal and pairing eviction all reach, also calls `deviceForgotten(deviceKey)`, which deletes that device's watermark. A re-paired device gets the messages of the last 24 h once.

**Capability.** `SESSION_REPORT = "session-report"` in `plugins/openclaw-yorozu/src/envelope.ts` next to `REPLIES` and `REACTIONS`, with a doc comment naming what it gates (`OWNER_DECISIONS.md:131`), and added to `PEER_INFO.capabilities`. Why this name: it gates everything the session-open report adds after the read cursors, including ticket 03's `run_started`, not only restart reports. The reason text `INTERRUPTED_REASON = "interrupted by a host restart"` sits beside it.

**Live Activity.** No change.

### Ticket 03: `run_started` at session open (S4)

**Executing signal (CA-1).** `runningTurns` (`conversation.ts:81,288,308`) stays as it is: it is a start marker used to file outbound cards, and a follow-up whose start fires after its turn's `finally` leaves a stale entry there (T0b B5). Ticket 03 adds a separate map, `executing` (`convId → messageId`):

- `handleMessage` sets a local flag `awaiting` just before `await runChannelInboundEvent(…)` and clears it right after the await. (Ticket 02's writers 3 and 4 use the same flag.)
- `onAgentRunStart` sets `executing[convId] = messageId` only while `awaiting` is set.
- The inner `finally` deletes `executing[convId]` if it still names this message.

Every entry ends in the `finally` of the call that set it. A follow-up whose start fires before its dispatch returns is executing only until that return.

**Report.** After the interrupted errors, the report adds `run_started {convId, messageId}` for each entry of `executing`, behind the same `session-report` gate.

**Why gated.** `run_started` is an existing kind, and its meaning ("the run for this message started") holds. But sending it at session open for a run that started earlier is new sending behaviour, and `OWNER_DECISIONS.md:128` says a sender uses new behaviour only when the other side listed it. Clients also read `run_started` as the read mark (`docs/ios-relay-contract.md:432`) and as a cue to fetch history (`:346`), so a replay could act differently on clients nobody tested it with. CA-7 just rejected the same "existing kind, so not new" reading for `run_failed`. So it is gated on `session-report`. Cost: S4 helps only the iOS app, after ticket 04 ships; others keep the typing keepalive (up to 8 s).

### Module interfaces (frozen per ticket)

`src/ledger.ts` is a pure factory. It imports only Node built-ins, `envelope.ts` and the `Keyed` type from `cards.ts`, and it is added to `tsconfig.standalone.json`. `src/runs.ts` is a thin runtime binding, as `presentations.ts` binds `cardStore` (`cards.ts:133`).

```ts
// src/ledger.ts — ticket 01
export type RunRecord = { convId: string; at: number; state?: RunState; interruptedAt?: number; sweep?: number }; // state etc.: ticket 02
export type Store<T> = Keyed<T> & { entries(): Promise<{ key: string; value: T }[]> };
export type LedgerDeps = {
  runs: () => Store<RunRecord>;          // namespace "runs"
  now: () => number;
  bootId: string;
  log: { info(line: string): void; warn(line: string): void };
  inTranscript: (convId: string, messageId: string) => "found" | "missing" | "unreadable";
  // ticket 02:
  marker: () => Keyed<SweepMarker>;      // namespace "run-sweep"
  told: () => Keyed<Told>;               // namespace "run-told"
  parked: () => Promise<Set<string>>;    // rejects when the retry store can't be read
  sessionState: (convId: string) => "exists" | "gone" | "unreadable";
  // ticket 03:
  executing: () => ReadonlyMap<string, string>;   // convId → messageId of the executing run
};
export function createLedger(deps: LedgerDeps): Ledger;
export type Ledger = {
  load(): Promise<"loaded" | "degraded">;          // once per instance; later calls return the first result
  claim(message: Message): "fresh" | "duplicate";
  runStarted(messageId: string, attempt: number): void;            // log line
  idle(): Promise<void>;                           // every pending write chain settled (tests, sweep)
  // ticket 02:
  handing(messageId: string, convId: string): Promise<void>;       // writer 2, awaited
  dispatchReturned(messageId: string, convId: string, deferred: unknown, started: boolean): void;
  startedAfterReturn(messageId: string, convId: string): void;     // writer 4
  turnEnded(messageId: string, convId: string, parked: boolean): void;
  sweep(): Promise<void>;
  report(deviceKey: string, capabilities: readonly string[]): Promise<Event[]>;  // [] without SESSION_REPORT
  forgetDevice(deviceKey: string): Promise<void>;
};
// ticket 02:
export type RunState = "accepted" | "queued" | "settled" | "interrupted";
export type SweepMarker = { bootId: string; seq: number };
export type Told = { seq: number };

// src/runs.ts (binding; imports runtime.ts, history.ts, and in later tickets retry.ts, sessions.ts, conversation.ts)
export function openLedger(ctx: { cfg: OpenClawConfig; agent: string; log?: ChannelGatewayContext["log"] }): Promise<Ledger>;
//   First call: creates the ledger with the runtime stores and boot id, loads it. Later calls (reloads) update the
//   bound cfg, agent and log and return the same instance.
export function currentLedger(): Ledger | undefined;

// ticket 01  src/history.ts:   export function findUserMessage(cfg, agent, convId, messageId): "found" | "missing" | "unreadable";
// ticket 01  src/hub.ts HubOptions:        claim?: (message: Message) => "fresh" | "duplicate";
// ticket 01  src/relay.ts RelayHostOptions: claim?: HubOptions["claim"];
// ticket 02  src/retry.ts:     export function parkedMessages(): Promise<Set<string>>;
// ticket 02  src/sessions.ts:  export function sessionState(agent: string, convId: string): "exists" | "gone" | "unreadable";
// ticket 02  src/relay.ts RelayHostOptions: sessionOpen?: (deviceKey: string, capabilities: readonly string[]) => Promise<Event[]>;
//                                           deviceForgotten?: (deviceKey: string) => void;
// ticket 03  src/conversation.ts: export function executingRuns(): ReadonlyMap<string, string>;
```

The Hub and relay modules don't import the ledger or the conversation module; `startAccount` passes the callbacks. `runtime.ts:1` imports `openclaw/plugin-sdk/runtime-store`, which isn't installed in CI, so Hub tests build a ledger with `createLedger` over fake stores and inject its `claim`; they never import `runs.ts`. The gate lives in `report`, so it is tested on the pure factory.

**Restart seam for tests.** A restart is a new `createLedger` over the same fake store objects with a new `bootId`, plus a new Hub. A module re-import is a new `createLedger` with the same `bootId`. A reload is a second `load()` on the same instance.

### Wire (ticket 02 docs; ticket 04 constant)

- **New capability** `session-report`: plugin constant `SESSION_REPORT` (`envelope.ts`), client constant `SessionReport.capability` (`packages/YorozuWire`, a `public enum` like `UnversionedWire` in `Wire.swift:5-7`, with `public static let interruptedReason = "interrupted by a host restart"`). The contract's capability table (`docs/ios-relay-contract.md:286`) and constants table (`:482`) get it; a short section next to the read cursors describes the gated report: only to a session whose client listed it, only at session open, interrupted errors then `run_started` for executing runs, never for a conversation whose OpenClaw session is gone.
- **`run_failed` reason:** `message` exactly `interrupted by a host restart` means a restart lost the message before OpenClaw held it and the host will not run it by itself. A client may show its own text and offer Resend for it. Every other `run_failed` keeps its meaning. The contract's error table carries the exact string; each side keeps it as a constant, with a test on each side (CN-5: the Swift side's constant now lives in YorozuWire beside the capability, since the package changes anyway).
- **Dedupe promise** (`docs/ios-relay-contract.md:433`, "remembered 24 h, up to 10,000") keeps its bounds and now holds across restarts (ticket 01), with the limits in "Promises and their limits".
- **Unchanged:** no new event kind or field; `:435` ("Nothing is queued for a device without a session") stays.

**Older peers.**

| Peer | What changes |
|---|---|
| Older iOS builds, Windows app | Nothing: they don't list `session-report`, so they get no report, no `typing false` and no `run_failed` replay. |
| Older hosts | Never list `session-report` or send the report; the new app keeps today's behaviour with them. |

The Windows app doesn't list the capability until it shows a `run_failed` outside the open conversation too (today it flags one only in the open conversation or its outbox, `apps/windows/core/src/sync.rs:253-265`, `outbox.rs:166-176`). That change is out of scope.

### Ticket 04: app capability, Interrupted row and Resend

**Capability.** `SessionReport.capability` is added to the app's `peer_info` capabilities (`apps/ios/Sources/Client/AppModel.swift:393-394`).

**Recognising it.** An `error` with code `run_failed`, `message` equal to `SessionReport.interruptedReason`, a valid conversation id and a message id.

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

**Strings** (`apps/ios/Resources/Localizable.xcstrings`; source language en, the key is the English text). "Interrupted" now covers a message the host was preparing or that waited in the queue, so the first string no longer says "during this reply":

| Key (en) | ja | zh-Hans | zh-Hant | ko | es | fr | de | pt-BR |
|---|---|---|---|---|---|---|---|---|
| Interrupted: the host restarted before this message ran. | 中断: このメッセージの実行前にホストが再起動しました。 | 已中断：此消息运行前主机重新启动了。 | 已中斷：此訊息執行前主機重新啟動了。 | 중단됨: 이 메시지가 실행되기 전에 호스트가 다시 시작되었습니다. | Interrumpido: el anfitrión se reinició antes de procesar este mensaje. | Interrompu : l’hôte a redémarré avant le traitement de ce message. | Unterbrochen: Der Host wurde neu gestartet, bevor diese Nachricht verarbeitet wurde. | Interrompido: o host reiniciou antes de processar esta mensagem. |
| Resend | 再送信 | 重新发送 | 重新傳送 | 다시 보내기 | Reenviar | Renvoyer | Erneut senden | Reenviar |
| Resent | 再送信済み | 已重新发送 | 已重新傳送 | 다시 보냄 | Reenviado | Renvoyé | Erneut gesendet | Reenviado |
| Resend appears once this message loads. | このメッセージを読み込むと再送信できます。 | 此消息加载后即可重新发送。 | 此訊息載入後即可重新傳送。 | 이 메시지를 불러오면 다시 보낼 수 있습니다. | Podrás reenviar cuando se cargue este mensaje. | Le renvoi sera possible une fois ce message chargé. | Erneutes Senden ist möglich, sobald diese Nachricht geladen ist. | Será possível reenviar quando esta mensagem carregar. |

**Resend.** `AppModel.resend(_ row: ChatItem, in convId: String)`:

1. Does nothing unless the row is `offered` and the conversation holds the original user item.
2. Calls a new `send` overload that takes a stored `ReplyTo` (`send(_:attachments:in:messageId:replyTo:)`) with a fresh id, the original's text, its `replyTo`, and its attachments that have no `failure`. The ids are reused: the host already holds those files.
3. Sets the row to `sent`. A second tap does nothing. Nothing is sent without the tap.

**Shared attachment files.** After a Resend, two items name the same attachment ids. `discard` (`AppModel.swift:1030-1037`) deletes files by attachment id (`Transfers.swift:65-67`). It now deletes a file only when no other item in any conversation still names that attachment id. Deleting a conversation still deletes all its files: both items are in it.

**Other devices.** Each device shows its own Resend; two devices can each resend once (two deliberate taps; accepted). Siri's wait ends on an `.error` item; `needsAttention` turns on, as for any failed turn.

**`run_started` at session open** needs no app change: the app already handles `run_started`.

### Tickets, PRs and files

Paths are repo-relative. One PR per ticket, in this order.

| Ticket | PR | Blocked by | Release on merge |
|---|---|---|---|
| 01 Run ledger (dedupe) | Plugin PR 1 | — | Release Mac (`plugins/**`); Deploy website (`apps/mcp/src/**`, regenerated help bundle) |
| 02 Lost-message tracking, sweep, gated report | Plugin PR 2 | 01 | Release Mac; Deploy website |
| 03 `run_started` at session open | Plugin PR 3 | 02 | Release Mac; Deploy website if the README changes |
| 04 App capability, row, Resend | App PR | None to merge (the app works with any host); an end-to-end check needs 02 | Release iOS and Release Mac (`apps/ios/**`, `packages/**`) |

| Ticket | Action | Path | What |
|---|---|---|---|
| 01 | Create | `plugins/openclaw-yorozu/src/ledger.ts` | Pure factory: load, claim, pruning, degraded mode, run log line. |
| 01 | Create | `plugins/openclaw-yorozu/src/runs.ts` | Runtime binding: store, boot id, transcript check. |
| 01 | Modify | `plugins/openclaw-yorozu/src/hub.ts` | `claim` option. |
| 01 | Modify | `plugins/openclaw-yorozu/src/relay.ts` | Pass `claim` to the Hub. |
| 01 | Modify | `plugins/openclaw-yorozu/src/conversation.ts` | Run log line call. |
| 01 | Modify | `plugins/openclaw-yorozu/src/history.ts` | `findUserMessage`. |
| 01 | Modify | `plugins/openclaw-yorozu/src/channel.ts` | `openLedger`, pass `claim`. |
| 01 | Modify | `plugins/openclaw-yorozu/tsconfig.standalone.json` | Add `src/ledger.ts`. |
| 01 | Create | `plugins/openclaw-yorozu/test/ledger.test.ts` | Claim, degraded mode, pruning, write order. |
| 01 | Create | `plugins/openclaw-yorozu/test/hub-ledger.test.ts` | Hub with an injected claim; restart seam. |
| 01 | Modify | `plugins/openclaw-yorozu/test/genui-host.js` | Fake keyed store extensions (Testing). |
| 01 | Modify | `plugins/openclaw-yorozu/test/hub-host.ts` | Optional `claim`. |
| 01 | Modify | `docs/ios-relay-contract.md` | Dedupe line (`:433`). |
| 01 | Modify | `docs/openclaw-channel.md` | The `runs` store. |
| 01 | Modify | `plugins/openclaw-yorozu/README.md` | Run ledger section. |
| 01 | Modify | `apps/mcp/src/content.json` | Regenerated help bundle. |
| 02 | Modify | `plugins/openclaw-yorozu/src/envelope.ts` | `SESSION_REPORT`, `INTERRUPTED_REASON`, `PEER_INFO.capabilities`. |
| 02 | Modify | `plugins/openclaw-yorozu/src/ledger.ts` | States, writers, sweep, gated report, watermark. |
| 02 | Modify | `plugins/openclaw-yorozu/src/runs.ts` | Marker and told stores, `parked`, `sessionState`. |
| 02 | Modify | `plugins/openclaw-yorozu/src/conversation.ts` | `awaiting` flag, writer calls 2–5. |
| 02 | Modify | `plugins/openclaw-yorozu/src/retry.ts` | `parkedMessages`. |
| 02 | Modify | `plugins/openclaw-yorozu/src/sessions.ts` | `sessionState`. |
| 02 | Modify | `plugins/openclaw-yorozu/src/channel.ts` | Start order, sweep, `sessionOpen`, `deviceForgotten`. |
| 02 | Modify | `plugins/openclaw-yorozu/src/relay.ts` | Report after the read cursors; `deviceForgotten` in `forget`. |
| 02 | Create | `plugins/openclaw-yorozu/test/sweep.test.ts` | Writers, sweep, gate, report, watermark (pure factory + Hub). |
| 02 | Create | `plugins/openclaw-yorozu/test/conversation-ledger.test.ts` | Writers through the stand-in host. |
| 02 | Create | `plugins/openclaw-yorozu/test/sweep-retry.test.ts` | Real retry module with mock timers. |
| 02 | Modify | `plugins/openclaw-yorozu/test/genui-host.js` | Dispatch stub returns `deferredToActiveRun`; start before or after return. |
| 02 | Modify | `plugins/openclaw-yorozu/test/presentations.test.ts` | Start order. |
| 02 | Modify | `docs/ios-relay-contract.md` | Capability rows (`:286`, `:482`); `run_failed` reason row; gated session-open report. |
| 02 | Modify | `docs/openclaw-channel.md` | `deferredToActiveRun`, follow-up start timing, session-existence read. |
| 02 | Modify | `plugins/openclaw-yorozu/README.md` | Tracking, sweep and report. |
| 02 | Modify | `apps/mcp/src/content.json` | Regenerated help bundle. |
| 03 | Modify | `plugins/openclaw-yorozu/src/conversation.ts` | `executing` map, `executingRuns`. |
| 03 | Modify | `plugins/openclaw-yorozu/src/ledger.ts` | `run_started` in the report. |
| 03 | Modify | `plugins/openclaw-yorozu/src/runs.ts` | Pass `executing`. |
| 03 | Create | `plugins/openclaw-yorozu/test/executing.test.ts` | Executing signal and report. |
| 03 | Modify | `docs/ios-relay-contract.md` | `run_started` in the gated report. |
| 03 | Modify | `apps/mcp/src/content.json` | Regenerated help bundle. |
| 04 | Modify | `packages/YorozuWire/Sources/YorozuWire/WireEvent.swift` | `SessionReport` enum: `capability`, `interruptedReason`. |
| 04 | Create | `packages/YorozuWire/Tests/YorozuWireTests/SessionReportTests.swift` | Constant values. |
| 04 | Modify | `apps/ios/Sources/Client/Store.swift` | `ResendState`, `ChatItem.resend`, stray-error rule, merge upgrade. |
| 04 | Modify | `apps/ios/Sources/Client/AppModel.swift` | Capability, error case, `interrupted`, `resend`, `send` overload, `discard`. |
| 04 | Modify | `apps/ios/Sources/YorozuIOS/Chat.swift` | Row look. |
| 04 | Modify | `apps/ios/Resources/Localizable.xcstrings` | Four strings, nine languages. |
| 04 | Modify | `apps/ios/Tests/Support/Transports.swift` | `ScriptedTransport.sentMessages`. |
| 04 | Create | `apps/ios/Tests/AppModelInterruptedTests.swift` | Ticket 04 tests. |

No files are deleted. `apps/ios/Project.swift` needs no change: the YorozuTests target lists `"Tests/**"` (`Project.swift:250`), so the new test file is compiled. The target has no resources, so test 04 #11 reads the strings file from the source tree: `URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../Resources/Localizable.xcstrings")`, as `YorozuActivityTests.swift:113` reads its fixture.

## Testing decisions

**Seams, highest first.**

- **Ledger:** `createLedger` over fake stores, a fake clock and boot ids. The restart seam is in "Module interfaces".
- **Hub:** the existing fake host and Noise device harness (`hub-host`), with a claim from `createLedger`.
- **Conversation and writers:** the existing stand-in host for OpenClaw (`genui-hooks` maps the runtime and Gateway-bound modules to `genui-host.js`). Extend its fake keyed store rather than copying it: no eviction when `maxEntries` is undefined (today it would wipe the retained `retry` store); an `entries` failure mode, a write recorder and a slow mode; reopen over the same rows. Ticket 02 adds to the stub's dispatch a way to return `dispatchResult.deferredToActiveRun` and to fire `onAgentRunStart` before or after the dispatch returns.
- **Retry interplay:** a resolve hook scoped to the module under test loads the **real** retry module while the runtime stays the stub, with `node:test` mock timers for the 5 s tick. Precedent: `conversation-owner.test.ts:146`.
- **Start order:** recording stubs for the retry, ledger and relay modules on the existing `startAccount` test base in `presentations.test.ts`.
- **OpenClaw types:** no pin test. The only OpenClaw shape the design reads beyond today's code is `dispatchResult.deferredToActiveRun`, checked by the full plugin typecheck against `~/openclaw`.
- **App:** `ModelHarness` with `ScriptedTransport`. `ScriptedTransport.send(_ message:)` records nothing today; ticket 04 adds `sentMessages`.

**What a good test checks:** the events each device receives, whether `onMessage` ran, log lines, the store's rows after a reopen, the app's items and sent messages. Not private maps.

**Prior art:** `hub-events`, `hub-session` (Hub); `genui-golden`, `prerun-error`, `conversation-owner` (conversation); `activitywatch` U6/U7 (Live Activity restore); `AppModelSyncTests` (app); `presentations.test.ts` (`startAccount`); `UnversionedWireTests` (capability constant).

Each PR's first code commit holds only red tests; the PR body names each and its failure on the parent.

**Red tests, ticket 01.**

1. A restart (new ledger and Hub over the same store) and M again: `onMessage` ran once; `delivered` went out both times; one `duplicate message skipped`.
2. A duplicate of M while M runs gets only `delivered`: no `run_started`, `typing` or `error`.
3. Degraded ledger, transcript holds M: M doesn't run.
4. Degraded ledger, transcript read fails: M runs; `run ledger transcript check failed` logged.
5. Degraded ledger: a second copy of M in the same process is a duplicate without a transcript read.
6. Writes for one id land in call order with a slow store; a failed write logs and the turn completes.
7. Pruning: entries older than 24 h are dropped on load; the map stays within 24 h and 10,000 on claims.
8. `run started <id> attempt 0 boot <bootId>` on the first run; a parked rerun logs attempt 1.
9. Guards: relay and direct copies of M arriving together run once; a Hub without `claim` behaves as before (`pnpm --filter @yorozu/relay test` and `bash apps/windows/ci/core.sh` pass unmodified).

**Red tests, ticket 02.** "Capable device" lists `session-report`.

1. Preparation cut off: M claimed, restart before its dispatch call, session exists: `interrupted`, logged once; a capable device gets one interrupted error for M, after the read cursors, to that device only.
2. Handed: M's dispatch called with no deferral (run started, then a restart): nothing marked, no error.
3. Steered: M's dispatch returns `"steer"`: no error after a restart.
4. Queued: M2 and M3 return `"followup"` behind M1 and never start, restart: M1 nothing; M2 and M3 `interrupted`; a capable device gets one error each (Q3).
5. A follow-up whose start fires after its dispatch returned settles it and the earlier queued entries of that conversation; a restart then marks nothing.
6. A follow-up whose start fires before its dispatch returns `"followup"` stays `settled`.
7. The handing write is awaited before the dispatch call; a failed handing write logs and the dispatch still runs.
8. A pre-dispatch failure (`attachment_missing`) settles M; a restart marks nothing.
9. An unknown `deferredToActiveRun` value changes nothing and logs `unknown dispatch deferral`.
10. A parked id stays as it is; the real retry loop still reruns it on schedule; the sweep doesn't mark it.
11. A second `startAccount` in the same process sweeps nothing; a new ledger with the same boot id (module re-import) sweeps nothing.
12. A retry-store read failure, a marker read failure and a degraded ledger each skip the sweep and write no marker.
13. Start order: stores → ledger → sweep → `watchSessions` → retry loop → gateway notice → relay host.
14. Gate: a device without `session-report` gets only the read cursors (no `typing`, no `error`) and its watermark is untouched; two capable devices each get the error once; a reconnect and a second restart send nothing more.
15. No session at the sweep: `settled`, `turn settled, no session` logged; a throwing session read: `settled`, one warning; session gone by the report: nothing sent, `interrupted message withdrawn` logged.
16. At most 100 errors per report; entries older than 24 h are skipped; a wall-clock step back of an hour hides nothing.
17. A duplicate of an `interrupted` message gets only `delivered` and doesn't run.
18. Unpairing a device deletes its watermark; after re-pairing it gets the last 24 h once.
19. The marker is written after every entry chain settles, also when one entry write failed.
20. An entry written by ticket 01 (no `state`) is never marked.
21. The plugin's `peer_info` lists `session-report`.
22. Guard: an interrupted turn's Live Activity job still ends on restore.

**Red tests, ticket 03.**

1. A capable device opening a session while M's run executes gets `run_started {convId, messageId}` after any errors; a device without the capability gets nothing new.
2. A follow-up whose start fires before its dispatch returns is in `executingRuns` until the return, then not.
3. A follow-up whose start fires after its turn's `finally` is never in `executingRuns`.
4. After a follow-up has run, a session open gets no `run_started`; a parked or preparing turn gets none either.

**Red tests, ticket 04.**

1. The app's `peer_info` lists `session-report`; `SessionReport.capability == "session-report"` and `interruptedReason` match the plugin's strings.
2. An interrupted error appends one Interrupted row with Resend, and clears typing, stall and awaiting for that conversation.
3. The same error again adds no row and keeps a `sent` state.
4. Resend sends exactly one new message (new id; same text, `replyTo` and attachment ids without a failure); the row shows "Resent" with no button; a second tap sends nothing.
5. Nothing is sent without the tap, across a reconnect.
6. The row state survives a relaunch (store round trip), including an `unavailable` row whose message the app doesn't hold.
7. An `unavailable` row becomes `offered` when a history page brings its message.
8. An interrupted error for an unknown conversation creates nothing.
9. An existing `error:<id>` row without `resend` is replaced in place by the Interrupted row.
10. Discarding the queued resent message keeps the original's attachment files.
11. A `run_failed` with any other message keeps the old row with no Resend; the four strings exist in all nine languages, read from `Localizable.xcstrings` as above.

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
# App (ticket 04):
tuist generate --no-open --path apps/ios
xcodebuild test -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuTests -destination 'platform=macOS'
env -u SDKROOT swift test --package-path packages/YorozuWire
```

## Alternatives considered

- **The v4 source-spec shape: a new `turn_state` event, a `turnState` capability, a `resendOf` field and a host-side Resend guard.** Not taken (A1(b)); CA-7 adds only a capability, not the event or field.
- **The v3 recovery classifier.** Read `abortedLastRun`, `status` and OpenClaw's recovery fields through `getSessionEntry` to mark started runs interrupted when OpenClaw seemed not to hold them, with a re-check at report time and a pin test against OpenClaw 2026.9.8. Rejected by CA-6: it copied part of OpenClaw's private custody logic, depended on fields OpenClaw may reshape, and left a gap where Resend could double a run OpenClaw recovered.
- **Ungated A1(b): send the report to every client.** Rejected by CA-7: older iOS builds would move up to 100 conversations to the top of the list (against `OWNER_DECISIONS.md:84`), the Windows app would flag only some, and the "existing kind, so not new behaviour" reading of `OWNER_DECISIONS.md:128` was the agent's, not the owner's.
- **Automatic requeue after a restart.** Withdrawn by decision 5.
- **T0 option (c): opt Yorozu turns out of OpenClaw's restart recovery.** Not available: OpenClaw 2026.9.8 has no per-channel or per-run opt-out (T0b B4).
- **T0 option (d): measure first, build later.** Partly taken by CA-6: ticket 01 ships alone first and its logs give the first incident data.
- **Relying on OpenClaw's own message dedupe.** Not enough. OpenClaw's `MessageSid` cache is memory-only. Its durable source-turn check does survive a restart (T0 answer 2), but only while the session keeps a matching active claim or terminal source id, and only for messages OpenClaw already received. The host still needs its own dedupe for messages it accepted and never handed over (preparing, or lost with the follow-up queue), and to avoid repeating preparation work (attachment staging, the push title, the `attachment_missing` error) (CA-9).
- **A per-entry boot id instead of one sweep marker.** Not taken (K3).
- **A module-level "swept" flag instead of a persisted marker.** Not taken: a module re-import in the same process would sweep again.
- **A wall-clock watermark.** Not taken: a clock step back hides messages. A sweep sequence costs one more field.
- **Waiting for the claim write before `delivered`.** Not taken: it changes ✓✓ from "received and decrypted" (`OWNER_DECISIONS.md`) and adds an async step to close a short gap. The handing write, by contrast, is awaited, because it sits in preparation time and guards Resend.
- **A new distinguishing field on `error`.** Not taken: a wire change the capability makes unnecessary.
- **Extra events for a duplicate (`run_started`, the interrupted error).** Dropped (CA-8).
- **Ungated `run_started` at session open.** Not taken (ticket 03, "Why gated").
- **A complete "still running" listing with the app's unlisted rule.** Deferred (Further notes).
- **Transcript only, no store.** Not taken: queued messages aren't in the transcript. Kept as the degraded fallback (decision 3).
- **Removing the Hub's in-memory list and requiring a ledger.** Not taken: the relay and Windows conformance Hubs are built without one.

## Risks

| Risk | Mitigation or check |
|---|---|
| A restart between the claim and its store write loses the entry | Accepted: that message behaves as before the change. Measured by `run started <id> attempt 0` under two boot ids. |
| A failed handing write (writer 2) or writer 4/5 write leaves an `accepted` or `queued` entry for a message OpenClaw held | The next restart marks it interrupted, and a Resend may run it twice. Logged as `run ledger write failed`; target 0. |
| A restart between a follow-up's start and its `settled` write landing | Same as above; the window is one store write. Not measured separately. |
| A cut-off run OpenClaw doesn't resume | No row; the device waits out the awaiting window, as today (CA-6, fail-safe direction). |
| A new conversation's first message cut off before OpenClaw recorded its session | Reads as no session: settled, no row; the device waits out the window. |
| OpenClaw drops a queued follow-up over its queue cap | Settled when a later queued message of that conversation starts; no row (as before the change). |
| Queued messages collect mode would have merged | One row each (Q3 after CA-6). |
| Rollback of ticket 02, then re-deploy | Ticket 01 code ignores `state`; entries it claims while rolled back have no state and are never marked. Entries 02 left `accepted` or `queued` before the rollback are marked by the next 02 sweep within 24 h, possibly for answered messages. Accepted; rollback is rare. |
| A session reset between the message and a degraded transcript check | The check reads the new session and answers "missing": the message runs. Degraded mode only. |
| Message ids stored on disk | Ids, conversation ids, states, times and sequence numbers; no message text. |
| Two devices both tap Resend | Accepted (two deliberate taps). |
| Report size | At most 100 errors and one `run_started` per executing run, about 200 bytes each. |

## Out of scope

- S3 and S5–S8; relay, pairing, timestamp and Live Activity format changes; Windows sync tests.
- The Windows app listing `session-report` (needs it to show a `run_failed` outside the open conversation first).
- Marking runs OpenClaw may resume; asking OpenClaw for a public custody check.
- Automatic rerun after a restart; typing for queued turns from other devices.
- Release, TestFlight and merges: draft PRs only.

## Further notes

- **Deferred (Yorozu (the agent), 2026-11-19 11:21 JST): decision 1's app-side "unlisted" rule.** A run the app shows as running but the host doesn't list is not marked interrupted. The host side of decision 1 stays (tickets 02 and 03). The case it covered keeps the awaiting window and is measured by `run ledger unavailable` (target 0).
- **Agent-accepted items:** the choices in "Referenced decisions" were accepted by Yorozu (the agent) under the brief's delegation. None changes an owner rule: CA-7 follows `OWNER_DECISIONS.md:128` by gating.
- **Hermes dependency.** The Hermes spec relies on the ledger API and sweep. v4 changes both (no recovery classifier, new states, `report` takes capabilities); that spec follows this one.
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
  - B3. OpenClaw marks cut-off runs for its restart recovery at start-up, through a private custody field plus public fields; no SDK helper reports custody. (Why v3 needed a classifier; v4 reads none of it.)
  - B4. No opt-out from restart recovery for a channel or run.
  - B5. `runningTurns` is a start marker per conversation, set by `onAgentRunStart` and cleared only by the matching turn's `finally`; a follow-up that starts after its turn's `finally` leaves a stale owner. A parked turn is not in it once its attempt returns.
- **Measures (Yorozu (the agent), for 2 weeks after each plugin PR's Release Mac build):** `rg 'yorozu: (run started|duplicate message skipped|turn interrupted by restart|turn settled, no session|interrupted message withdrawn|session unreadable|unknown dispatch deferral|run ledger|restart sweep)' ~/.openclaw/logs/`.

| Log line | Target |
|---|---|
| `run started <id> attempt 0` for one id under two boot ids | 0 |
| `run ledger write failed` | 0 |
| `run ledger unavailable`, `run ledger transcript check failed` | 0 |
| `restart sweep skipped` | 0 |
| `session unreadable`, `unknown dispatch deferral` | 0 (any line: the code needs an update) |
| `duplicate message skipped` | Counted (ticket 01's incident data) |
| `turn interrupted by restart` | Each within a minute after a restart. `~/.openclaw/logs/gateway-restart.log` records planned restarts; whether a crash writes to it is unverified, so an unmatched line is checked against the Gateway's start-up lines before being called a bug. |
| `turn interrupted by restart` followed by a reply for that message id | 0 (each one is a run Resend could double) |

- **Release triggers (on merge to `main`):** per ticket in "Tickets, PRs and files". The docs PR edits only `docs/designs/` and `docs/tickets/`; the help bundle reads only top-level `docs/*.md` and the READMEs (`apps/mcp/scripts/generate.ts:61-63`), and no workflow watches those paths, so its merge starts nothing (CA-16).
- **Rollback:** revert the PR. An older plugin ignores the `runs`, `run-sweep` and `run-told` namespaces. An older app doesn't list `session-report`, so it gets nothing new. A plugin without ticket 02 never lists the capability, so the new app gets nothing new either.

## Review dispositions (round 2)

| Id | Disposition | Reason |
|---|---|---|
| CA-1 | FIXED | "Executing" defined with a known end (awaiting dispatch, cleared in that turn's `finally`); follow-ups never executing after return; B5 restated; now ticket 03, tests 03 #2–#4. |
| CA-2 | FIXED (reshaped) | (a) Steered messages now never marked; (b) rollback row rewritten for the 01/02 split; (c) false rows from failed writes accepted and logged. |
| CA-3 | FIXED | Ticket and file tables, names frozen per ticket, `Project.swift` needs no change, strings read via `#filePath`. |
| CA-4 | FIXED | Goals, stories and exclusion tables restated for CA-6; unsolved part of S2 in Problem. |
| CA-5 | FIXED (by CA-6) | Started runs are never marked, so Resend can't double a run OpenClaw recovered; only failed writes remain (Risks). |
| CA-6 | DECIDED | Yorozu (the agent), 2026-11-19 12:57 JST: mark only never-handed and never-started follow-up messages; no classifier, recovery reads or pin test; parked never interrupted; Q3 as one row per lost message; ticket 01 ships alone. |
| CA-7 | DECIDED | Yorozu (the agent), 2026-11-19 12:57 JST: new capability `session-report`; report only to listing sessions, only at session open, never for a gone session; older peers get nothing new; iOS lists it, Windows doesn't yet; YorozuWire constant. |
| CA-8 | FIXED | `claim` returns fresh or duplicate; a duplicate gets only `delivered`; tests 01 #2 and 02 #17. |
| CA-9 | FIXED | T0 answer 2 and the alternative give the source-turn check and the real reason for own dedupe. |
| CA-10 | FIXED | Pure factory with injected deps, `runs.ts` binding, restart seam, gate inside `report`, Hub tests inject the claim. |
| CA-11 | FIXED | Store options and value types; watermark deleted on forget; await-then-marker rule; pruning timestamps; why not `defaultTtlMs`. |
| CA-12 | FIXED | Unavailable look and upgrade, existing-row replacement, shared-file reference check, unknown conversation dropped first, nine-language strings, awaiting reason. |
| CA-13 | FIXED | Real guard files, relay and Windows commands, exact typecheck and bundle commands, start order matches test 02 #13. |
| CA-14 | FIXED | Surviving stores named, restart count sourced, write latency qualified, contract quote fixed, report size restated, crash log unverified. |
| CA-15 | FIXED | Roles and glossary cover host, plugin, Hub, Gateway, paths, device session, `peer_info`, turn, run and the agents. |
| CA-16 | FIXED | Triggers per ticket, phrased "on merge"; docs PR touches only paths nothing ingests. |
| CA-17 | FIXED | S1b limited to a queued message lost at restart. |
| CN-1 | FIXED | Transcript check reuses `itemsOf`; sync cost stated; async lookup and background retry deferred. |
| CN-2 | FIXED | Watermark is a sweep sequence. |
| CN-3 | FIXED | Reason for a persisted marker stated. |
| CN-4 | REVISED | `typing false` dropped: only `session-report` clients get the report, and the app clears typing itself. |
| CN-5 | FIXED | Exact string in the contract table; plugin constant in `envelope.ts`, Swift constant in YorozuWire; a test on each side. |
| CN-6 | MOOT | The pin test is gone (CA-6). |
| CN-7 | FIXED | Cut-off follow-ups and collect-mode rows in Risks and Q3. |
| CN-8 | FIXED | Promise chain in the store paragraph; fake-store internals listed as test seams. |
| CN-9 | FIXED | Terms defined; recovery-only terms removed with the classifier. |
| CN-10 | FIXED | Stories reworded for v4. |
| CN-11 | FIXED | Non-goals listed under Goals. |
| CN-12 | FIXED | `unknown dispatch deferral` tested (02 #9) and measured. |
| CN-13 | FIXED | Precedent is `conversation-owner.test.ts:146`. |
