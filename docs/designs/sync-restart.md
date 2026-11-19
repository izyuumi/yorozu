# Sync restart durability: ticket 01 (run ledger)

- **Status:** v5. Ticket 01 is fully specified and is built now, alone. No EGM round 4: Yorozu (the agent) reviews the PR at its exact head. Tickets 02–04 are deferred to a later spec ("Deferred (later spec)"). Yorozu (the agent)'s final decisions on v4 after EGM round 3, 2026-11-19 ~13:30 JST, are in "Referenced decisions" and "Review dispositions (round 3)".
- **Brief:** box handover `inbox/coder/20261119-1104-yorozu-yorozu-sync-restart-durability.md` (Tier: feature). The box is the shared Linux machine the bots use; its handover folder is `/home/box/handover`.
- **Source spec:** box handover `transfers/20261119-yorozu-sync-stability-spec.md` (v4, with §9 owner decisions 1–6) and its EGM round 4 report.
- **Baseline:** `origin/main` at `8a278a5c`.
- **Roles:** the *owner* is the person who uses the app. *Yorozu* means the product unless written "Yorozu (the agent)": the agent that holds the product's delegated decisions and wrote the brief. *Coder* is the agent that wrote this spec and runs the implementation. *The OpenClaw agent* is the model run that answers the owner's messages. Owner decisions live in `OWNER_DECISIONS.md`; Yorozu (the agent) decides only what the brief delegates.
- **Review terms:** *EGM* is the multi-stage spec review; its findings are cited as CA-n/CN-n (round 2) and A-n/N-n (round 3). *T0* and *T0b* are Coder's read-only source readings of OpenClaw 2026.9.8, answered in Further notes.

## Problem

The OpenClaw Gateway on the owner's Mac mini restarted five times between Nov 2 and Nov 12 (count from the source spec). Yorozu's host plugin runs inside it. Several plugin stores survive a restart (`retry`, `replies`, `reactions`, `attachments`, `message-times`, `read`, `devices`, and the upload spool). What the plugin knows about which messages it accepted is in memory only, and a restart loses it. No double run or lost message has been traced to a restart yet. The source spec found these cases by reading the code:

- **S1. A message can run twice.** The host answers `delivered` and drops repeats with an in-memory list of message ids (`hub.ts:22-23`). A restart clears the list. A device that never got `delivered` resends the message in its next session, and the OpenClaw agent runs it again. **Ticket 01 fixes this.**
- **S1b. A queued message can vanish.** A message waiting in OpenClaw's follow-up queue is lost when the Gateway restarts (T0b B2). The device already shows ✓✓ and never resends it. **01 only counts it** (start-up count lines).
- **S2. A cut-off turn ends late**, when the app's 10-minute awaiting window runs out, unless OpenClaw resumes it. **01 only counts it.**
- **S4. A late joiner doesn't see "working…"** until the next typing keepalive (up to 8 s). **Deferred** (A-8).

How often S1b and S2 happen is unknown. 01's logs measure it for two weeks on the mini before anything acts on them (A-6). S3 and S5–S8 are a later spec.

## Goals

1. A message the host accepted runs at most once across restarts, within the bounds in "Promises and their limits".
2. Each turn's progress (accepted, handed to OpenClaw, started, settled) is recorded durably with the boot id of the process that wrote it, so that at start-up the host logs, once per process, how many messages each earlier process left unsettled, by category.
3. Nothing a device sees changes, except that a repeat after a restart gets only `delivered` instead of running again.
4. Shipped apps, the Windows app, older hosts, the relay and the Windows conformance host keep working unchanged: no new event, field or capability.

Non-goals (01): marking or reporting interrupted messages; any action at start-up beyond counting; automatic rerun; `run_started` at session open; app changes; top-level docs, contract or plugin README edits.

## Solution

- **Run ledger.** The host keeps a durable record per message id, written when the message is accepted and stamped with the boot id. A repeat of a recorded id gets `delivered` and does not run again, also after a restart. When the store can't be read, the host checks the transcript instead.
- **Progress writes.** The record moves `accepted → handed → started → settled` (plus `parked`), each write stamping the current boot id. The `handed` write is awaited immediately before the dispatch call.
- **Start-up counts.** Once per process, the host logs one line per earlier boot id with the counts of that process's unsettled entries. It changes nothing.
- **Dispatch logs.** Each dispatch's `deferredToActiveRun` value and each follow-up start after its dispatch returned are logged (A-6).

## Promises and their limits

**At-most-once** holds for a message id within 24 h and the latest 10,000 messages, once its claim write has landed. The claim write starts right after the claim, before `delivered`, without being awaited. It does not hold:

- in degraded mode (the store can't be read at start-up): a message still in OpenClaw's queue is not in the transcript, and a failed transcript read runs the message;
- for a claim whose store write failed (logged, target 0);
- for a restart between the claim and its write landing.

**Start-up counts** are as good as the writes behind them. A failed or unlanded write leaves an entry one step behind (logged, target 0). An entry stays unsettled in the store until it ages out, so a later restart within 24 h logs the same earlier boot id again; readers take the first line per boot id.

**Device-visible behaviour** is unchanged except for the duplicate case.

## User stories

1. As the owner, I want a message the host already accepted to run at most once even if the Gateway restarts, so that the OpenClaw agent doesn't do the same work twice.
2. As the owner, I want a message my device resends after a restart (because it never got ✓✓) to get ✓✓ and not run again, so that a flaky connection costs nothing.
3. As the owner, I want a message that arrives on both the relay and the direct path to run once, also right after a restart.
4. As the owner, I want the host to keep working when its store fails, falling back to the transcript to spot repeats, so that a store failure never fails a turn.
5. As the owner, I want a run that fails for a temporary reason to be retried after 5, 15, 30, 60 and 120 s, as before, including across a restart.
6. As the owner using any app version, I want nothing else to change.
7. As Yorozu (the agent), I want start-up count lines per earlier boot id and per-dispatch deferral lines, so that two weeks of logs decide what tickets 02–04 do (A-5, A-6).

## Implementation decisions

### Referenced decisions

| Label | Who and where | What it says |
|---|---|---|
| Decision 3 | Owner, source spec v4 §9 | Dedupe falls back to the transcript when the store fails. |
| Decision 5 | Owner, source spec v4 §9 | No automatic rerun after a restart; the auto-retry rule (`retry` store) is unchanged. |
| Q1 (b) | Yorozu (the agent), 2026-11-19 11:21 JST | Leave to OpenClaw what its restart recovery may resume; fail safe toward at-most-once. |
| CA-6, CA-7 | Yorozu (the agent), 2026-11-19 12:57 JST | Shape and gating of the later report; kept in "Deferred (later spec)". |
| A-7 | Yorozu (the agent), 2026-11-19 ~13:30 JST, final | A boot id on each entry; no per-device watermark in 01 (that is 02's). |
| A-4 | same | Mark an entry handed with an awaited write immediately **before** the dispatch call, for every backend (Hermes will call the same function). |
| A-5, A-6 | same | 01 logs start-up counts and dispatch deferrals. Tickets 02–04 wait for two weeks of 01's logs from the mini. A-5's question is decided after the logs; no T0c now. |
| A-8 | same | Ticket 03 deferred. |
| A-9 | same | A message OpenClaw never held (never handed, per the boot-id ledger) goes back into the retry store and is sent when the Gateway is back; anything handed gets no automatic action and no Resend; the awaiting window ends it. Implementation: see "A-9 implementation" below. |
| A-2 | same, accepted | For the later spec: the error goes only to the device that sent the message; `unavailable` is removed; story "on the device that sent it". |
| No round 4 | same | 01 is built alone; Yorozu (the agent) reviews the PR at its exact head. |

- **A-9 implementation: deferred.** Not implemented in 01, because 01 keeps only ids, conversation ids, states, times and boot ids on disk, and its start-up pass only counts. A-9 needs the full message (text, attachments, `replyTo`) kept on disk until it is handed, and a start-up action that parks messages into the retry store before the retry loop starts, which is a state-changing start-up pass and a start-order change: the size and risk of the deferred ticket 02, not of 01. The later spec can reuse `park` (`retry.ts:19-24`), which already stores the whole message. 01's `not handed` count measures how often A-9 would act.

### How a message flows (context)

- **Host, plugin, Hub.** The *host* is the owner's Mac running the OpenClaw *Gateway*. Yorozu's *plugin* (`plugins/openclaw-yorozu`) runs inside it. Its *Hub* (`src/hub.ts`) holds one encrypted *device session* per connected device.
- **Relay and direct paths.** A device reaches the Hub through the relay (`apps/relay`) or, on the same network, through the plugin's direct listener. One message can arrive twice, once on each path.
- **Device → Hub.** For each `message` event the Hub broadcasts `delivered` (✓✓) and hands the message to `handleMessage` (`src/conversation.ts:124`).
- **Conversation module → OpenClaw.** `handleMessage` prepares attachments and media, resolves the conversation's OpenClaw session, awaits `runChannelInboundEvent` (`conversation.ts:224`), and turns OpenClaw's callbacks into events. A temporary failure before any reply or tool call parks the message in the `retry` store (`conversation.ts:303`).
- **OpenClaw** runs one agent run per session at a time. A message arriving during a run is either *steered* into it (the dispatch returns with `deferredToActiveRun: "steer"`, no start of its own) or put in the per-process *follow-up queue* (returns at once with `"followup"`; its own `onAgentRunStart` fires later, before or after the return; a collected batch fires only its last item's) (T0b B1). The follow-up queue is lost on a restart (T0b B2); restart recovery may resume a cut-off run (T0 answer 1).

### Glossary

| Term | Meaning |
|---|---|
| Restart | The Gateway process stops and starts. A plugin reload (`startAccount` again in the same process) is not a restart. |
| Boot id | `"<pid>:<Math.round(performance.timeOrigin)>"`: the same across plugin reloads and module re-imports, new after a restart. |
| Turn | One `handleMessage` call. A parked rerun is a new turn for the same message id. |
| Run ledger | The host's record of accepted messages, keyed by message id. In memory, loaded once per process, written through to keyed-store namespace `runs`. |
| Earlier entry | An entry whose `boot` differs from the current boot id. |
| Degraded mode | The ledger store couldn't be read at start-up; the transcript check stands in for it. |
| Transcript check | A synchronous read of the conversation's OpenClaw transcript for a user message with that transport message id. |
| Target 0 | The log line should never appear. |

### Record and states

`RunRecord = {convId, at, boot, state}`: `at` = host receipt time (ms), `boot` = boot id of the process that made the last write, `state` below. Never sent to devices.

| State | Written by | When |
|---|---|---|
| `accepted` | `claim` | The Hub accepted a fresh message. |
| `handed` | `handing` (awaited) | Immediately before the dispatch call (`await runChannelInboundEvent`), on every attempt including parked reruns. Any later backend (Hermes) calls the same `handing` right before its own dispatch. |
| `started` | `runStarted` | The turn's own `onAgentRunStart` fired, before or after its dispatch returned. Only from `handed` (a start never moves an entry back from `settled`). |
| `parked` | `turnEnded(parked: true)` | The auto-retry rule parked the turn. Its rerun writes `handed` again. |
| `settled` | `turnEnded(parked: false)` | The turn's outer `finally`, not parked, **unless** its dispatch returned `"followup"` and its own start hadn't fired yet: that entry stays `handed` (it sits in OpenClaw's queue). Covers a reply, a reported failure, a steer, a dispatch without deferral, a follow-up whose start fired before the return, and a preparation failure (its error was already sent). |

A follow-up whose start fires after its dispatch returned moves `handed → started` and is never settled: the host can't see that run end. At the next start-up it counts as `started`; the `follow-up started after dispatch` lines tell those apart.

**Writes.** Every write updates the map synchronously, stamps the current boot id, and goes through one promise chain per id, so writes land in call order. A writer for an id the map lacks (a parked message whose entry was pruned) first inserts it with `at` = now. A failed write logs `yorozu: run ledger write failed: <error>` and never fails a turn; a failed `handing` write still lets the dispatch run.

**Store timing (A-12).** The async keyed store the plugin opens (`api.runtime.state.openKeyedStore`, `createPluginStateKeyedStore`, `~/openclaw/src/plugin-state/plugin-state-store.ts:477`) runs its operations in OpenClaw's state worker (`...InWorker`, same file `:65-73`), not synchronously on the Gateway's event loop (correcting v5's first draft, found while building 01). So the awaited `handing` write gets a deadline: `handing` resolves when the write lands or after 2 s, whichever is first; on the deadline it logs `yorozu: run ledger write slow <messageId> handed` and the dispatch runs (fail open, as for a failed write). The write itself is left to finish on its chain, so later writes for the id still land in call order. `LedgerDeps` gains an optional `handDeadlineMs` (default 2000) for tests; nothing else in the frozen interface changes.

**Store.** Namespace `runs`, `{maxEntries: 10_000, overflowPolicy: "evict-oldest"}`, like `replies`. The store's `defaultTtlMs` is not used: it counts from the last write, and entries are rewritten.

**Pruning.** On load, entries older than 24 h (from `at`) are dropped from the map and deleted from the store. On each claim the map drops entries past the same age and the oldest beyond 10,000, as the Hub's id list does now.

### Claim and dedupe

On every `message` event in the Hub, before `delivered`, the Hub calls the injected synchronous `claim(message)`:

1. Unknown id: a new `accepted` entry, its write started and not awaited; returns `"fresh"`.
2. Known id (any state): logs `yorozu: duplicate message skipped <messageId> <state> boot <same|earlier>`; returns `"duplicate"`. `boot earlier` marks a copy that crossed a restart; `boot same` is mostly the relay-plus-direct double arrival (A-20).
3. The Hub broadcasts `delivered` in both cases, runs a fresh message (`onMessage`) and does nothing more for a duplicate, as `hub.ts` does today (CA-8).

**Degraded mode (decision 3).** If the `runs` store can't be read at load, the host logs `yorozu: run ledger unavailable: <error>`, starts with an empty map and logs no start-up counts. The claim checks the map first; on a miss it runs the transcript check: found → duplicate, entered in the map; missing → fresh; read failed → fresh, logged `yorozu: run ledger transcript check failed: <error>`. New entries still go to the map and the store. The check reuses history's matching (`history.ts` `itemsOf`, `:214`, user items keyed by transport message id, `:403`). It is synchronous on the event loop while degraded; moving it off the loop and retrying the load in the background are deferred until `run ledger unavailable` shows up (CN-1).

### Start-up counts and logs

**Counts (A-5, A-9 data).** `load()` reads the store, prunes, then logs one line per earlier boot id that has at least one entry not `settled`:

```
yorozu: restart ledger <bootId>: not handed <n>, handed not started <n>, started <n>, parked <n>
```

`not handed` = `accepted`; `handed not started` = `handed`; `started` = `started`; `parked` = `parked` (the retry loop still reruns those; A-3). Entries of the current boot id are never counted, so a reload or module re-import can't count this process's own turns (A-1). The lines are logged once per process: `runs.ts` keeps a flag on `globalThis` under `Symbol.for("yorozu.runLedger.counted")`, which survives a module re-import. Nothing changes state; nothing is sent.

**Per-run lines.**

| Line | When |
|---|---|
| `yorozu: run started <messageId> attempt <n> boot <bootId>` | The turn's own `onAgentRunStart`; attempt 0 first, a parked rerun counts up. |
| `yorozu: dispatch returned <messageId> deferred <steer\|followup\|none\|other:<value>> started <true\|false>` | Right after the dispatch call returns (A-6). `started` = its own start had fired. |
| `yorozu: follow-up started after dispatch <messageId>` | Its own `onAgentRunStart` fires after its dispatch returned (A-6). |

### Wiring

`startAccount` opens the ledger (`openLedger`) after the existing stores load and before the relay host starts, and passes `claim` through `RelayHostOptions` to the Hub. `handleMessage` calls `handing` right before `runChannelInboundEvent`, `runStarted` from `onAgentRunStart`, `dispatchReturned` after the await, and `turnEnded` in its outer `finally` (parked = `ended === "retrying"`). Without `claim`, the Hub keeps its in-memory id list, so the Hubs built without one in `apps/relay/src/direct.test.ts:57` and `apps/windows/conformance/host/fake-host.ts:39` behave as before. The Hub still imports only Node built-ins and wire files (standalone typecheck). The retry loop and start order are otherwise unchanged.

### Module interfaces (frozen for 01)

`src/ledger.ts` is a pure factory: imports only Node built-ins, `envelope.ts` and the `Keyed` type from `cards.ts`; added to `tsconfig.standalone.json`. `src/runs.ts` is a thin runtime binding, as `presentations.ts` binds `cardStore`.

```ts
// src/ledger.ts
export type RunState = "accepted" | "handed" | "started" | "parked" | "settled";
export type RunRecord = { convId: string; at: number; boot: string; state: RunState };
export type Store<T> = Keyed<T> & { entries(): Promise<{ key: string; value: T }[]> };
export type LedgerDeps = {
  runs: () => Store<RunRecord>;          // namespace "runs"
  now: () => number;
  bootId: string;
  log: { info(line: string): void; warn(line: string): void };
  inTranscript: (convId: string, messageId: string) => "found" | "missing" | "unreadable";
};
export function createLedger(deps: LedgerDeps): Ledger;
export type Ledger = {
  load(): Promise<"loaded" | "degraded">;   // once per instance; later calls return the first result
  counts(): string[];                       // the start-up count lines, one per earlier boot id
  claim(message: Message): "fresh" | "duplicate";
  handing(messageId: string, convId: string): Promise<void>;   // awaited before every backend's dispatch call
  runStarted(messageId: string, attempt: number, afterReturn: boolean): void;
  dispatchReturned(messageId: string, deferred: unknown, started: boolean): void;  // log only
  turnEnded(messageId: string, convId: string, outcome: { parked: boolean; queued: boolean }): void;
  idle(): Promise<void>;                    // every pending write chain settled (tests)
};

// src/runs.ts (imports runtime.ts, history.ts)
export function openLedger(ctx: { cfg: OpenClawConfig; agent: string; log?: ChannelGatewayContext["log"] }): Promise<Ledger>;
//   First call: creates the ledger with the runtime store and boot id, loads it, logs counts() once per process.
//   Later calls (reloads) update the bound cfg, agent and log and return the same instance.
export function currentLedger(): Ledger | undefined;

// src/history.ts:   export function findUserMessage(cfg, agent, convId, messageId): "found" | "missing" | "unreadable";
// src/hub.ts HubOptions:        claim?: (message: Message) => "fresh" | "duplicate";
// src/relay.ts RelayHostOptions: claim?: HubOptions["claim"];
```

`turnEnded`'s `queued` = the dispatch returned `"followup"` and the turn's own start hadn't fired. The Hub and relay don't import the ledger; `startAccount` passes `claim`. `runtime.ts:1` imports `openclaw/plugin-sdk/runtime-store`, which isn't installed in CI, so Hub tests build a ledger with `createLedger` over fake stores and never import `runs.ts`.

**Restart seam for tests.** A restart is a new `createLedger` over the same fake store with a new `bootId`, plus a new Hub. A module re-import is a new `createLedger` with the same `bootId`. A reload is a second `load()` on the same instance.

### Files and release

One PR. Paths are repo-relative. No files are deleted.

| Action | Path | What |
|---|---|---|
| Create | `plugins/openclaw-yorozu/src/ledger.ts` | Pure factory: load, counts, claim, states, pruning, degraded mode, log lines. |
| Create | `plugins/openclaw-yorozu/src/runs.ts` | Runtime binding: store, boot id, transcript check, once-per-process count log. |
| Modify | `plugins/openclaw-yorozu/src/hub.ts` | `claim` option. |
| Modify | `plugins/openclaw-yorozu/src/relay.ts` | Pass `claim` to the Hub. |
| Modify | `plugins/openclaw-yorozu/src/conversation.ts` | `handing` before dispatch; `runStarted`, `dispatchReturned`, `turnEnded`. |
| Modify | `plugins/openclaw-yorozu/src/history.ts` | `findUserMessage`. |
| Modify | `plugins/openclaw-yorozu/src/channel.ts` | `openLedger`, pass `claim`. |
| Modify | `plugins/openclaw-yorozu/tsconfig.standalone.json` | Add `src/ledger.ts`. |
| Create | `plugins/openclaw-yorozu/test/ledger.test.ts` | Pure-factory tests. |
| Create | `plugins/openclaw-yorozu/test/hub-ledger.test.ts` | Hub with an injected claim; restart seam; relay+direct race. |
| Create | `plugins/openclaw-yorozu/test/conversation-ledger.test.ts` | Writes and ordering through the stand-in host. |
| Modify | `plugins/openclaw-yorozu/test/genui-host.js` | Fake keyed store extensions; dispatch stub returns `deferredToActiveRun` and fires the start before or after the return; call-order recorder. |
| Modify | `plugins/openclaw-yorozu/test/hub-host.ts` | Optional `claim`. |

**Not touched:** any top-level `docs/*.md` and the plugin README, which feed `apps/mcp/src/content.json` and would trigger Deploy website. The contract's dedupe line (`docs/ios-relay-contract.md:433`, "remembered 24 h, up to 10,000") stays true, so no contract edit. Also untouched: `apps/relay/src/direct.test.ts`, `apps/windows/conformance/host/fake-host.ts`, everything under `apps/ios` and `packages`.

**Release triggers (on merge to `main`):** `plugins/**` starts Release Mac (a Mac beta). Nothing else. This docs PR edits only `docs/designs/`, which nothing ingests or watches (`apps/mcp/scripts/generate.ts:61-63`), so its merge starts nothing (CA-16).

## Testing decisions

**Seams.** Ledger: `createLedger` over fake stores, a fake clock and boot ids. Hub: the existing fake host and Noise device harness (`hub-host`) with a claim from `createLedger`. Conversation: the stand-in host (`genui-hooks` maps runtime and Gateway-bound modules to `genui-host.js`); extend its fake keyed store rather than copying it: no eviction when `maxEntries` is undefined (today it would wipe the retained `retry` store), an `entries` failure mode, a write recorder, a slow mode, and reopen over the same rows. Tests check what devices receive, whether `onMessage` ran, log lines and store rows after a reopen, not private maps. Prior art: `hub-events`, `hub-session`, `genui-golden`, `prerun-error`, `conversation-owner`.

The PR's first code commit holds only red tests; the PR body names each and its failure on the parent.

**Red tests.**

1. **Restart replay dedupe.** M runs; a restart (new ledger with a new boot id and a new Hub over the same store); M again: `onMessage` ran once; `delivered` went out both times; one `duplicate message skipped`.
2. **Duplicate gets only `delivered`.** A duplicate of M while M runs: no `run_started`, `typing` or `error`.
3. **Relay + direct race.** Relay and direct copies of M arriving together, both right after a restart: M runs once, each copy gets `delivered`.
4. **Handed before dispatch (ordering).** The call recorder shows the `handed` store write settled before `runChannelInboundEvent` was called, on the first attempt and on a parked rerun; a failed `handing` write logs `run ledger write failed` and the dispatch still runs.
5. **Boot id on entries.** Every write stamps the current boot id; a parked rerun in a new process rewrites the entry under the new one.
6. **States.** No deferral → `settled`; `"steer"` → `settled`; `"followup"` with the start after the return → `handed`, then `started` and `follow-up started after dispatch` logged; `"followup"` with the start before the return → `settled`; a preparation failure (`attachment_missing` path) → `settled`; a parked turn → `parked`, its rerun → `handed` then `settled`; a start never moves a `settled` entry back.
7. **Start-up count lines.** Store rows from boot A covering each category (one `accepted`, one `handed`, one `started`, one `parked`, one `settled`) and boot B with only `settled`: a new ledger under boot C logs exactly `restart ledger A: not handed 1, handed not started 1, started 1, parked 1` and no line for B or C.
8. **Counts once per process.** A reload (second `load()`) and a module re-import (same boot id) log no count lines again, and current-boot entries are never counted.
9. **Dispatch log lines.** `dispatch returned <id> deferred <value> started <bool>` for `steer`, `followup`, none and an unknown value (`other:<value>`); `run started <id> attempt 0 boot <bootId>`, attempt 1 on a parked rerun.
10. **Degraded fallback.** Store unreadable at load: `run ledger unavailable` logged, no count lines; transcript holds M → M doesn't run; transcript read fails → M runs and `run ledger transcript check failed` is logged; a second copy of M in the same process is a duplicate without a transcript read.
11. **Write order.** With a slow store, writes for one id land in call order (`accepted`, `handed`, `started`, `settled`); a failed write logs and the turn completes.
12. **Pruning.** Entries older than 24 h are dropped on load and deleted from the store; the map stays within 24 h and 10,000 on claims.
13. **Device view unchanged.** A normal turn sends the same events as before the change (existing `genui-golden` passes unmodified).
14. **Legacy guards.** A Hub without `claim` behaves as before: `apps/relay/src/direct.test.ts` and `apps/windows/conformance/host/fake-host.ts` unchanged, and the relay suite and `bash apps/windows/ci/core.sh` pass.

**Acceptance commands** (Node 26, as CI; from the repo root):

```sh
node --test 'plugins/openclaw-yorozu/test/*.test.ts'
tsc -p plugins/openclaw-yorozu/tsconfig.standalone.json --typeRoots ~/openclaw/node_modules/@types
# Full plugin typecheck: needs plugins/openclaw-yorozu/node_modules/openclaw -> ~/openclaw.
# Zero errors in plugin files; about 484 pre-existing errors inside ~/openclaw source are ignored.
~/openclaw/node_modules/.bin/tsc -p plugins/openclaw-yorozu
pnpm --filter @yorozu/relay test        # without pnpm: (cd apps/relay && npx tsc -p tsconfig.worker.json && npx vitest run)
bash apps/windows/ci/core.sh
```

## Alternatives considered

- **A per-device watermark or a sweep marker in 01.** Not taken (A-7): 01 changes no state at start-up, and the boot id on each entry is enough to tell earlier processes' entries from this one's. Supersedes K3's sweep-marker choice for 01.
- **Marking handed after the dispatch call.** Not taken (A-4): a restart during the call would leave an entry OpenClaw holds looking never-handed.
- **A-9's requeue in 01.** Deferred ("A-9 implementation").
- **Waiting for the claim write before `delivered`.** Not taken: it changes ✓✓ from "received and decrypted" (`OWNER_DECISIONS.md`) to close a short gap.
- **No deadline on the `handed` write.** Rejected: the store runs in a worker, so a stuck worker would hold every dispatch (A-12, "Store timing").
- **Relying on OpenClaw's own message dedupe.** Not enough: its `MessageSid` cache is memory-only, and its durable source-turn check covers only messages OpenClaw already received (T0 answer 2). The host still needs its own dedupe for messages it accepted and never handed over, and to avoid repeating preparation work (CA-9).
- **Transcript only, no store.** Not taken: queued messages aren't in the transcript. Kept as the degraded fallback (decision 3).
- **Removing the Hub's in-memory list and requiring a ledger.** Not taken: the relay and Windows conformance Hubs are built without one.

## Risks

| Risk | Mitigation or check |
|---|---|
| A restart between the claim and its store write loses the entry | That message behaves as before. Measured by `run started <id> attempt 0` under two boot ids (target 0). |
| A failed or unlanded progress write leaves an entry one step behind | Counts skew by one; logged `run ledger write failed` (target 0). Nothing acts on counts in 01. |
| Follow-ups that ran to the end count as `started` | Cross-checked with `follow-up started after dispatch` lines. |
| A session reset between the message and a degraded transcript check | The check answers "missing" and the message runs. Degraded mode only. |
| The awaited `handed` write adds latency before each dispatch | One synchronous SQLite write; the claim's write is usually already done. |
| Message ids on disk | Ids, conversation ids, states, times and boot ids; no message text. |
| Rollback | Revert the PR. An older plugin ignores the `runs` namespace. |

## Out of scope

- Tickets 02–04 and A-9's requeue ("Deferred (later spec)").
- S3 and S5–S8; relay, pairing, timestamp and Live Activity changes; Windows sync tests.
- Top-level docs, the contract and the plugin README.
- Release, TestFlight and merges: draft PRs only.

## Deferred (later spec)

After two weeks of 01's logs from the mini (A-6), a NEW spec with a fresh EGM cycle replaces v4's tickets 02–04. Decided so far, so nothing is lost:

- **What gets reported (CA-6).** Only messages OpenClaw never held: claimed but never handed, or returned `"followup"` and never started. No recovery classifier, no `abortedLastRun`/`status`/recovery-field reads, no pin test. Parked messages are never reported. Q3 after CA-6: one row per lost message, also in collect mode.
- **How never-held messages end (A-9).** Never-handed messages go back into the retry store and are sent when the Gateway is back; anything handed gets no automatic action and no Resend; the awaiting window ends it. Whether a never-started follow-up counts as handed here is for the new spec.
- **Gating (CA-7).** A new `peer_info` capability `session-report`; the report goes only to a session that lists it, only at session open, never for a conversation whose OpenClaw session is gone; peers without it get nothing new. iOS lists it; Windows doesn't until it shows a `run_failed` outside the open conversation.
- **A-2 (accepted).** The interrupted error goes only to the device that sent the message (dropped on other devices); the app's `unavailable` row state is removed; the story reads "an Interrupted row on the device that sent it".
- **A-5.** Decided after the logs; no T0c now.
- **A-8.** Ticket 03 (`run_started` at session open, an `executing` map separate from `runningTurns`) is deferred.
- **Per-device watermark** (A-7): belongs to the new spec, not 01.
- **Session-report capability, the reason string `interrupted by a host restart`, app strings and their translations:** not shipped; unreviewed; they wait for the new spec.
- **Earlier deferral:** decision 1's app-side "unlisted" rule (Yorozu (the agent), 2026-11-19 11:21 JST).
- **Hermes dependency.** The Hermes spec relies on 01's `handing` (called before its own dispatch) and on the later spec for reporting.

## Further notes

- **T0 answers** (OpenClaw 2026.9.8, source reading only):
  1. Can OpenClaw resume a cut-off Yorozu turn after a restart? Yes, through main-session restart recovery.
  2. Is OpenClaw's message dedupe durable? Its `MessageSid` cache is memory-only (20 min, 5,000 entries). A source-turn check survives a restart while the session keeps a matching active claim or terminal source id (`src/auto-reply/reply/dispatch-from-config.prepare-context.ts:325-345`).
  3. Does each message get its own run? No: `steer` (default) folds into the running run; a follow-up queue runs later.
  4. Does a parked rerun append the user message twice? No.
  5. Does a `channels.yorozu` reload reload the module? No, it reuses it.
  6. Does `onToolStart` fire before the tool runs? No guarantee (unused here).
  7. Keyed store API? `register`/`delete`/`entries`/`lookup`, `evict-oldest` or `reject-new`, awaited transactional writes.
- **T0b answers** (after EGM round 1): B1 steer and follow-up return timing (above); B2 the follow-up queue is per process and lost at a restart; B3 OpenClaw's recovery custody is private (unused); B4 no opt-out from restart recovery; B5 `runningTurns` is a start marker and can go stale for a follow-up.
- **Measures (Yorozu (the agent), two weeks after 01's Release Mac build on the mini):** `rg 'yorozu: (run started|duplicate message skipped|restart ledger|dispatch returned|follow-up started after dispatch|run ledger)' ~/.openclaw/logs/`.

| Log line | Target |
|---|---|
| `run started <id> attempt 0` for one id under two boot ids | 0 |
| `run ledger write failed`, `run ledger unavailable`, `run ledger transcript check failed` | 0 |
| `duplicate message skipped … boot earlier` | Counted (S1 incidents prevented); `boot same` lines are path doubles and not counted (A-20) |
| `restart ledger <bootId>: …` (first line per boot id) | Counted per category; decides A-5, A-9 and the later spec's scope |
| `dispatch returned … deferred followup`, `follow-up started after dispatch` | Counted (how often messages wait in OpenClaw's queue) |

## Review dispositions (round 3)

Yorozu (the agent), 2026-11-19 ~13:30 JST, final.

| Id | Disposition | Where |
|---|---|---|
| A-1 | CLOSED by A-7 | Entries carry the writing process's boot id; a reload or re-import never counts its own entries ("Start-up counts"; test 8). |
| A-2 | ACCEPTED, deferred | Sender-only error, no `unavailable`, story reworded ("Deferred"). |
| A-3 | RESOLVED for 01 | `parked` state and its own count; rerun writes `handed` again (tests 6, 7). |
| A-4 | FIXED in 01 | `handing` awaited immediately before the dispatch call, for every backend (test 4). |
| A-5 | DECIDED: after the logs | No T0c; 01's count lines are the input. |
| A-6 | DECIDED | 02–04 wait two weeks of 01's logs; deferral and late-start log lines in 01 (test 9). |
| A-7 | FIXED in 01 | Boot id per entry; watermark and sweep marker removed (test 5). |
| A-8 | DEFERRED | Ticket 03. |
| A-9 | DECIDED; implementation deferred | "A-9 implementation: deferred" with the reason. |
| A-12 | RESOLVED for 01 | The store runs in OpenClaw's state worker, so the awaited `handed` write has a 2 s deadline, then logs and dispatches ("Store timing"). |
| A-13 | RESOLVED for 01 | `conversation.ts` reaches the ledger through `currentLedger()` from `runs.ts` (calls are skipped when it is undefined); `runs.ts` imports `runtime.ts` and `history.ts`, never `conversation.ts`, so there is no cycle ("Wiring", "Module interfaces"). |
| A-14 | RESOLVED for 01 | One `runStarted` (the ledger's); the call site is `onAgentRunStart` in `handleMessage`; `afterReturn` is a new per-turn flag set only there, separate from the existing `started`. |
| A-15 | RESOLVED for 01 | 01's harness files are listed in "Files and release" (`test/genui-host.js` stub extensions); the iOS harness belongs to the deferred ticket 04. |
| A-16 | MOOT | Test 02 #8 left with ticket 02. |
| A-20 | RESOLVED for 01 | `duplicate message skipped` carries the entry state and `boot same|earlier`, so restart duplicates are counted apart from relay-plus-direct doubles. The "unlisted" case left with 02. |
| A-24 | RESOLVED for 01 | Latency is stated as one synchronous SQLite write, unmeasured; 01's `run started` and `dispatch returned` lines bound it in the logs ("Risks"). |
| A-10, A-11, A-17 – A-19, A-21 – A-23, A-25 | CARRIED to the later spec | They concern tickets 02–04, which v5 removes. |
| N-1 – N-7 | CARRIED to the later spec, or moot | Nits on removed 02–04 text; any that touch 01 are covered by the sections above. |

Round 2 dispositions (CA-1 – CA-17, CN-1 – CN-13) are in v4 of this file (`git show 3c677c72:docs/designs/sync-restart.md`). Those still live in 01: CA-8 (duplicate gets only `delivered`), CA-9 (own dedupe), CA-16 (release triggers), CN-1 (sync transcript check).
