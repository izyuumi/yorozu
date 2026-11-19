# Hermes Agent as a second backend: side-by-side test

- **Status:** reviewed (EGM round 1 of this dev spec), then aligned with sync spec v4. How each finding was handled is in "Review dispositions" at the end.
- **Brief:** the Hermes backend test spec v4 with its §8 decisions (box handover `transfers/20261119-yorozu-hermes-backend-spec.md`). The direction is final.
- **Depends on:** the sync restart durability spec v4 (box handover `transfers/`; Coder's copy `sync-restart-v4.md`), which supersedes v3: its run ledger, claim, handing write and start-up sweep (sync tickets 01 and 02, one PR each). Its decisions CA-6 and CA-7 are final.
- **Baseline:** `origin/main` at `8a278a5c`. Nothing this spec describes exists there yet, and neither do the sync ledger and sweep.
- **Roles:** *the owner* uses the app and approves. *Yorozu (the agent)* owns the product decisions and runs the operator steps on the Mac mini. *Coder* wrote this spec and implements H1–H3.
- **Box handover:** `/home/box/handover` on the box, the Linux machine the agents share. `transfers/` holds the source specs and the H0 fixtures.

## Problem

The owner asked (2026-11-19) to "start testing of hermes agent backend as replacement to openclaw". Today every Yorozu turn runs on OpenClaw, so there is nothing to compare.

The test measures four things:
- **quality:** the owner's blind A/B/tie picks on 20 read-only tasks from past Yorozu conversations, each answered by both backends (P12);
- **latency:** the wall time of the same 20 tasks on each backend (P13);
- **tools:** OpenClaw tools Hermes lacked in real use, recorded as gaps;
- **reliability:** double runs and lost replies in real use of an opted-in conversation. Any one blamed on Hermes is a no-go.

Gateway restarts don't count for or against Hermes here: the plugin stays inside the OpenClaw Gateway, so the test only counts each process's restarts.

## Goals and non-goals

**Goals.**
1. Run real Yorozu conversations on Hermes beside OpenClaw, on the owner's own devices, about one opted-in conversation at a time, with no re-pair.
2. Produce the go/no-go report (Test plan).
3. Keep the test removable (Rollback).

**Scope rule.** Build only what a Test plan row needs.

**Non-goals.**
- OpenClaw retirement (ADR-H4, after a go only).
- Production-grade code: no backend interface, no general multi-backend support (D1).
- Cards, Automations, reactions, attachments and image input on Hermes.
- OpenClaw's own tools (iMessage, Meet, Signal and the owner's other tools) on Hermes. Gaps go in the report.
- An approval screen in the app.
- Any relay, app or wire change.
- An opt-out command.

## Solution

- The plugin gains a test-only config key, `channels.yorozu.backends.hermes`. Its `enabled` flag is off by default.
- With the flag on, the owner sends `/backend hermes` in a conversation that already has at least one message. From then on, that conversation's agent turns run on Hermes Agent through its runs API on `127.0.0.1:8652`. At most 20 conversations can be opted in.
- The plugin keeps every other duty: pairing, the relay, push, the conversation list, history, titles, pin, archive and delete. An opted-in conversation is still an OpenClaw session: the user message and Hermes's final reply are written into its transcript, so history and new devices show them.
- **What differs in an opted-in conversation:**
  - Hermes doesn't see the messages from before the opt-in.
  - Tool rows show live only: history doesn't show them.
  - Attachments aren't sent (the input says so), reactions reach no agent, and there are no cards.
  - Approvals are denied with a plain line.
  - Automations still run on OpenClaw, and Hermes doesn't see what they post.
  - Both backends share one ChatGPT quota, so heavy Hermes use can rate-limit OpenClaw turns too.
- Nothing changes on the wire, the relay or the apps.
- The owner decides go, extend or no-go from the report. The test ends at that decision or on 2026-12-31, whichever is first. Unless the outcome is go, the flag and its code are removed.

## User stories

1. As the owner, I want to opt a conversation into Hermes by sending `/backend hermes`, so that I can try Hermes on real work without re-pairing.
2. As the owner, I want every other conversation to keep running on OpenClaw as before, so that the test doesn't change them.
3. As the owner, I want an opted-in conversation to show ✓✓, typing, live tool rows, Live Activity steps and the reply, and to keep its history on every device, so that I can use it like any other conversation.
4. As the owner, I want a turn that found Hermes unreachable or rate-limited before any tool ran to recover by itself within about four minutes, as OpenClaw turns do, and to end with one clear error after that, so that I never wait forever.
5. As the owner, I want a Hermes run that failed for a permanent reason (no model provider, a refused key) to show its error once and never be retried, so that I learn about it at once.
6. As the owner, I want the plugin to resubmit a message to Hermes only under the key Hermes already holds, unless Hermes itself failed that run for a temporary reason before any tool ran, so that a retry never repeats a tool.
7. As the owner, I want a step that needs an approval to be denied with a plain line in the reply while the rest of the answer arrives, so that one gated tool doesn't lose the whole answer.
8. As the owner, I want `/new` and `/reset` in an opted-in conversation to tell me to start a new conversation, so that the Hermes and OpenClaw sessions can't drift apart. *Pending the owner's answer at step 7.*
9. As the owner, I want a Hermes turn that a Gateway restart cut off before the plugin handed it to Hermes to end with the same Interrupted row the sync work gives OpenClaw turns, and one Hermes already had to end as a turn OpenClaw already had does (the app's 10-minute window), with nothing resent without my tap, so that a Resend never repeats work Hermes may still be doing.
10. As the owner, I want a `channels.yorozu` config change (a plugin reload) not to lose a Hermes reply on its way, so that config edits are safe during a turn.
11. As the owner, I want turning the flag off to return every conversation to OpenClaw at the next reload, so that rollback is one config change.

## Implementation decisions

### Context

The owner's devices (the iPhone, iPad and Mac apps) talk end to end encrypted, through the relay (`apps/relay`) or the plugin's direct listener, to the plugin `plugins/openclaw-yorozu`, which runs inside the OpenClaw Gateway on the owner's Mac mini. In the plugin, the **Hub** (`src/hub.ts`) holds one encrypted session per connected device, acknowledges each message with `delivered` (✓✓) and hands it to the conversation module (`src/conversation.ts`), which runs the turn on OpenClaw. Each Yorozu conversation is one OpenClaw session (the conversation id is its thread id). Hermes Agent is a separate agent runtime with its own HTTP API. This test makes the plugin hand an opted-in conversation's turns to it instead of to OpenClaw.

**Owner rules** (quoted from `OWNER_DECISIONS.md` at `8a278a5c`):
- "Yorozu runs nothing of its own: no routing, classification, workers, coding agents, memory, jobs, Hermes or cua."
- The exception under that rule: "the Hermes backend test may run Hermes Agent as a second backend inside the plugin, behind `channels.yorozu.backends.hermes` (off by default) and opted into per conversation. OpenClaw stays the default throughout."
- "No Mac host process. The OpenClaw channel plugin … holds the host keys and the relay connection itself."
- "Language: Swift wherever possible …; never Python."

**Yorozu's reading of the exception** (Yorozu's, not the owner's words; asked as yes/no questions at step 7, before H2 and H3 start):
- The exception covers the plugin delegating turns to Hermes.
- The Hermes gateway is a third-party agent runtime, like OpenClaw. It isn't Yorozu's own code, so "never Python" doesn't apply to it.
- Yorozu still has no host process: the plugin keeps the host keys and the relay.
- `/new` and `/reset` in an opted-in conversation answer with a notice instead of resetting the session in place. That departs from `OWNER_DECISIONS.md:25` for the test only.

### Referenced decisions

These are final. This spec builds on them and doesn't reopen them.

| Label | Who and when | What it says |
|---|---|---|
| Owner-rule exception | The owner, 2026-11-19 09:18 JST; recorded at `OWNER_DECISIONS.md:13` by #748 (`8a278a5c`) | Quoted above. Test only; ends at the go/no-go or on 2026-12-31; with no go, the flag and its code are removed. |
| Test approval | The owner, 2026-11-19 08:43 JST | Go with Yorozu's recommendations, and set up the Hermes test install on the mini. |
| D1 | Yorozu (the agent), 2026-11-19 | Test-grade code behind the flag. No backend interface. Deleted after the go/no-go unless the outcome is go. |
| D2 | Yorozu (the agent), 2026-11-19 | The OpenClaw session entry stays the record. Only the agent turn is delegated to Hermes. |
| D3 | Yorozu (the agent), 2026-11-19 | The `Idempotency-Key` is `<messageId>:<keyAttempt>`. `keyAttempt` is stored before the POST. It advances only when Hermes itself ended the previous key's run with a temporary failure. Every other rerun replays the same key. |
| D4 | Yorozu (the agent), 2026-11-19 | A denied approval ends only that tool step, with a plain message. The run continues. |
| D5 | Yorozu (the agent), 2026-11-19 | Measure from the plugin logs and the 20-task batch, with the owner's blind A/B/tie pick per task. |
| Sync decision 5 | The owner, sync source spec §9 | No automatic rerun after a Gateway restart; the auto-retry rule is unchanged. |
| CA-6 | Yorozu (the agent), 2026-11-19 12:57 JST (sync v4) | Interrupted only for a message the host claimed but never handed to the backend, or one deferred as a follow-up that never started. No recovery classifier, no `abortedLastRun`/`status` reads. Parked messages are never interrupted. Sync ticket 01 ships alone first. |
| CA-7 | Yorozu (the agent), 2026-11-19 12:57 JST (sync v4) | The session-open report goes only to a device whose `peer_info` lists `session-report`. |
| Stack order | Yorozu (the agent), 2026-11-19, final | H1 is a draft PR stacked on the sync plugin branch (here sync ticket 02's PR branch; Tickets), H2 on H1, H3 on H2. Stacked branches are merged forward only. |
| Auto-retry rule | The owner, `OWNER_DECISIONS.md:92` | A run that fails for a moment before any reply or tool runs again by itself for about four minutes. |

### Glossary

| Term | Meaning |
|---|---|
| Gateway | The OpenClaw Gateway on the Mac mini. The plugin runs inside it. |
| Hermes, Hermes gateway | Hermes Agent, the second backend under test; its server process (v0.23.1, API on `127.0.0.1:8652`, home `~/.hermes-yorozu-test`). |
| Flag | `channels.yorozu.backends.hermes.enabled`. **Backend on/off** is the result of resolving the whole key (the flag and the key file) at `startAccount`. |
| Plugin reload | `startAccount` runs again in the same Gateway process after a `channels.yorozu` change. The module stays loaded. Not a restart. |
| Restart | The Gateway process stops and starts. |
| Opted-in conversation | A conversation with a route-store entry. |
| Delegated turn | One message of an opted-in conversation, handled by `hermesTurn`. |
| Route store, key store | Keyed-store namespaces `backends` (one entry per opted-in conversation, holding its unsettled run ids) and `hermes-keys` (`keyAttempt` per message id). |
| `retryAttempt` | The auto-retry counter: the index into `retry.ts`'s 5/15/30/60/120 s schedule, carried by `park` and `runParked`. Starts at 0. |
| `keyAttempt` | D3's counter, the suffix of the `Idempotency-Key`. Starts at 0. It never exceeds `retryAttempt`, because every advance is followed by a park. |
| Unsettled run | A Hermes run this plugin created and hasn't seen end. Kept in the route-store entry. |
| Replay | `POST /v1/runs` with a key Hermes already holds: it returns the existing `run_id` with `replayed: true`. |
| Cards, Automations | Yorozu's rich reply blocks (`presentation.ts`) and its scheduled jobs (OpenClaw cron). |
| Sync terms | From sync spec v4. **Run ledger:** a durable record per message id; states `accepted` → `queued` → `settled` \| `interrupted`. **Claim:** `claim(message)`, the Hub's call before `delivered`; it returns `"fresh"` (run it) or `"duplicate"` (don't). **Handing:** `handing(messageId, convId)`, awaited just before the message goes to the backend; it marks the entry `settled`. **`turnEnded(messageId, convId, parked)`:** settles an entry still `accepted` unless parked. **`runStarted(messageId, attempt)`:** the `run started <id> attempt <n> boot <bootId>` log line. **Sweep:** once per process, it marks the `accepted` and `queued` entries an earlier process left `interrupted`, unless the retry store holds them or the conversation's OpenClaw session is gone (then `settled`). **Session-open report:** only to a device listing `session-report`: the Interrupted errors it hasn't been told about (sync 02), then `run_started` for executing runs (sync 03). **Interrupted error:** `error {code: "run_failed", message: "interrupted by a host restart"}`, shown by sync ticket 04 as an Interrupted row with Resend. |
| Release Mac, Deploy website | `.github/workflows/release-mac.yml` (a push to `main` touching `plugins/**` publishes a public Mac beta) and `deploy-web.yml` (a push touching `apps/web/**`, `apps/mcp/src/**` or `apps/mcp/package.json` deploys the website). |
| Option B, ADR-H4 | Option B is the chosen design: a branch inside the plugin. ADR-H4 (deferred) is OpenClaw retirement, only after a go. |
| Red test, guard | A red test fails on the parent commit and passes after the change. A guard is an existing test that must stay green unmodified. |
| H0–H3, H6; P1–P13 | Tickets (H0 is the operator steps; H4 and H5 were dropped) and Test plan rows (P10 was dropped). |

### Components and data flow

```
device ─relay/direct─▶ Hub ─claim, delivered─▶ onMessage (channel.ts)
                                                 │ backend off: handleMessage (unchanged)
                                                 ▼ backend on
                                          routeMessage (hermes-turn.ts)
                         ┌───────────── not opted in: handleMessage (OpenClaw)
                         ▼ opted in, on the conversation's FIFO
                 notice, or hermesTurn ─▶ HermesClient ─HTTP─▶ Hermes gateway
                    │  externalTurn (conversation.ts): run_started, typing, tool rows, Live Activity, ledger writers
                    │  park / runParked (retry.ts): the auto-retry schedule
                    ▼
       sendDurableMessageBatch(mirror) ─▶ outbound adapter ─▶ reply event; transcript mirror; push
```

Data kept: the route and key stores; the existing `retry` store (parked messages of both backends); the sync stores, unchanged; the mirrored user messages and replies in the OpenClaw transcript.

### Hermes API facts

Recorded by `probe.sh` from the running test install with no model provider signed in, 2026-11-19. Fixtures: `transfers/20261119-yorozu-hermes-h0-fixtures/NN-name.{headers,body,sse}`, listed in `index.txt`.

| # | Fact |
|---|---|
| 01 | Without the key, `GET /v1/capabilities` answers 401 `gateway_auth_failed`. |
| 04 | Capabilities include `runs_idempotency` (`durable: true`, `retention_seconds: 86400`), `run_status`, `run_events_sse`, `run_stop`, `run_approval_response`, `tool_progress_events`, `approval_events` and `run_unknown_resolution`. |
| 06 | Vision is `configured: false`. |
| 08 | `POST /v1/runs` with a client-chosen `session_id` answers 202 `{"run_id","status":"started","replayed":false}`. |
| 09 | The event stream sends `: open`, then `id: 0` / `data: {"event":"run.failed","run_id","timestamp","error","completed","partial","interrupted","seq"}`, then `: stream closed`. |
| 10 | `GET /v1/runs/{id}` answers `{"object":"hermes.run","status","session_id","output","usage","admission_id","execution_generation","pending_controls",…}`, with no `error` field. For a failed run, `output` is the error text. |
| 11 | The same key and body after the run failed answers 202 with the same `run_id`, `"status":"failed"`, `"replayed":true`. |
| 12 | The same key with a different body answers 409 `idempotency_key_conflict`. |
| 13 | A new key starts a new run. |
| 14 | `GET /api/sessions/yorozu-<convId>` finds the session the run created. |
| 16, 17 | An unknown run (`run_not_found`) or session answers 404. |

From the v0.23.1 docs (`website/docs/user-guide/features/api-server.md` in the test clone):
- **Replay** (lines 489–495). An identical keyed retry returns the original `run_id`, "including after a gateway restart and after the run has completed, failed, or been cancelled". A run the gateway couldn't admit "keeps no reservation, so an exact retry is safe". Keys are kept for 24 h after the run's last update. The docs don't promise exactly-once (lines 646–647).
- **Durable runs** (lines 533, 600–624). A clean shutdown ends a running run as `interrupted`. A run whose gateway died mid-turn reports `unknown`, which isn't terminal: later runs in that session wait until `POST /v1/runs/{id}/resolve-unknown` gets exactly `{admission_id, execution_generation}`.
- **Approvals** (lines 659–677). An answer is `{"request_id", "execution_generation", "choice"}` from the run's `pending_controls`. `"deny"` appears only in the MCP passage, so it is inferred until step 9 records it.
- **SSE buffer.** A finished run's event buffer is dropped 300 s after its last subscriber (`docs/history/hermes-integration.md:134`).

Pending the owner's Codex sign-in (steps 8–11): a completed run with tools and `usage`; `approval.request`; `run.interrupted` and `unknown`; two runs at once on one session; whether the event stream replays from `seq` 0.

### Config, key file and state (H1)

**Schema.** H1 adds `backends` inside `channelConfigs.yorozu.schema.properties` in `plugins/openclaw-yorozu/openclaw.plugin.json`, next to `direct`:

```json
"backends": {
  "type": "object", "additionalProperties": false,
  "description": "Test only (Hermes backend test; ends at its go/no-go or on 2026-12-31).",
  "properties": {
    "hermes": {
      "type": "object", "additionalProperties": false,
      "properties": {
        "enabled": { "type": "boolean", "default": false },
        "keyFile": { "type": "string" }
      }
    }
  }
}
```

The URL isn't configurable: it is `http://127.0.0.1:8652`.

**Help bundle.** `apps/mcp/scripts/generate.ts` (`hostSettings`) fails `--check` for any schema key missing from the Config table in `docs/setup.md`, and documenting the key there would start Deploy website. So H1 adds `TEST_ONLY_KEYS = new Set(["backends"])`, skipped by `hostSettings`, with a comment naming this spec and the 2026-12-31 expiry. `content.json` stays byte-identical. H1 changes no `docs/*.md` and no plugin README; this design doc is the reference for the test-only code.

**Resolution.** `resolveHermesBackend(cfg, log)` in `src/backends.ts` is synchronous (`fs.statSync`, `fs.readFileSync`) and runs once per `startAccount`. The first matching row wins:

| Case | Result | Log (`info` for the first two and the last; `warn` otherwise) |
|---|---|---|
| `backends` or `backends.hermes` absent | off | none |
| `enabled` isn't `true` | off | `yorozu: hermes backend off: disabled` |
| `keyFile` missing or not starting with `/` (this includes `~/…`) | off | `… off: keyFile must be an absolute path` |
| `stat` or the read fails | off | `… off: keyFile unreadable (<error code>)` |
| not a regular file (`stat` follows symlinks) | off | `… off: keyFile is not a regular file` |
| `(mode & 0o077) !== 0` | off | `… off: keyFile is readable by others` |
| empty after trimming and removing one pair of surrounding `"` or `'` | off | `… off: keyFile is empty` |
| otherwise | on: `{url: new URL("http://127.0.0.1:8652"), key}` | `yorozu: hermes backend on` |

The key is never logged and never put in a URL or an error message. `<error code>` is `error.code` only (for example `ENOENT`).

**State.** `createHermesState(open, log)` in `src/backends.ts` is a factory over an injected keyed-store opener, like sync's `createLedger`. `openHermesState(log)` binds it to the runtime stores and returns one instance per module, so a plugin reload reuses it. With the backend off, it isn't called, so neither namespace is opened.

| Namespace | Value | Options | Notes |
|---|---|---|---|
| `backends` | `{unsettled: string[]}` | `{namespace: "backends", retention: "retained"}`, like the other small stores | Loaded into a map when the instance is created. `routedToHermes` reads the map synchronously. `setRoute` and the `unsettled` writes go to the map, then the store, awaited; a failed store write undoes the map change and rejects. |
| `hermes-keys` | `{keyAttempt: number}` | `{namespace: "hermes-keys", maxEntries: 10_000, overflowPolicy: "evict-oldest"}` | Read and written per turn. 10,000 matches the ledger. |

The instance also holds the per-conversation FIFO (`serial(convId, fn)`): a promise chain per conversation, each link with its own `.catch`, so one failed link never blocks the next.

`setRoute` answers `"full"` when the map already holds 20 routes (Goal 1; 20 leaves room for mistakes). No repository store uses `reject-new`, so the cap is a count in code. `addUnsettled` is idempotent and keeps at most 10 ids; an 11th drops the oldest, logged `yorozu: hermes unsettled list full, dropped <runId>`.

**Wiring in H1.** `startAccount` calls `resolveHermesBackend(ctx.cfg, ctx.log)` as a statement, for its log line only. Nothing else changes until H3.

### Client (H2)

`src/hermes-client.ts` imports Node built-ins only (it uses the global `fetch`) and joins `tsconfig.standalone.json`. Everything that touches OpenClaw lives in `backends.ts` and `hermes-turn.ts`, outside the standalone list.

- **Requests.** Every request sends `Authorization: Bearer <key>` and uses `redirect: "manual"`: a 3xx is an `http` error and is never followed, so the key can't reach another host.
- **Timeouts.** `createRun`, `status`, `deny`, `resolveUnknown` and `stop` each time out after 30 s. `events` takes the caller's `AbortSignal` and times out on connect (30 s) and on idle (60 s with no bytes; comments count).
- **No retries inside the client.** Every retry is a park.

| Input | `HermesError.kind` |
|---|---|
| `fetch` rejects (refused, reset, socket), or a timeout fires | `unavailable` |
| 429; any 503 | `unavailable` |
| 401, 403 | `auth` |
| 404 | `not_found` |
| 409 with `error.code` `idempotency_key_conflict` | `conflict` |
| any other non-2xx (3xx, 400, other 409, other 5xx) | `http`, with `status` and `error.code` |
| a 2xx whose JSON lacks the fields the method needs | `http`, `code: "bad_response"` |

`unavailable` covers both "never admitted" and "maybe admitted" (a timeout after the request was sent). Replaying the same key is the documented way to handle both; whether a replay after a restart behaves as documented is unverified.

- **Event stream.** `events` parses SSE: `:` lines are comments; `id:` is ignored; consecutive `data:` lines are joined with `\n` and parsed as JSON. A `data` that isn't a JSON object is skipped. Each event is yielded as `{event, seq, data}`, where `data` is the whole parsed object. The iterator ends after a terminal event (`run.completed`, `run.failed`, `run.cancelled`, `run.interrupted`), on `: stream closed`, when the server closes the connection, or after the idle timeout.
- **Fixed bodies.** `deny` sends `{"request_id","execution_generation","choice":"deny"}`; `resolveUnknown` sends `{"admission_id","execution_generation"}`; `stop` sends none.
- **Errors.** A `HermesError` message holds the method, the path, the HTTP status and Hermes's `error.code`, never a header or a request body.

### Routing and commands (H3)

`routeMessage(deps, message)` decides from the trimmed text and `routedToHermes(convId)`. A command matches the whole text or its first word (`/new foo` is `/new`).

| Message | Not opted in | Opted in |
|---|---|---|
| `/backend hermes` | Session entry exists: `setRoute`; notice "This conversation now uses Hermes (test). Hermes doesn't see the earlier messages." No entry yet: notice "Send one message first, then /backend hermes." Store full: notice "Too many Hermes test conversations." | Notice "This conversation already uses Hermes." |
| `/new`, `/reset` | `handleMessage` (OpenClaw) | Notice "Start a new conversation for a fresh Hermes session." |
| anything else | `handleMessage` (OpenClaw) | `hermesTurn` |

- The session entry check is `liveSessionId(agent, sessionKey)` from `history.ts`, with the thread session key from `resolveThreadSessionKeys`. Only `/backend hermes` needs it: an opted-in conversation always has an entry, because opting in requires one.
- **Order.** `/backend hermes` and every opted-in message run on the conversation's FIFO, so a message sent right after the opt-in queues behind it. Messages for conversations that aren't opted in go straight to `handleMessage`, as today.
- **A notice** goes out through `sendDurableMessageBatch` with the options of `post` in `updates.ts` (`durability: "best_effort"`, `mirror`). When the session entry exists, the user message is mirrored first. With no entry, neither is mirrored: the notice shows on devices but not in history. A status other than `sent` is logged `yorozu: hermes notice not sent: <status>`. The message then ends with `turnEnded(messageId, convId, false)`.
- **Backend off.** Every message goes to `handleMessage` as today, `/backend hermes` included. A message that arrives while an earlier OpenClaw turn of that conversation still runs can overlap with it on Hermes; accepted.
- **Pass-through, verified** (Coder, 2026-11-19, OpenClaw 2026.9.8, backend off). OpenClaw has no built-in text or native command `backend`, so `/backend hermes` reaches the agent runner verbatim and the device gets only the agent's reply; `/help` on the same path still gets OpenClaw's command reply with no agent run. Evidence: `test/backend-passthrough.test.ts` (H3) against the real SDK's inbound lifecycle, with the runner replaced at the agent handoff and no model call. **Caveat:** the test uses isolated state and a fresh workspace; a configured skill or plugin that claims `/backend` would change the result, and the test depends on OpenClaw's compiled chunk names.

### A delegated turn (H3)

`hermesTurn(deps, message, retryAttempt = 0)` runs on the conversation's FIFO. Each entry point (`routeMessage`, `routedRerun`, `hermesTurn`) catches every unexpected throw: it ends the message with `t.fail("The Hermes test turn failed.")` (creating `t` first if needed), logs `yorozu: hermes turn failed: <errorTag>`, and writes the usage line. None of them ever rejects.

1. **Claimed.** The Hub's claim returned `"fresh"` and `delivered` went out. A duplicate never reaches the turn.
2. **Live turn.** `t = externalTurn(deps.turn, message, retryAttempt)`.
3. **Settle earlier runs.** For each id in the route entry's `unsettled`: `status(id)`. Remove the id when it is terminal or `not_found` (its output isn't delivered; Risks). For `unknown`: `resolveUnknown` (a throw is logged), then `status` once more; remove the id if it is now terminal. Keep it in every other case, logging `yorozu: hermes earlier run still running <id>` for a running one; the new run then waits behind it under Hermes's session lease. A throw keeps the id and the turn goes on.
4. **Key.** Read the key store. With no entry, write `{keyAttempt: 0}` and await it; if that fails, `t.fail("The Hermes request key couldn't be stored.")` (D3: stored before the POST). Then, only for a new entry, mirror the user message (Mirror). Key first, then mirror, so a crash between them loses a history line and never mirrors twice. A failed mirror is logged and the turn goes on.
5. **Body.** `requestBody(message)` uses only the stored `Message` and fixed strings, so every attempt with one key is byte-identical (a different body gets 409). `input` joins, with blank lines: a quote line `> <replyTo.text, whitespace collapsed, at most 500 characters>` (or `> (an earlier message)` with no text) when the message quotes one; the text; `[n attachment(s) not sent to the Hermes test]` when it has attachments. The body is `{input, session_id: "yorozu-<convId>", instructions}`. The instructions say: answer in Yorozu, a chat app; plain Markdown, tables fine; no message tool and no card format. The persona comes from the step-12 import.
6. **Hand, then create.** `await t.handing()` (sync v4's `handing`, awaited as before OpenClaw's dispatch; a failed write is logged and the POST still goes). Then `createRun({key: "<messageId>:<keyAttempt>", body})`. Every attempt passes `handing`; on a rerun the entry is already `settled`.
   - On success, `addUnsettled(runId)` (a failed write is logged). If `replayed`, read `status(runId)` and act by the status table. Otherwise attach (step 7).
   - `unavailable`: retry later with the same key.
   - `auth`: `t.fail("The Hermes test backend refused the key.")`.
   - `conflict`, `not_found`, `http`: `t.fail("Hermes answered <status> <code>.")` and a warning log.
   - A replayed run whose `status` throws: `unavailable` retries later with the same key; other kinds fail as above.
7. **Attach.** `t.started()`, then read `events(runId)` and handle each event (Turn outcomes). The turn keeps `lastSeq` and ignores any event at or below it, so a re-attach that replays from `seq` 0 doesn't repeat a tool row or an approval answer. The turn is capped at 30 minutes from `t.started()`: at the cap, `stop(runId)` (best effort; the id stays unsettled) and `t.fail("The Hermes run took over 30 minutes.")`.

   **Lost stream.** When the stream ends without a terminal event, or `events` throws (any kind, including `not_found` after the buffer was dropped), read `status(runId)` once and act by the status table. If that is still a running status, wait 2 s and attach again, at most 5 times per turn. If `status` throws, or the 5 re-attaches are used up: `t.fail("Lost contact with the Hermes run; it may still finish.")`, with the id kept unsettled.
8. **Deliver.** An empty `output` is `t.fail("Hermes finished with an empty reply.")`. Otherwise send `output`, then one line per denied approval, with `sendDurableMessageBatch` and the options of `post` in `updates.ts`. A status other than `sent` is `t.fail("The Hermes reply couldn't be sent: <status>.")`. Then the push (before-code question 3), then `t.done()`. No `maybeTitle` or `noteFirstMessage`: the conversation's first message was an OpenClaw turn, which set the title.

**Status table.** The one mapping from a run's status to an action, used for a replayed run (step 6), after a lost stream (step 7) and for terminal events (`run.<status>`). Every terminal row removes the id from `unsettled` first.

| Status | Action |
|---|---|
| `completed` | Deliver the event's `output`, or the status's `output` if the event has none (step 8). |
| `failed`, from a `run.failed` event on this turn's own stream, with no tool seen and `isTemporary(text)` | Write `{keyAttempt: keyAttempt + 1}` (awaited; if it fails, `t.fail("Hermes: <text>")`), then retry later. |
| `failed`, any other way (a replayed run, a status read, a tool seen, a permanent error) | `t.fail("Hermes: <text, cut to 500 characters>")`. |
| `interrupted` | `t.fail("Hermes interrupted this run.")` |
| `cancelled` | `t.fail("Hermes cancelled this run.")` |
| `unknown` | `resolveUnknown`, then `status` once, then this table once more. Still `unknown`, or a throw: `t.fail("The Hermes run couldn't be resolved.")`, id kept unsettled. |
| any other (`started`, `running`, `queued`, …) | Attach (step 7). |

`<text>` is the event's `error` when it is a string, else its `message` field when that is a string, else its JSON; for a status, it is the failed run's `output`. `isTemporary` is `retry.ts`'s test: overloaded, rate limit, 429/503/529, "temporarily unavailable", `ECONNRESET`, `ETIMEDOUT`. Fixture 09's "not connected to any AI provider" isn't temporary, so it is reported at once.

A replayed `failed` run is never retried: the turn can't tell whether a tool ran in it. An `interrupted` run (a clean Hermes stop) isn't retried either: D3 advances the key only after a temporary *failure*.

**Retry later** (the only retry path): `deps.park(message, retryAttempt)` (`retry.ts`, the same 5/15/30/60/120 s schedule as OpenClaw turns; a rejection counts as `false`). On `true`, `t.parked()` and log `yorozu: hermes run parked (retry <retryAttempt + 1> queued): <reason>`. On `false` (from `retryAttempt` 5): `t.fail` with "The Hermes test backend isn't answering." or "Hermes: <text>". A stopped Hermes therefore gets 6 POSTs in about 4 minutes, then one error.

**Mirror.** `appendSessionTranscriptMessageByIdentity` (before-code question 1) appends one user message: `message.text` only (no quote line, no attachment note), with `__openclaw.transport.messageId = messageId`, `provenance.kind: "external_user"`, and the host receipt time. Quotes and attachments aren't in history for these messages; accepted.

### Turn outcomes (H3)

| Event | Action |
|---|---|
| `tool.started` | `t.tool(callId, name, "running")`. `callId` is `hermes:<runId>:<id>`, where `<id>` is the event's tool call id if it has one (field name from step 8), else its `seq`. |
| `tool.completed` | `t.tool(callId, name, ok ? "done" : "failed")` (the success field from step 8). Without a tool call id, it matches the oldest open `tool.started` with the same name, else the oldest open one. |
| `approval.request` | `status(runId)`, then `deny` for each pending control of the approval kind (name from step 9). Each adds "Denied: <tool> needed an approval Yorozu can't show yet." to the reply, `<tool>` from the control's `tool` field, else "a tool". With none pending, or if a `deny` throws: `stop(runId)` (best effort) and `t.fail("Hermes asked for an approval that could not be answered.")`. Step 9 can remove this row (Further notes). |
| `run.completed`, `run.failed`, `run.interrupted`, `run.cancelled` | The status table. |
| anything else | Ignored. Each unknown kind is logged once per process. |

`externalTurn(ctx, message)` sits beside `handleMessage` in `conversation.ts` and reuses its module-private `registerTurn` and `removeTurn`. Its operations are idempotent, and the first end wins:

| Operation | What it does |
|---|---|
| (creation) | `registerTurn(message)`; a parked rerun reuses the live turn |
| `handing()` | ledger `handing(messageId, convId)`; resolves when the write lands or has failed (logged); never rejects |
| `started()` | `run_started` once; typing on, repeated every 8 s by its own `setInterval`, capped at 30 min; ledger `runStarted(messageId, attempt)` |
| `tool(callId, name, status)` | the `tool` event; on a new `callId`, `owner.steps` and `activityTurn {kind: "step"}` |
| `fail(text)` | `error {code: "run_failed", message: text}`; then as `done()` but with `activityTurn {kind: "failed"}` |
| `parked()` | typing off; live turn and Live Activity job kept; ledger `turnEnded(messageId, convId, true)` |
| `done()` | typing off; live turn removed; `activityTurn {kind: "done"}`; ledger `turnEnded(messageId, convId, false)` |
| `toolSeen` | true once `tool()` has run |

It copies the about 25 lines of `run_started`, typing and tool handling from `handleMessage` instead of extracting them, and doesn't touch `runningTurns` (a card-filing marker; Hermes sends no cards) or sync 03's `executing` map: a device that opens a session mid-turn learns of a Hermes turn from the next typing keepalive (up to 8 s), as before sync 03. `handleMessage` isn't changed (D1); `genui-golden` and `prerun-error` guard that. The ledger calls reach the ledger the same way `handleMessage`'s do (`currentLedger()`); H3 adds no second path. Hermes turns never call `dispatchReturned` or `startedAfterReturn`, so their entries are never `queued`.

### Restarts, reloads and the sync ledger

A Hermes turn uses the sync v4 ledger as an OpenClaw turn does, with the Hermes POST in place of OpenClaw's dispatch: the Hub's `claim` (dedupe) always; `handing` awaited before every POST; `runStarted` at `t.started()`; `turnEnded` at every end and park. The sweep reads only the entry's state, so CA-6 holds unchanged: a turn the restart caught before `handing` is `accepted` and gets the Interrupted row; a handed turn is `settled` and gets none.

| Event | What happens |
|---|---|
| Plugin reload | Nothing is aborted. An in-flight Hermes turn keeps its deps and finishes. `broadcast`, `activityTurn` and `notifyReply` already forward to the current relay host. The Hermes state (route map, FIFO) survives. If the backend is now off, new messages go to OpenClaw, and parked Hermes messages rerun on OpenClaw (`runParked` then calls `handleMessage`). |
| Gateway restart, turn parked | The retry store holds it, so the sweep leaves it alone. `runParked` reruns it: `routedRerun` finds its key-store entry and calls `hermesTurn` with the stored `retryAttempt` and the same key (replay). |
| Gateway restart before `handing` (steps 1–5) | Hermes never got the POST. The entry is `accepted`, so the sweep marks it `interrupted` (if the conversation's session exists) and a `session-report` device gets the Interrupted error at its next session open. Resend sends a new message id, so a new key. |
| Gateway restart after `handing` | No requeue (sync decision 5), no row (CA-6): the entry is `settled`, and the device's 10-minute window ends the turn. The Hermes run is orphaned: it may still finish, its output isn't delivered, and it stays unsettled for the next turn's step 3. |
| Hermes clean stop mid-run | `run.interrupted` (pending step 11): `run_failed`. |
| Hermes `kill -9` mid-run | Lost stream. `status` throws while Hermes is down: "Lost contact…", the id stays unsettled. The next turn resolves it in step 3 once Hermes is back, even across a Gateway restart, because the id is in the route store. |
| Gateway and Hermes at once | Not tested on its own (Further notes). |

`runParked` dispatches by the key store, not by the current route, so a message OpenClaw parked never reruns on Hermes:

```ts
runParked(abortSignal, (message, attempt) =>
  void (deps ? routedRerun(deps, message, attempt) : handleMessage(turn, message, attempt)));
// routedRerun: on the FIFO, keys.lookup(messageId) ? hermesTurn(…) : handleMessage(deps.turn, …).
// A lookup that rejects fails the message closed with one run_failed; it never falls back to OpenClaw,
// because Hermes may already have admitted it.
```

### Measurement (D5)

**Usage line.** One per delegated turn, at its final end (a park isn't an end; the rerun writes it), including turns that never got a run id:

```
yorozu: hermes turn conv=<convId> message=<messageId> key_attempt=<n> retry=<retryAttempt> run=<runId|-> outcome=<outcome> first_event_ms=<n|-> total_ms=<n> input_tokens=<n|-> output_tokens=<n|-> model=<m|->
```

| Exit | `outcome` |
|---|---|
| Reply sent | `completed` |
| Hermes ended the run `failed`, `interrupted`, `cancelled`, or left it `unknown` | `failed` |
| Retries used up while `unavailable` | `unreachable` |
| The 30-minute cap | `capped` |
| Lost stream | `lost` |
| Anything else: key write, `auth`/`conflict`/`http`/`not_found`, empty reply, send status not `sent`, approval failure, unexpected throw | `error` |

- `first_event_ms`: from the first `createRun` call of this attempt to the first `data:` event. `total_ms`: from that call to the end.
- Tokens and `model` (`runtime.model`, confirmed at step 8): from one best-effort `status(runId)` after the end; a throw leaves `-`.
- The line never holds message text or the key.

**Latency (P13).** Step 13 records each task's wall time on both backends: from sending the prompt to the final answer. That gives 20 paired measures. `total_ms` of real Hermes turns is reported for information.

**The 20-task set.** The tasks and both backends' answers from step 13, in the owner's notes vault under `Projects/Yorozu/`.

### Module signatures (sketch: names may change, shapes may not)

```ts
// src/hermes-client.ts (H2; Node built-ins only; in tsconfig.standalone.json)
export type HermesErrorKind = "unavailable" | "auth" | "not_found" | "conflict" | "http";
export class HermesError extends Error {
  constructor(readonly kind: HermesErrorKind, message: string, readonly status?: number, readonly code?: string);
}
export type RunStatus = {
  status: string;                      // "started" | "running" | "completed" | "failed" | "cancelled" | "interrupted" | "unknown" | …
  admissionId?: string; generation?: number;
  output?: string; model?: string;     // a failed run's output is its error text
  usage?: { inputTokens?: number; outputTokens?: number };
  pendingControls: { id: string; kind: string; tool?: string }[];
};
export type RunEvent = { event: string; seq: number; data: Record<string, unknown> };   // data: the whole parsed object
export interface HermesClient {
  createRun(req: { key: string; body: string }): Promise<{ runId: string; status: string; replayed: boolean }>;
  status(runId: string): Promise<RunStatus>;
  events(runId: string, signal?: AbortSignal): AsyncIterable<RunEvent>;
  deny(runId: string, requestId: string, generation: number): Promise<void>;
  resolveUnknown(runId: string, admissionId: string, generation: number): Promise<void>;
  stop(runId: string): Promise<void>;
}
export function createHermesClient(opts: { url: URL; key: string; timeoutMs?: number; idleMs?: number }): HermesClient;

// src/backends.ts (H1)
import type { Keyed } from "./cards.js";
export type HermesBackend = { url: URL; key: string };
export type Route = { unsettled: string[] };
export type KeyRecord = { keyAttempt: number };
export type HermesState = {
  routedToHermes(convId: string): boolean;                         // sync, from the map
  setRoute(convId: string): Promise<"set" | "already" | "full">;    // rejects (map undone) if the store write fails
  unsettled(convId: string): string[];
  addUnsettled(convId: string, runId: string): Promise<void>;       // idempotent
  removeUnsettled(convId: string, runId: string): Promise<void>;
  keys: Keyed<KeyRecord>;
  serial(convId: string, fn: () => Promise<void>): Promise<void>;   // the FIFO
};
export function resolveHermesBackend(cfg: OpenClawConfig, log?: Log): HermesBackend | undefined;
export function createHermesState(
  open: <T>(opts: { namespace: string; retention?: "retained"; maxEntries?: number; overflowPolicy?: "evict-oldest" }) => Keyed<T> & { entries(): Promise<{ key: string; value: T }[]> },
  log?: Log,
): Promise<HermesState>;
export function openHermesState(log?: Log): Promise<HermesState | undefined>;   // one per module; undefined (logged) if the load fails

// src/conversation.ts (H3; additions only)
export type TurnContext = /* the existing type, now exported */;
export type ExternalTurn = {
  handing(): Promise<void>;            // ledger handing(messageId, convId); never rejects
  started(): void;                     // also ledger runStarted(messageId, attempt)
  tool(callId: string, name: string, status: ToolStatus): void;
  fail(text: string): void;
  parked(): void;
  done(): void;
  readonly toolSeen: boolean;
};
export function externalTurn(ctx: TurnContext, message: Message, attempt: number): ExternalTurn;   // attempt = retryAttempt

// src/hermes-turn.ts (H3)
export type HermesDeps = {
  client: HermesClient;
  state: HermesState;
  turn: TurnContext;
  park: (message: Message, retryAttempt: number) => Promise<boolean>;   // retry.ts park
  log?: Log;
};
export const hermesClients = { create: (backend: HermesBackend) => createHermesClient(backend) };   // only tests replace `create`
export function routeMessage(deps: HermesDeps, message: Message): Promise<void>;
export function routedRerun(deps: HermesDeps, message: Message, retryAttempt: number): Promise<void>;
export function hermesTurn(deps: HermesDeps, message: Message, retryAttempt?: number): Promise<void>;
export function requestBody(message: Message): string;
```

`Log` is `ChannelGatewayContext["log"]`. `YorozuConfig` (`channel.ts:49`) gains `backends?: { hermes?: { enabled?: boolean; keyFile?: string } }`. Log lines use `errorTag` from `cards.ts`. In H3, `startAccount` builds `deps` after the sync sweep (sync start order step 3) and before `runParked` (step 5):

```ts
const hermes = resolveHermesBackend(ctx.cfg, ctx.log);
const state = hermes && (await openHermesState(ctx.log));
const deps = state && { client: hermesClients.create(hermes), state, turn, park, log: ctx.log };
// onMessage: (message) => void (deps ? routeMessage(deps, message) : handleMessage(turn, message)),
```

When `deps` is undefined, `onMessage` and `runParked` are exactly as at the parent commit.

### Tickets, order and gates

| # | PR | Base branch | May start | May merge |
|---|---|---|---|---|
| 0 | `docs: Hermes backend test design` (this file only) | `main` | now | on the owner's approval |
| H0 | Operator steps 7–13 (no PR) | — | now | — |
| H1 | `feat(plugin): accept the Hermes test backend config (dormant)` | sync ticket 02's PR branch, draft | once that branch exists | into `main`, after sync ticket 02 merges and the stop rule passes |
| H2 | `feat(plugin): Hermes client with fake-server tests (dormant)` | H1's branch, draft | after steps 8–11 and 13 pass the stop rule | into `main`, after H1 merges |
| H3 | `feat(plugin): run an opted-in conversation's turns on Hermes` | H2's branch, draft | after the owner's step-7 answers and step 9 | into `main`, after H2 merges and the before-code answers are in the PR |
| H6 | The test run, the report, and on a no-go the removal PRs | — | after H3 merges and step 14 | — |

- **Why sync ticket 02, not 01.** H3 calls `handing` and relies on the sweep's `accepted`-only rule, both ticket 02; on ticket 01 alone every Hermes entry would be a bare dedupe record and H3 would change again when 02 lands. H1 and H2 use no ledger API; they sit on ticket 02's branch so the stack has one base. Sync tickets 03 (`run_started` at session open) and 04 (the app) aren't needed: Hermes turns stay out of `executing`, and the Interrupted row needs no Hermes change.
- **Merged forward only.** History on these branches is never rewritten. New commits on a base branch are merged into the branch above it (sync 02 → H1 → H2 → H3). When a base PR merges into `main`, the next PR's base becomes `main` and `main` is merged into it.
- **Deadline.** If sync ticket 02's PR hasn't merged by 2026-12-10, H3 can't run long enough before the exception ends. Yorozu (the agent) then tells the owner, who decides whether to extend.
- **Every merge** to `main` needs the owner's approval in the owner's own words.
- **Commits.** Each PR's first commit holds only red tests, and the PR body names each one and its failure on the parent. Conventional Commits, signed.
- **Release and deploy** (on push to `main`; merges between stacked branches trigger nothing): PR 0 triggers nothing (`generate.ts` reads only top-level `docs/*.md`). H1 touches `plugins/**` and `apps/mcp/scripts/generate.ts`: Release Mac yes (a dormant beta), Deploy website no. H2 and H3 touch `plugins/**`: Release Mac yes; H2's beta is dormant too.

**H1: config and state (dormant).**

| Action | File | What |
|---|---|---|
| Modify | `plugins/openclaw-yorozu/openclaw.plugin.json` | the `backends` property |
| Create | `plugins/openclaw-yorozu/src/backends.ts` | `resolveHermesBackend`, `createHermesState`, `openHermesState` |
| Modify | `plugins/openclaw-yorozu/src/channel.ts` | `YorozuConfig`; the `resolveHermesBackend` call |
| Modify | `apps/mcp/scripts/generate.ts` | `TEST_ONLY_KEYS`, skipped by `hostSettings` |
| Create | `plugins/openclaw-yorozu/test/backends-config.test.ts` | red tests; copies the `channel()` helper from `presentations.test.ts:947`; clears `host.stores` before each test |

Red tests:
1. The manifest has `backends.hermes` with `additionalProperties: false` at both levels, and `enabled` defaults to `false`.
2. Flag absent: `resolveHermesBackend` returns undefined and logs nothing. `startAccount` opens neither namespace, and a stubbed global `fetch` is never called.
3. `enabled: false`: one `hermes backend off: disabled`.
4. Each refusal with its reason: a relative path, a `~/` path, a missing file, a directory, mode 0644, an empty key, a key of only quotes.
5. Mode 0600 and 0400 are accepted. A quoted key loses its quotes. The URL is `http://127.0.0.1:8652/`.
6. The key text never appears in any log line from tests 3–5.
7. `createHermesState` over a fake store: `setRoute` then `routedToHermes` is true; a second `openHermesState` (reload) returns the same instance; a new `createHermesState` over the same rows (restart) sees the route; the 21st `setRoute` answers `"full"`; `unsettled` keeps 10; `addUnsettled` twice keeps one; a failing store write rejects and leaves the map unchanged; a throwing FIFO link doesn't block the next.

Guards: `hub-session`, `prerun-error`, `genui-golden`, `presentations`, unmodified.

**H2: client (dormant).**

| Action | File | What |
|---|---|---|
| Create | `plugins/openclaw-yorozu/src/hermes-client.ts` | the client |
| Modify | `plugins/openclaw-yorozu/tsconfig.standalone.json` | add `src/hermes-client.ts` to `include` |
| Create | `plugins/openclaw-yorozu/test/fixtures/hermes-0.23.1/` | a byte-exact copy of the H0 fixtures without `probe.sh`, plus a `README.md` naming the source and date |
| Create | `plugins/openclaw-yorozu/test/hermes-server.ts` | a `node:http` fake Hermes on `127.0.0.1:0` that plays an ordered script per test: method, path and `Idempotency-Key` → a fixture or an inline response (429, 503, 307, a hang, a reset socket, a mid-stream close). It records each request's headers and body. Not a `*.test.ts`. |
| Create | `plugins/openclaw-yorozu/test/hermes-client.test.ts` | red tests |

Red tests:
1. Each error-kind row, one test each. `unavailable` covers a closed port, 429, 503, a hang past `timeoutMs` and a reset socket.
2. A 307 to another server is `http`, and the other server gets no request.
3. `createRun` sends the `Idempotency-Key` and the body byte for byte. Fixture 11 parses as `{replayed: true, status: "failed"}`.
4. `status` parses fixture 10, including `admissionId`, `generation` and empty `pendingControls`. Fixture 16 is `not_found`.
5. `events` on fixture 09 yields one `run.failed` with `seq` 0, `data.error` as recorded, and ends. It ignores comments, joins multi-line `data`, skips non-JSON `data`, ends on a server close without `: stream closed`, and ends after `idleMs`.
6. The exact bodies of `deny` and `resolveUnknown`; `stop` has none.
7. For every error kind, neither `String(error)` nor `error.stack` contains the key.
8. Scrub: no fixture file contains `Authorization` or matches `/Bearer [A-Za-z0-9]/`.
9. A fixture test for each step 8–11 recording (a completed run with tools and `usage`, `approval.request`, `run.interrupted`, `unknown` and `resolve-unknown`, an event replay of a finished run). H2 starts after those steps, so these are red tests like the rest.

Guards: the standalone typecheck passes with `hermes-client.ts` included.

**H3: delegated turns.**

Before code, Coder answers these by reading `~/openclaw` (2026.9.8, read only) and writes the answers in the PR. If an answer is "no" or unclear, Coder stops and reports to Yorozu (the agent) before coding.

| # | Question | If yes | If no |
|---|---|---|---|
| 1 | Is `appendSessionTranscriptMessageByIdentity` (`openclaw/plugin-sdk/session-transcript-runtime`) reachable from a plugin installed with `--link`, the call for a user message with `__openclaw.transport.messageId` and `provenance.kind: "external_user"`, and does it leave an existing session entry unchanged? | use it for the mirror | stop and report |
| 2 | Does an appended user message leave OpenClaw with no pending turn (no run, no restart-recovery marker)? | as designed | stop and report |
| 3 | Does `sendDurableMessageBatch` run the outbound adapter's `afterDeliverPayload`, which sends the push? | no push call in `hermesTurn` | call `notifyReply(convId, firstMessageId, text)` once after a `sent` |

| Action | File | What |
|---|---|---|
| Create | `plugins/openclaw-yorozu/src/hermes-turn.ts` | `routeMessage`, `routedRerun`, `hermesTurn`, `requestBody`, `hermesClients` |
| Modify | `plugins/openclaw-yorozu/src/conversation.ts` | export `TurnContext`; add `externalTurn` |
| Modify | `plugins/openclaw-yorozu/src/channel.ts` | build `deps`; branch `onMessage` and `runParked` |
| Modify | `plugins/openclaw-yorozu/test/genui-host.js` | Recording stubs: `sendDurableMessageBatch` (records its arguments; returns `{status: host.batchStatus ?? "sent"}`), `appendSessionTranscriptMessageByIdentity` (records; fails when `host.mirror === "reject"`), `notifyReply` (records). `runRelayHost` and `runParked` keep their last arguments in `host.relay` and `host.rerun`, unless sync 02's recording stubs already do. |
| Create | `plugins/openclaw-yorozu/test/hermes-turn.test.ts` | red tests |
| Create | `plugins/openclaw-yorozu/test/backend-passthrough.test.ts` | the backend-off pass-through check (Routing); runs only when `YOROZU_OPENCLAW_SDK` names an installed OpenClaw package root, so CI skips it |

**Test seams.**
- **Level.** Turn tests call `routeMessage` and `routedRerun` with injected `HermesDeps`: a real client from `createHermesClient` bound to `hermes-server.ts` on port 0, a `createHermesState` over the fake keyed store, the stand-in `TurnContext`, and the real `park`. Three wiring tests go through `startAccount` (tests 2, 3 and 21); test 3 replaces `hermesClients.create` with one that binds the fake server's port.
- **The real `retry.ts`.** As `conversation-owner.test.ts` does, the test file registers its own `registerHooks` resolve hook after importing `genui-hooks.ts`, so it runs first. It sends `./retry.js` imported from `src/hermes-turn.ts`, and the test's own import of `src/retry.ts`, to the real file with `shortCircuit`. `retry.ts`'s own `./runtime.js` import still reaches the stub, so `park` writes the fake `retry` store. `channel.ts` keeps the stub `retry`. The 5 s tick runs under `node:test` mock timers.
- **From sync 01 and 02**, used unmodified: the fake keyed store that doesn't evict when `maxEntries` is undefined (the `retry` and `backends` stores need it), with reopen over the same rows and the write-failure modes; `createLedger` over fake stores; the way `conversation-ledger.test.ts` connects `conversation.ts`'s writers to a test ledger; sync 02's recording stubs on the `startAccount` base. Ledger results are read from the `runs` store rows.
- **Restart simulation** (sync's restart seam, plus Hermes state). The turn before the restart is left hanging: the fake server never answers its open requests, and the test never advances mock time past its 30-minute cap. Then a new `createLedger` over the same fake store rows with a new `bootId`, `load()`, `sweep()`; a new `createHermesState` over the same rows; new deps. `conversation.ts`'s module state isn't reset, so restart tests assert only store rows, device events after the restart, and the fake server's requests.
- **What the stubs drive.** The `sendDurableMessageBatch` stub doesn't run the outbound adapter, so tests check its call (text, `mirror`) instead of `reply` events, and count pushes only through `notifyReply` when question 3 is "no".

Red tests:
1. Routing: one test per cell of the routing table, including the no-entry notice (no `setRoute`, no mirror) and the full-store notice.
2. Backend off (flag absent), through `startAccount`: `host.relay`'s `onMessage` and `host.rerun` reach `handleMessage`; the fake server gets no request; neither namespace exists.
3. Wiring with the backend on, through `startAccount`: an opted-in message reaches the fake server through `hermesClients.create`.
4. A plain turn: `run_started` once; typing on, then off; the batch called once with `output` and `mirror`; the user message mirrored once with the Mirror fields; `activityTurn` `done`; ledger entry `settled`; one usage line with `outcome=completed`; one push per question 3.
5. When the fake server receives the POST, the key-store row exists and the `runs` entry is `settled` (`handing` landed first). A failing `handing` write is logged and the POST still goes.
6. Bounded retries: the fake server refuses every connection. Exactly 6 POSTs, each after its scheduled delay (5, 15, 30, 60, 120 s, each within one 5 s tick of the previous attempt's end), all with key `<id>:0` and the same body. Then one `run_failed`, `outcome=unreachable`, `run=-`, and no 7th request after another 10 minutes of mock time.
7. A timeout after admission, then a rerun: the second POST carries the same key, the server replays, the turn attaches, and the server saw one run.
8. Replay by status: `completed` delivers once; `failed` (fixtures 11 and 10) is `run_failed` with no batch call, even for a temporary error; `cancelled` and `interrupted` are `run_failed`; `running` attaches and delivers; `unknown` calls `resolveUnknown` with the exact body, then maps.
9. `run.failed` temporary (`rate limit`) with no tool: key `:1`, parked, and the rerun answers. The same after a `tool.started`: `run_failed`. Fixture 09's permanent error: `run_failed` at once.
10. `run.interrupted`, with or without a tool: `run_failed`, the key unchanged.
11. Lost stream: status `running` re-attaches and `lastSeq` drops replayed events (no second tool row, no second `deny`); a stream that closes at once is re-attached 5 times, 2 s apart, then fails `lost`; `events` throwing `not_found` reads `status`; a `status` throw fails with the id kept unsettled.
12. `kill -9`, a simulated restart, then the next message: step 3 calls `resolveUnknown` from the route store, and the new run runs.
13. Approval: `deny` with the exact body; the "Denied:" line ends the reply; the run completes. No pending control, or a failing `deny`: `stop`, then `run_failed`.
14. `requestBody`: byte-identical across reruns; the quote line with text, with multi-line text, and without text; the attachments note with 1 and with 3; text only.
15. The 30-minute cap: `stop`, then `run_failed`, `outcome=capped`, the id kept unsettled.
16. Plugin reload mid-turn: a second deps over the same `openHermesState` instance while the first turn's stream is open; the reply is delivered once.
17. Restart interplay, each across a simulated restart with the session present: a turn held before `handing` (the fake server got no POST) is `interrupted` and a `session-report` device gets one Interrupted error; a turn cut off after its POST stays `settled`, gets no error and is never rerun; a parked one is left alone by the sweep and reruns through `routedRerun` with the same key.
18. A message OpenClaw parked reruns on OpenClaw after its conversation was opted in; a key-store lookup that rejects fails the message closed, with no `handleMessage`.
19. Error paths, one test each: `auth` and `conflict` from `createRun`; an empty `output`; a batch status other than `sent`; a failing key write; a failing mirror (logged, the turn goes on); an unexpected throw (one `run_failed`, the FIFO's next message still runs). Each writes one usage line with its `outcome`.
20. FIFO: two messages in one opted-in conversation run in order; a message right after `/backend hermes` queues behind the opt-in.
21. Backend turned off by a reload: a parked Hermes message reruns on OpenClaw.
22. No log line from any test contains the key.

Guards: `genui-golden`, `prerun-error`, `hub-session`, `presentations` and the sync 01/02 tests, unmodified. `backend-passthrough` is new in this PR but passes on the parent too, so it is a guard, not a red test: run with `YOROZU_OPENCLAW_SDK=~/openclaw`, it must pass; without it, it is skipped (as in CI).

### Operator steps (H0 and enablement)

Yorozu (the agent) runs every step on the Mac mini, except where it says the owner. Coder runs none of them.

`H` stands for `HERMES_HOME=~/.hermes-yorozu-test ~/.hermes-yorozu-test/hermes-agent/.hermes/bin/hermes`.

**Forbidden commands:** `hermes` with any other home or without `HERMES_HOME`; `hermes claw cleanup`; `hermes claw migrate`; any `--migrate-secrets`. `import-agent` only as written in step 12.

**Start and stop of the hand-started Hermes gateway** (until step 14):
- Start: `mkdir -p ~/.hermes-yorozu-test/logs`, then `H gateway run >> ~/.hermes-yorozu-test/logs/hand.log 2>&1 &`. Check the subcommand with `H gateway --help` first.
- Stop: `kill $(lsof -tiTCP:8652 -sTCP:LISTEN)`. Hard stop for step 11: `kill -9` instead. Check with `lsof -iTCP:8652`.

**`probe.sh`** lives in the box handover fixtures folder. Copy it to `~/.hermes-yorozu-test/probe/` on the mini and run it from there. Each new recording takes the next free `NN` and adds a line to `index.txt`. Recordings go back to the handover folder, scrubbed (the H2 scrub test checks).

**Done (2026-11-19):** steps 1–6, as one install:
1. A separate clone at `3b42157858`, home `~/.hermes-yorozu-test`, `cli.expose_on_path: false`.
2. The API server only, on `127.0.0.1:8652`, with its key in the home's `.env` (0600) and `auth.adopt_external_logins: false`. No messaging platform.
3. OpenClaw unchanged (`~/.openclaw/openclaw.json` mtime and sha256 recorded in the rollback note).
4. Fixtures 01–17.

**Pending:**

7. **The owner: Codex sign-in and two questions** (about 5 minutes; the code lasts 15 minutes). The owner signs in with the same ChatGPT account OpenClaw uses, so the two share its quota.
   1. In Terminal on the mini: `HERMES_HOME=~/.hermes-yorozu-test ~/.hermes-yorozu-test/hermes-agent/.hermes/bin/hermes model`.
   2. Choose OpenAI Codex, and answer **N** to importing the Codex CLI tokens.
   3. Open `https://auth.openai.com/codex/device`, enter the code, sign in.
   4. Yorozu (the agent) checks with `H auth status openai-codex`.
   5. Yorozu (the agent) asks the owner, yes or no: (a) Is Yorozu's reading right that the Hermes gateway (Python) runs as a third-party runtime, outside "never Python"? (b) In an opted-in conversation, may `/new` and `/reset` answer with a notice instead of resetting in place? A "no" to (a) stops the test. A "no" to (b) holds H3 until Yorozu (the agent) and the owner settle what `/new` does there.
8. **A completed run with a tool.** POST a run with `session_id` `yorozu-h0-probe-8` and input "Run `date` in the terminal and tell me the output." Record the event stream, the status (with `usage` and `runtime`), the tool events' fields (tool call id, success field), and the event stream fetched again after the run finished (does it replay from `seq` 0?).
9. **Approvals.**
   1. Set `agent.disabled_toolsets: [cronjob]` in the test home's `config.yaml`.
   2. Send each command of a fixed list of 10 as its own run (session `yorozu-h0-probe-9-<n>`): `ls ~`, `cat /etc/hosts`, `mkdir -p /tmp/yorozu-h0 && touch /tmp/yorozu-h0/a`, `rm -rf /tmp/yorozu-h0`, `curl -sI https://example.com`, `git -C ~/.hermes-yorozu-test/hermes-agent status`, `chmod 777 /tmp/yorozu-h0-x`, `sudo -n true`, `osascript -e 'display notification "h0"'`, `kill -0 1`. For each, record whether `approval.request` came. The result is the list of commands `smart` runs without asking.
   3. For one that asked: record `approval.request`, the status's `pending_controls` (with the approval kind's name), the `deny` exchange, and what the run did next.
   4. Check whether `approvals.mode` can deny every escalation server-side while the run continues (Further notes).
10. **Two runs at once on one session.** Two POSTs with different keys and the same `session_id`, under 1 s apart. Record whether the second waits, fails or runs alongside. For information: H3's FIFO serializes either way.
11. **Interrupted and unknown runs.** Start a run with a long tool ("Run `sleep 60`, then say done."), stop the Hermes gateway cleanly mid-run, and record `run.interrupted`. Repeat with `kill -9`, start Hermes again, and record `unknown`, a second run on that session waiting, `resolve-unknown`, and whether `GET /api/sessions/{id}` names the session's running or `unknown` run (Further notes).
12. **Persona.**
    1. `H plugins install agent-importers`.
    2. `H import-agent openclaw --dry-run`, and confirm from its output that it only reads `~/.openclaw`.
    3. Review each MCP server it would import (name, command, `trust`). Drop any that writes outside the Hermes home.
    4. `H import-agent openclaw` (without `--migrate-secrets`).
    5. Check that `~/.openclaw/openclaw.json`'s mtime and sha256 still match the rollback note.
13. **The quality batch (P12, P13).** Run it while the owner isn't using Yorozu.
    1. Yorozu (the agent) picks 20 read-only prompts (no sends, no writes) from the owner's past Yorozu conversations and lists them in the vault note first.
    2. Hermes answers each in a fresh session `yorozu-p12-<n>`, with the fixed instructions.
    3. OpenClaw answers each in a throwaway session that no Yorozu conversation uses, through OpenClaw's CLI agent command (check the form with `openclaw agent --help`).
    4. For each task and backend, record the wall time from sending the prompt to the final answer.
    5. Each pair is stripped of backend names, model names and tool traces, and put as A and B by a coin flip. The key stays in a separate file. The owner sees one vault note with 20 sections and writes A, B or tie for each.
14. **Enablement.** After H3 merges, with the owner's approval of these yes/no questions, asked together:
    - Edit the OpenClaw config to turn on the flag (and restart the Gateway if needed)?
    - Run the Hermes gateway under launchd (label `local.hermes-yorozu-test`, `KeepAlive: true`) instead of by hand?

    A "no" to the second keeps Hermes hand-started. Then:
    1. Check that the Gateway's plugin is at the H3 merge or later (`openclaw plugins list`).
    2. `cd ~/.hermes-yorozu-test && (umask 077; grep '^API_SERVER_KEY=' .env | cut -d= -f2- > yorozu-plugin.key)`.
    3. `cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak-hermes-test`.
    4. `openclaw config set channels.yorozu.backends.hermes.keyFile ~/.hermes-yorozu-test/yorozu-plugin.key` (expanded to an absolute path), then `openclaw config set channels.yorozu.backends.hermes.enabled true`. Check that the Gateway log shows `yorozu: hermes backend on`.
    5. Write `~/Library/LaunchAgents/local.hermes-yorozu-test.plist`: `Label` `local.hermes-yorozu-test`; `ProgramArguments` `[<home>/hermes-agent/.hermes/bin/hermes, gateway, run]`; `EnvironmentVariables` `{HERMES_HOME: <home>}`; `KeepAlive` true; `StandardOutPath` and `StandardErrorPath` `<home>/logs/launchd.log`.
    6. Stop the hand-started Hermes gateway, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.hermes-yorozu-test.plist`.
    7. Check with `openclaw config get channels.yorozu.backends` and `launchctl print gui/$(id -u)/local.hermes-yorozu-test`.

**Stop rule.** H2 and H3 don't start, nothing merges, and the result goes to the owner as a no-go, if either holds:
- by step 11, Hermes hasn't completed a run with a tool on the Codex sign-in;
- in step 13, Hermes is preferred in fewer than 5 of the 20 pairs.

### Test plan and go/no-go report (H6)

| Row | Scenario | Where | Pass |
|---|---|---|---|
| P1 | Plain chat over the relay and the direct listener | The owner's devices | ✓✓, then the reply, the same on both devices |
| P2 | A long tool run (about 5 min) | The owner's devices | Tool rows and Live Activity steps update; typing never lapses |
| P3 | A device offline during the turn | The owner's devices | The reply shows after catch-up, once, in order |
| P4 | Two devices, sending from one | The owner's devices | The other shows the message and the reply, no duplicates |
| P5 | Hermes unreachable or rate-limited before any tool; separately, a clean stop and a `kill -9` mid-run | Test home + a device | Unreachable or rate-limited, and back within about 4 min: the reply arrives once. Every other case: one error row, no stuck typing, and the next message in that conversation runs. |
| P6 | A Gateway restart mid-turn | H3 test 17 | Before `handing`: one Interrupted error. After: no row, no rerun. Parked: the rerun replays the same key (one Hermes run). |
| P7 | The same message twice; a timeout after admission; a rerun after a park | H2/H3 tests | One Hermes run per key; the key advances only after a temporary `run.failed` with no tool |
| P8 | Rename, pin, archive, delete; `/new` | The owner's devices | As on OpenClaw; `/new` gets the notice |
| P9 | History after reinstalling the app | The owner's device | The full conversation, including the `/backend hermes` line, each Hermes reply once |
| P11 | A command that needs approval | H3 test 13 + one real check after step 9 | Denied with the plain line; the run continues |
| P12 | Quality on the 20 tasks | Step 13 | Hermes / OpenClaw / tie counts |
| P13 | Latency and tokens | Step 13 wall times; usage lines | p50 and p90 per backend over the 20 paired tasks; tokens per Hermes turn |

- **Real use** starts after step 14. Only turns sent while the Hermes gateway was up count. Turns cut off by a Gateway restart are excluded for both backends.
- **Restarts.** Gateway restarts from `~/.openclaw/logs/gateway-restart.log`; Hermes restarts from the `runs = N` line of `launchctl print gui/$(id -u)/local.hermes-yorozu-test`.
- **Quota.** Yorozu (the agent) checks `rg -i 'rate.?limit|\b429\b' ~/.openclaw/logs/` daily. Any OpenClaw 429 stops the P12 batch, and Yorozu (the agent) asks the owner to stop sending in opted-in conversations. The flag stays on.
- **Blame.** A double run or lost reply is Hermes's when the plugin log shows one `createRun` per key and Hermes ran it twice or sent no terminal event. Otherwise it is the plugin's.
- **Spend.** At the go/no-go the owner checks the ChatGPT account: no new subscription or billing line.
- **Report.** Yorozu (the agent) writes it to the vault under `Projects/Yorozu/`: P1–P9 and P11 pass or fail; double runs and lost replies with blame; the P12 counts; P13; restart counts; spend; tool gaps.
- **Outcome.** At n = 20 the numbers are indicative only, so the owner decides: **go** (the Yorozu backend switch, which opens ADR-H4), **extend** (moves the go/no-go date; the code stays until then, and a date past 2026-12-31 needs a new owner exception), or **no-go**. One rule is fixed: any double run or lost reply blamed on Hermes is a no-go. With no decision by 2026-12-31, the outcome is no-go.

## Testing decisions

- **Every PR is dormant until the flag is on.** Each ships with a backend-off test (H1 test 2, H3 test 2), so merging it changes nothing for anyone.
- **Seams, highest first.**
  - H3: `routeMessage` and `routedRerun` with injected deps (the real client against the fake Hermes, the stand-in `TurnContext`, the real `retry.ts`), plus three `startAccount` wiring tests (H3 test seams).
  - H2: the client against the same fake server, from the recorded fixtures.
  - H1: `resolveHermesBackend` on real temp files; `createHermesState` over a fake store; `startAccount` on the `presentations.test.ts` base.
- **What a good test checks:** the requests the fake Hermes received (method, path, key, body), the events each device receives, the batch and mirror calls, store rows (including the `runs` ledger), log lines (including the usage line). Not private maps.
- **Prior art:** `prerun-error` and `genui-golden` (turns on the stand-in host); `presentations.test.ts` (`startAccount`); `relay-integration` (a real local server in a test); `conversation-owner.test.ts` (the real-module resolve hook); the sync 01/02 tests (ledger, sweep and retry hook).
- **Acceptance commands** (Node 26, as CI):
  - `node --test 'plugins/openclaw-yorozu/test/*.test.ts'` from the repository root.
  - `tsc -p plugins/openclaw-yorozu/tsconfig.standalone.json` with TypeScript 7.0.2 and `@types/node` 26.6.2 (as `plugin-typecheck.yml`).
  - The full plugin typecheck against the OpenClaw checkout ([plugin README](../../plugins/openclaw-yorozu/README.md#typecheck)), with no errors in plugin files.
  - H1: `node apps/mcp/scripts/generate.ts --check`; `git diff --exit-code apps/mcp/src/content.json` after `node apps/mcp/scripts/generate.ts`; and CI's `mcp` job: `pnpm --filter @yorozu/help-mcp check`, `typecheck` and `test`.
  - H3: `YOROZU_OPENCLAW_SDK=$HOME/openclaw node --test plugins/openclaw-yorozu/test/backend-passthrough.test.ts` (local only; CI skips it).
  - Every PR: `git diff --stat` shows no change to the guard files.

## Alternatives considered

- **Option A: a Hermes platform plugin (Python) as a second Yorozu host.** It ports the Noise sessions, the relay host, history and push to Python, needs a re-pair, and puts Yorozu code in Python.
- **Option C: a standalone Yorozu host that talks to Hermes.** The retirement shape; breaks "No Mac host process". Considered only after a go (ADR-H4).
- **Option D: OpenClaw's agent pointed at Hermes over ACP** (Agent Client Protocol). It moves one OpenClaw agent, so it moves all of Yorozu unless OpenClaw can bind ACP per thread, which wasn't checked.
- **D1 alternative: a backend interface.** More code for a test that is deleted unless it goes.
- **D2 alternative: a Hermes-only conversation record.** The list, pin, archive and history would all need new code.
- **D3 alternative: a fresh key per attempt.** A timeout after admission would run the work twice.
- **D4 alternative: stop the run on a denied approval.** One gated tool would lose the whole answer.
- **D5 alternative: fixed pass bars.** At n = 20 the numbers can't carry a bar.
- **Opting in with the first message of a new conversation.** Cut: OpenClaw would answer the literal `/backend hermes` on the shared quota, and the conversation would stay untitled (`sessions.ts:210` and `push.ts:57` skip `/` text). The notice asks for one message first.
- **Retrying a replayed or interrupted run with the next key.** Cut: the turn can't tell whether a tool ran in a replayed run, and D3 covers only temporary failures.
- **Seeding the Hermes session with OpenClaw's history.** Opting in after one OpenClaw turn keeps that turn small instead.
- **Aborting Hermes turns on a plugin reload.** It drops answers OpenClaw turns keep across a reload.
- **The unsettled run id in memory.** Lost on a restart, it could block a conversation behind an `unknown` run for good.
- **Re-attaching to orphaned runs at start-up.** About 40 lines and a hook into the sync sweep for a rare case; recorded as a cost (Risks).
- **A circuit breaker for the shared quota.** Departs from the auto-retry rule and needs the owner; the daily 429 check is enough for a test.
- **Mirroring tool rows into the transcript.** Unverified API, and no Test plan row needs it.
- **Falling back to OpenClaw when the key lookup fails.** Hermes may already have admitted the message, so it could run on both backends.
- **Documenting `backends` in `docs/setup.md`.** It would start Deploy website for a test-only key.

## Risks

| Risk | Mitigation or check |
|---|---|
| Hermes's terminal, file and browser tools run as the owner's macOS user. They can read `~/.openclaw` and the key file, and web pages can inject prompts. | The same exposure OpenClaw's own exec tools have, for what `approvals.mode: smart` runs without asking (step 9); the plugin denies every escalation that asks. `cronjob` is disabled. If step 9 shows `smart` runs something OpenClaw would ask about, Yorozu (the agent) reports it before step 14. |
| An orphaned Hermes run after a Gateway restart keeps going and its output is never delivered. | It was handed, so it gets no Interrupted row and no Resend (CA-6); the device's 10-minute window ends it. The next turn's step 3 sees the orphan. Counted in the report. |
| A failed `handing` write leaves a handed Hermes turn `accepted`; a restart then marks it interrupted and a Resend may run it twice. | As sync v4's Risks: logged `run ledger write failed`, target 0. |
| A Hermes message that reruns on OpenClaw after the backend goes off was already mirrored. | Accepted. History keys user items by transport message id (`history.ts:403`), so it likely shows once; unverified. |
| Imported MCP servers | Reviewed one by one at step 12; no secrets migrated. |
| The shared ChatGPT quota | The daily 429 check (Test plan). |
| Dormant code in a public beta | Nothing merges before the stop rule; the flag is off by default; backend-off tests prove no Hermes path runs. |
| The sync work slips | The whole stack waits on sync ticket 02; the 2026-12-10 deadline rule. |
| A configured skill or plugin claims `/backend` | Only with the backend off, where `/backend hermes` should reach the agent as text. Rerun `backend-passthrough` against the live install's OpenClaw before step 14. |
| Hermes and OpenClaw histories drift | Opt-in needs one OpenClaw turn first; `/new` and `/reset` answer with a notice. |
| Reply ids differ from the transcript ids | The app's existing text match applies, as for cron deliveries (unverified for Hermes replies; checked in P9). |
| The key leaks | No redirects followed; never logged or put in an error; H2 test 7 and H3 test 22. |
| The `.env` key format differs from what step 14.2 expects | The reader strips one pair of quotes; a wrong key fails with `auth` and "refused the key". |

## Further notes

- **Sync dependency.** Sync v4's CA-6 and CA-7 are decided (Referenced decisions). Hermes uses `claim`, `handing`, `runStarted` and `turnEnded`, and sends no event of its own for a cut-off turn: whatever the gated session-open report sends applies.
- **Approvals, decided at step 9.** If `approvals.mode` can deny every escalation server-side while the run continues, H3 drops `deny`, the `approval.request` row and the "Denied:" line; P11 then passes when the tool step fails and the run continues with Hermes's own message (D4 still holds). Otherwise H3 builds the plugin-side deny. H3's PR states which.
- **Unsettled runs, decided at step 11.** If `GET /api/sessions/{id}` names the session's running or `unknown` run, step 3 reads that instead, and `unsettled`, its cap and its route-store field go. H3's PR states which.
- **Rollback (also the no-go clean-up).** In this order:
  1. Turn the flag off: `openclaw config set channels.yorozu.backends.hermes.enabled false`, or restore `~/.openclaw/openclaw.json.bak-hermes-test`. This edits the OpenClaw config, so it needs the owner's approval. Every conversation is back on OpenClaw at the reload.
  2. Before any revert of H1: `openclaw config unset channels.yorozu.backends`. Otherwise the leftover key fails the restored schema's `additionalProperties: false`.
  3. `launchctl bootout gui/$(id -u)/local.hermes-yorozu-test`, and delete the plist.
  4. Stop the Hermes gateway, then `rm -rf ~/.hermes-yorozu-test` (this also removes the key file).
  5. Revoke the Hermes session in ChatGPT's connected apps.
  6. Revert H3 and H1 (with H2 and `TEST_ONLY_KEYS`), or close them if unmerged.

  Left behind, inert: the keyed-store namespaces `backends` and `hermes-keys`, and the mirrored messages in transcripts, which are normal history. The rollback note for the H0 install is in the owner's vault (`Projects/Yorozu/2026-11-19 Hermes H0 test install rollback`).
- **Unverified.** H0 steps 8–13; the three before-code questions; per-thread ACP routing in OpenClaw (Option D); the Codex plan's limits with two agents on it; the Gateway and Hermes failing at the same moment; `gateway run`, `agent.disabled_toolsets`, `import-agent` and `plugins install` in the test home; replay after a Hermes restart (documented, not recorded); whether the app's text match pairs a Hermes reply with its transcript line.
- **ADRs.** ADR-H1 (D1), ADR-H3 (D3) and ADR-H6 (D2) are the decisions above. ADR-H2: Hermes runs from its own clone and home, on loopback, with no messaging platforms. ADR-H4 (deferred): OpenClaw retirement. ADR-H5: Hermes conversations are text only.

## Review dispositions

EGM round 1 of this dev spec (`.egm/20261119-122924/`, git-ignored). The earlier round's dispositions are in this file's history at `f6816e55`.

| Id | Disposition | Reason |
|---|---|---|
| CB1 | FIXED | Option (a): story 2 cut; `/backend hermes` with no session entry gets "Send one message first, then /backend hermes."; the no-entry `setRoute` branch, the route-without-entry rule, before-code question 5 and those routing cells are gone. The title premise in step 8 now holds. |
| CB2 | FIXED | H3 test seams: `hermesClients.create` as the client factory; turn tests at `routeMessage`/`routedRerun` with injected deps; the stubs H3 adds and the sync 01/02 pieces it uses; the real `retry.ts` through a test-local resolve hook as in `conversation-owner.test.ts`; the restart simulation. |
| CM1 | FIXED | Solution and stories rewritten in one pass; one "What differs" bullet; tool rows live only; story 6 states the key rule instead of "at most once"; stories 13 and 14 moved to Testing decisions. |
| CM2 | FIXED | D3 as written: `interrupted` and a resolved `unknown` fail without advancing the key; a replayed `failed` run is never retried; the event-replay read and old test 9's branches dropped; story 4 and P5 narrowed. S5 #10 not adopted. |
| CM3 | FIXED | One status table, used by the replay, lost-stream and event paths; every terminal row removes the id; distinct texts for interrupted and cancelled. |
| CM4 | FIXED | Error text source for events and statuses; any `events` throw is a lost stream; `lastSeq`; at most 5 re-attaches, 2 s apart. |
| CM5 | FIXED | Catch-all in each entry point; a `.catch` per FIFO link; a rejected key lookup fails closed (F19's fallback not adopted); `setRoute` rejects with the map undone; notices run on the FIFO. |
| CM6 | FIXED | The Python and `/new` questions move to step 7; starting H2 and H3 is gated on the stop rule; story 8 marked pending. F9's "no" path not adopted. |
| CM7 | SUPERSEDED | By Yorozu (the agent)'s final stack order: H1 on sync ticket 02's branch, H2 on H1, H3 on H2, merged forward only; each merges to `main` on its own; the deadline rule covers the stack. |
| CM8 | FIXED | Scope rule carried over; cuts from CB1, CM2, N1, N2; `unsettled` can go after step 11. |
| CM9 | FIXED | Problem states what is measured; Goals and Non-goals added (Out of scope folded in); "extend" named; P13 uses step 13 wall times, which drops the old before-code question 3. |
| CM10 | FIXED | One usage line per turn at its final end, `run=-` when there is none, an exit-to-outcome table, one best-effort final `status` for tokens; H3 tests 4, 6, 15 and 19 check it. |
| CM11 | FIXED | Context paragraph with the Hub; the four owner rules quoted; sync terms point to the sync spec; restated ADR text and the owner's v1 answers removed. |
| CM12 | FIXED | What the stubs drive; the restart simulation; red tests for the listed branches (tests 11, 18–21); H1 store reset and helper copy; tick tolerance per attempt; `presentations` in the H3 guards. |
| CM13 | FIXED | Mirror fields stated; with no session entry nothing is mirrored; the double mirror accepted in Risks. |
| CM14 | FIXED | H1 calls `resolveHermesBackend` as a statement and opens no state; synchronous checks with a read-failure row and log levels; the `mcp` job in acceptance. |
| CM15 | FIXED | "Flag" means only `enabled`, "backend on/off" the resolved state; the replay sentence calibrated. |
| CM16 | CONTEST in part | The Status line now points here with no counts or emoji, and the undefined labels are gone. The dispositions stay in the document because Coder's brief for this round asks for them here; the earlier round's list is left to git history. |
| N1 | FIXED | URL checks, `refused` and the old H2 test 1 dropped; `redirect: "manual"` kept. |
| N2 | FIXED | Route store `retention: "retained"`; `since` dropped. |
| N3 | FIXED | The `requestBody` code and the instructions text replaced by rules. User-visible strings kept: tests check them. |
| N4 | FIXED | `Keyed<T>` and `errorTag` from `cards.ts`. |
| N5 | FIXED | About 25 lines; position in sync's start order; `genui-hooks.ts` row dropped; "store write recorder" wording replaced by the sync 01 list; the `import-agent` citation dropped; the sweep defined via the sync terms; before-code question 1 covers `--link`. |
| N6 | FIXED | Only `events` takes a signal; every 503 is `unavailable`; `RunEvent.data` shape; `addUnsettled` idempotent. |
| N7 | FIXED | `<tool>` from the pending control; approval kind and the success field named as pending steps 9 and 8. |
| N8 | FIXED | `runningTurns` untouched; `YorozuConfig` location; `/new <args>`; the FIFO lives in `HermesState`; why `keyAttempt ≤ retryAttempt` holds. |
| N9 | FIXED | Sync terms, `isTemporary` classes, steps 5–6 and H0 in the order table, the step 9 wording, Cards and Automations, Option B and ADR-H4 defined. |
| N10 | FIXED | Header rewritten: no emoji, no tier, sync v3, plain tense, roles, motivation moved into Problem. |
| N11 | FIXED | Wording passes during the rewrite. |
| N12 | FIXED | S5 #11 lapses if `unsettled` goes at step 11; S5 #10 not adopted (CM2). |
| Sync v4 | ALIGNED | Classifier, `abortedLastRun` risk and v3 writer names removed; `handing` awaited before every POST; a handed Hermes turn gets no row (CA-6); H3 tests 5 and 17 and P6 restated. |
| Pass-through | RECORDED | Backend-off `/backend hermes` verified on OpenClaw 2026.9.8 (Routing, with its caveat); `backend-passthrough.test.ts` ships in H3 as a CI-skipped guard. |
| Not adopted | As recommended | S5 #6, S5 #7, S5 #10, the F2 tool-row mirror, the F9 `/new` "no" path, the F19 fallback and summarising every disposition: each is in Alternatives considered or above. |
