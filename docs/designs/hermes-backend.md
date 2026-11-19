# Hermes Agent as a second backend: side-by-side test

- **Status:** v5, after EGM round 2 (EGM: the multi-stage spec review). Each finding's handling is in "Review dispositions (round 2)"; round 1's are in this file's history at `0e63bcad`.
- **Brief:** the Hermes backend test spec v4 with its §8 decisions (box handover `transfers/20261119-yorozu-hermes-backend-spec.md`). The direction is final.
- **Sync spec:** the sync restart durability spec v5, ticket 01 only: the run ledger, draft PR #751 on branch `feat/sync-ledger`. This spec calls it "the sync spec" and its code "sync 01". What the H tickets call in it is listed once, in "Sync 01 calls". Sync tickets 02–04 are deferred to a later spec and nothing here depends on them.
- **Baseline:** `origin/main` at `8a278a5c`. Nothing this spec describes exists there yet, and neither does sync 01.
- **Roles:** *the owner* uses the app and approves. *The Yorozu agent* (written "Yorozu (the agent)" in the sync spec) owns the product decisions and runs the operator steps on the Mac mini. *Coder* wrote this spec and implements H1–H3. "Yorozu" alone is the product.
- **Box handover:** `/home/box/handover` on the box, the Linux machine the agents share. `transfers/` holds the source specs and the H0 fixtures.
- **Labels:** D1–D5, A-n and the stack order are in "Referenced decisions"; other terms, H0–H3 and P1–P13 in the "Glossary".

## Problem

The owner asked (2026-11-19) to "start testing of hermes agent backend as replacement to openclaw". Today every Yorozu turn runs on OpenClaw, so there is nothing to compare. The test answers one question before any switch: on the owner's real Yorozu conversations, how does Hermes Agent compare with OpenClaw on answer quality, latency, tools and reliability? What is measured, and how, is in "Measurement" and the "Test plan".

OpenClaw Gateway restarts aren't held against Hermes, because the plugin runs inside the OpenClaw Gateway on both backends. The report lists the OpenClaw Gateway's and the Hermes gateway's restart counts for information.

## Goals and non-goals

**Goals.**
1. Run real Yorozu conversations on Hermes beside OpenClaw, on the owner's own devices, about one opted-in conversation at a time, with no re-pair.
2. Produce the go/no-go report (Test plan).
3. Keep the test removable (Rollback).

**Scope rule.** Build only what a Test plan row needs.

**Non-goals.**
- OpenClaw retirement (ADR-H4, after a go only). A backend interface or general multi-backend support (D1).
- Cards, Automations, reactions, attachments and image input on Hermes.
- OpenClaw's own tools (iMessage, Meet, Signal and the owner's other tools) on Hermes. Gaps go in the report.
- An approval screen in the app; an opt-out command; any relay, app or wire change.

## Solution

- The plugin gains a test-only config entry, `channels.yorozu.backends.hermes`. Its `enabled` flag is off by default.
- With the flag on, the owner sends `/backend hermes` in a conversation that already has at least one message. From then on, that conversation's agent turns run on Hermes Agent through its runs API on `127.0.0.1:8652`.
- The plugin keeps every other duty: pairing, the relay, push, the conversation list, history, titles, pin, archive and delete. An opted-in conversation is still an OpenClaw session: the user message and Hermes's final reply are written into its transcript, so history and new devices show them.
- **What differs in an opted-in conversation:**
  - Hermes doesn't see the messages from before the opt-in.
  - Tool rows show live only: history doesn't show them.
  - Attachments aren't sent (the input says so), reactions reach no agent, and there are no cards.
  - Approvals are denied with a plain line.
  - OpenClaw commands (`/help`, `/status`, `/model`, an abort) go to Hermes as plain text; only `/new` and `/reset` are answered by the plugin.
  - A message sent while a Hermes run is going waits until that run ends (up to 30 minutes), so it can outlast the app's 10-minute awaiting window.
  - Automations still run on OpenClaw, and Hermes doesn't see what they post.
  - Both backends share one ChatGPT quota, so heavy Hermes use can rate-limit OpenClaw turns too.
- The owner decides go, extend or no-go from the report. The test ends at that decision or on 2026-12-31, whichever is first. On no-go, or with no decision by 2026-12-31, Coder removes the flag and its code (Rollback); on extend, the code stays until the new date.

## User stories

1. As the owner, I want to opt a conversation into Hermes by sending `/backend hermes`, so that I can try Hermes on real work without re-pairing.
2. As the owner, I want every other conversation to keep running on OpenClaw as before, so that the test doesn't change them.
3. As the owner, I want an opted-in conversation to show ✓✓, typing, live tool rows, Live Activity steps and the reply, and to keep its history on every device, so that I can chat in it as in any other conversation (with the differences listed in Solution).
4. As the owner, I want a turn that found Hermes unreachable or rate-limited before any tool ran to recover by itself within a few minutes, as OpenClaw turns do, and to end with one clear error after that, so that I never wait forever.
5. As the owner, I want a Hermes run that failed for a permanent reason (no model provider, a refused API key) to show its error once and never be retried, so that I learn about it at once.
6. As the owner, I want the plugin to resubmit a message to Hermes only under the request key Hermes already holds, unless Hermes itself failed that run for a temporary reason before any tool ran, so that a retry doesn't knowingly repeat a tool.
7. As the owner, I want a step that needs an approval to be denied with a plain line in the reply while the rest of the answer arrives, so that one gated tool doesn't lose the whole answer.
8. As the owner, I want `/new` and `/reset` in an opted-in conversation to tell me to start a new conversation, so that the Hermes and OpenClaw sessions can't drift apart. *Pending the owner's answer at operator step 7.*
9. As the owner, I want a Hermes turn that an OpenClaw Gateway restart cut off to end as a cut-off OpenClaw turn does under sync 01 (nothing rerun or resent by itself, the app's awaiting window ends it, counted in the restart ledger line), so that a restart never makes Hermes repeat work it may still be doing.
10. As the owner, I want a `channels.yorozu` config change (a plugin reload) not to lose a Hermes reply on its way.
11. As the owner, I want returning every conversation to OpenClaw to take one config change, and a Hermes message parked at that moment to end with one error rather than run on OpenClaw, so that rollback never runs a message twice.

## Implementation decisions

### Context

The owner's devices (the iPhone, iPad and Mac apps) talk end to end encrypted, through the relay (`apps/relay`) or the plugin's direct listener, to the plugin `plugins/openclaw-yorozu`, which runs inside the OpenClaw Gateway on the owner's Mac mini. In the plugin, the **Hub** (`src/hub.ts`) holds one encrypted session per connected device, acknowledges each message with `delivered` (✓✓) and hands it to the conversation module (`src/conversation.ts`), which runs the turn on OpenClaw. Each Yorozu conversation is one OpenClaw session (the conversation id is its thread id). Hermes Agent is a separate agent runtime with its own HTTP API. This test makes the plugin hand an opted-in conversation's turns to it instead.

**Owner rules** (quoted from `OWNER_DECISIONS.md` at `8a278a5c`):
- "Yorozu runs nothing of its own: no routing, classification, workers, coding agents, memory, jobs, Hermes or cua."
- The exception under that rule: "the Hermes backend test may run Hermes Agent as a second backend inside the plugin, behind `channels.yorozu.backends.hermes` (off by default) and opted into per conversation. OpenClaw stays the default throughout."
- "No Mac host process. The OpenClaw channel plugin … holds the host keys and the relay connection itself."
- "Language: Swift wherever possible …; never Python."

**The Yorozu agent's reading of the exception** (not the owner's words):
- The exception covers the plugin delegating turns to Hermes. *(Follows from its text; not asked.)*
- Yorozu still has no host process: the plugin keeps the host keys and the relay. *(Not asked.)*
- The Hermes gateway is a third-party agent runtime, like OpenClaw, so "never Python" doesn't apply to it. *(Asked at operator step 7, question a.)*
- `/new` and `/reset` in an opted-in conversation answer with a notice instead of resetting the session in place, departing from `OWNER_DECISIONS.md:25` for the test only. *(Asked at operator step 7, question b.)*

### Referenced decisions

These are final. This spec builds on them and doesn't reopen them.

| Label | Who and when | What it says |
|---|---|---|
| Owner-rule exception | The owner, 2026-11-19 09:18 JST; `OWNER_DECISIONS.md:13`, recorded by #748 (`8a278a5c`) | Quoted above. Test only; ends at the go/no-go or on 2026-12-31. |
| Test approval | The owner, 2026-11-19 08:43 JST | Go with the Yorozu agent's recommendations, and set up the Hermes test install on the mini. |
| D1 | The Yorozu agent, 2026-11-19 | Test-grade code behind the flag. No backend interface. Deleted after the go/no-go unless the outcome is go or extend. |
| D2 | same | The OpenClaw session entry stays the record. Only the agent turn is delegated to Hermes. |
| D3 | same | The request key (`Idempotency-Key`) is `<messageId>:<keyAttempt>`. `keyAttempt` is stored before the POST. It advances only when Hermes itself ended the previous key's run with a temporary failure. Every other rerun replays the same key. |
| D4 | same | A denied approval ends only that tool step, with a plain message. The run continues. |
| D5 | same | Measure from the plugin logs and the 20-task batch, with the owner's blind A/B/tie pick per task. |
| Sync decision 5 | The owner, sync source spec §9 | No automatic rerun after an OpenClaw Gateway restart; the auto-retry rule is unchanged. |
| A-4 | The Yorozu agent, 2026-11-19 ~13:30 JST (sync spec) | An entry is marked handed with an awaited write immediately before the dispatch call, for every backend. |
| A-6 | same | Sync tickets 02–04 wait for two weeks of sync 01's logs and a new spec. |
| A-9 | same | A message never handed goes back into the retry store when the OpenClaw Gateway is back; deferred to the later spec, not in sync 01. |
| A-12 | same (sync spec, "Store timing") | The store runs in OpenClaw's state worker, so `handing` resolves after at most 2 s. |
| Stack order | The Yorozu agent, 2026-11-19 13:30 JST | H1 is a draft PR stacked on `feat/sync-ledger`, H2 on H1, H3 on H2. Merged forward only, never rebased. No dependency on sync 02–04. |
| Auto-retry rule | The owner, `OWNER_DECISIONS.md:92` | A run that fails for a temporary reason before any reply or tool call is rerun automatically on the 5/15/30/60/120 s schedule, about four minutes in all. |

### Glossary

| Term | Meaning |
|---|---|
| OpenClaw Gateway | OpenClaw's server process on the Mac mini. The plugin runs inside it. |
| Hermes, Hermes gateway | Hermes Agent, the backend under test; its server process (v0.23.1, API on `127.0.0.1:8652`, home `~/.hermes-yorozu-test`). |
| Config entry, flag | `channels.yorozu.backends` and its `hermes.enabled`. **Backend on/off** is the result of resolving the flag and the key file at `startAccount`. |
| API key, key file | Hermes's `API_SERVER_KEY`; the file `~/.hermes-yorozu-test/yorozu-plugin.key` holding it, written at operator step 14. |
| Request key, key store | The `Idempotency-Key` (D3); keyed-store namespace `hermes-keys`, holding `keyAttempt` per message id. |
| Route store | Keyed-store namespace `backends`: one entry per opted-in conversation, holding its unsettled run ids. |
| Plugin reload | `startAccount` runs again in the same OpenClaw Gateway process after a `channels.yorozu` change. The module stays loaded. |
| Restart | The OpenClaw Gateway process stops and starts. |
| Opted-in conversation | A conversation with a route-store entry. |
| Delegated turn | One message of an opted-in conversation, handled by `hermesTurn`. |
| `retryAttempt` | The index into `retry.ts`'s 5/15/30/60/120 s schedule, carried by `park` and `runParked`. Starts at 0. |
| `keyAttempt` | D3's counter, the suffix of the request key. Starts at 0. |
| Unsettled run | A Hermes run this plugin created and hasn't seen end. Kept in the route-store entry. |
| Replay | `POST /v1/runs` with a request key Hermes already holds: it returns the existing `run_id` with `replayed: true`. |
| Awaiting window | The app's 10-minute window for a sent message (sync spec, S2): a turn with no reply or error ends in the app when it runs out. |
| Turn step N; operator step N | A step of "A delegated turn" (1–8); a step of "Operator steps" (1–14). |
| Before-code question N | A question in H3's table that Coder answers from the OpenClaw source before writing H3's code. |
| A-n | A decision label from the sync spec's EGM rounds (its "Referenced decisions"). |
| Cards, Automations | Yorozu's rich reply blocks (`presentation.ts`) and its scheduled jobs (OpenClaw cron). |
| Codex | ChatGPT's Codex sign-in, the model provider both backends use. |
| Standalone list | `tsconfig.standalone.json`: the plugin files CI typechecks without OpenClaw installed. |
| Help bundle | `apps/mcp/src/content.json`, generated from the top-level `docs/*.md` by `apps/mcp/scripts/generate.ts`. |
| Release Mac, Deploy website | `.github/workflows/release-mac.yml` (a push to `main` touching `plugins/**` publishes a public Mac beta) and `deploy-web.yml` (a push touching `apps/web/**`, `apps/mcp/src/**` or `apps/mcp/package.json` deploys the website). |
| Option B, ADR-H4 | Option B is the chosen design: a branch inside the plugin. ADR-H4 (deferred) is OpenClaw retirement, only after a go. |
| Red test, guard, new check | A red test fails on the parent commit and passes after the change. A guard is an existing test that must stay green unmodified. A new check is a new test that also passes on the parent. |
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
                    │  externalTurn (conversation.ts): run_started, typing, tool rows, Live Activity, ledger calls
                    │  park / runParked (retry.ts): the auto-retry schedule
                    ▼
       sendDurableMessageBatch(mirror) ─▶ outbound adapter ─▶ reply event; transcript mirror; push
```

Data kept: the route and key stores; the existing `retry` store (parked messages of both backends); sync 01's `runs` store, unchanged; the mirrored user messages and replies in the OpenClaw transcript.

### Hermes API facts

Recorded by `probe.sh` from the running test install with no model provider signed in, 2026-11-19. Fixtures: `transfers/20261119-yorozu-hermes-h0-fixtures/NN-name.{headers,body,sse}`, listed in `index.txt`.

| # | Fact |
|---|---|
| 01 | Without the API key, `GET /v1/capabilities` answers 401 `gateway_auth_failed`. |
| 04 | Capabilities include `runs_idempotency` (`durable: true`, `retention_seconds: 86400`), `run_status`, `run_events_sse`, `run_stop`, `run_approval_response`, `tool_progress_events`, `approval_events` and `run_unknown_resolution`. |
| 06 | Vision is `configured: false`. |
| 08 | `POST /v1/runs` with a client-chosen `session_id` answers 202 `{"run_id","status":"started","replayed":false}`. |
| 09 | The event stream sends `: open`, then `id: 0` / `data: {"event":"run.failed","run_id","timestamp","error","completed","partial","interrupted","seq"}`, then `: stream closed`. |
| 10 | `GET /v1/runs/{id}` answers `{"object":"hermes.run","status","session_id","output","usage","admission_id","execution_generation","pending_controls",…}`, with no `error` field. For a failed run, `output` is the error text. |
| 11 | The same request key and body after the run failed answers 202 with the same `run_id`, `"status":"failed"`, `"replayed":true`. |
| 12 | The same request key with a different body answers 409 `idempotency_key_conflict`. |
| 13 | A new request key starts a new run. |
| 14 | `GET /api/sessions/yorozu-<convId>` finds the session the run created. |
| 16, 17 | An unknown run (`run_not_found`) or session answers 404. |

From the v0.23.1 docs (`website/docs/user-guide/features/api-server.md` in the test clone):
- **Replay** (lines 489–495). An identical keyed retry returns the original `run_id`, "including after a gateway restart and after the run has completed, failed, or been cancelled". A run the gateway couldn't admit "keeps no reservation, so an exact retry is safe". Keys are kept for 24 h after the run's last update. The docs don't promise exactly-once (lines 646–647).
- **Durable runs** (lines 533, 600–624). A clean shutdown ends a running run as `interrupted`. A run whose gateway died mid-turn reports `unknown`, which isn't terminal: later runs in that session wait until `POST /v1/runs/{id}/resolve-unknown` gets exactly `{admission_id, execution_generation}`.
- **Approvals** (lines 659–677). An answer is `{"request_id", "execution_generation", "choice"}` from the run's `pending_controls`. `"deny"` appears only in the MCP passage, so it is inferred until operator step 9 records it.
- **SSE buffer.** A finished run's event buffer is dropped 300 s after its last subscriber (`docs/history/hermes-integration.md:134`).

Pending the owner's Codex sign-in (operator steps 8–11): a completed run with tools and `usage`; what `run.failed`'s `partial` means; `approval.request`; whether `stop` ends a run waiting on an approval; `run.interrupted` and `unknown`; two runs at once on one session. "Recordings feed back" says what each result changes.

### Sync 01 calls

The only place this spec states them. Checked against sync 01's code at PR #751 (`src/ledger.ts`, `src/runs.ts`, and its `channel.ts`, `conversation.ts` and `hub.ts` wiring). The H tickets add no ledger method, state, store or start-up step, and don't touch `ledger.ts`, `runs.ts` or `hub.ts`.

| Call | Where the H tickets use it | Behaviour they rely on |
|---|---|---|
| `currentLedger(): Ledger \| undefined` (`runs.ts`) | `externalTurn` reads it once at creation, as `handleMessage` does; the notice path reads it directly | Every call below is skipped when it is undefined. |
| `claim(message): "fresh" \| "duplicate"` | The Hub, before `delivered`; unchanged | A duplicate gets only `delivered` and never reaches `routeMessage`. Parked reruns (`runParked`) don't pass through it. |
| `handing(messageId, convId): Promise<void>` | `t.handing()`, awaited immediately before every `createRun` (A-4) | Writes `handed` under the current boot id. Resolves when the write lands, after a failed write (logged `yorozu: run ledger write failed: <error>`), or after 2 s (logged `yorozu: run ledger write slow <messageId> handed`, A-12). Never rejects; the POST always goes. |
| `runStarted(messageId, retryAttempt, false)` | `t.started()` | Logs `yorozu: run started <messageId> attempt <n> boot <bootId>`; writes `started` only from `handed`. `afterReturn` is always `false`: Hermes has no follow-up queue. |
| `turnEnded(messageId, convId, {parked, queued: false})` | `t.parked()` with `parked: true`; `t.done()` and `t.fail()` with `parked: false`; a notice calls `currentLedger()?.turnEnded(messageId, convId, {parked: false, queued: false})` directly, with no other turn event | `parked` or `settled`. With `queued` always `false`, a Hermes entry never stays `handed` after its turn ends. |

Not used: `dispatchReturned` (it measures OpenClaw's follow-up queue, A-6), `findUserMessage`, and `load`, `counts` and `idle` (start-up and tests). The start-up line `yorozu: restart ledger <bootId>: not handed <n>, handed not started <n>, started <n>, parked <n>` counts Hermes entries exactly as OpenClaw ones.

### Config and key file (H1)

**Schema.** H1 adds `backends` inside `channelConfigs.yorozu.schema.properties` in `plugins/openclaw-yorozu/openclaw.plugin.json`, next to `direct`:

```json
"backends": {
  "type": "object", "additionalProperties": false,
  "description": "Test only (Hermes backend test; ends at its go/no-go or on 2026-12-31).",
  "properties": {
    "hermes": {
      "type": "object", "additionalProperties": false,
      "properties": { "enabled": { "type": "boolean", "default": false } }
    }
  }
}
```

The URL (`http://127.0.0.1:8652`) and the key file path (`~/.hermes-yorozu-test/yorozu-plugin.key`, from `os.homedir()`) are fixed: the test has one install.

**Help bundle.** `generate.ts --check` (`hostSettings`) fails for any schema key missing from the Config table in `docs/setup.md`, and documenting the key there would start Deploy website. So H1 adds `TEST_ONLY_KEYS = new Set(["backends"])` to `apps/mcp/scripts/generate.ts`, skipped by `hostSettings`, with a comment naming this spec and the 2026-12-31 expiry. `content.json` stays byte-identical. This design doc is the reference for the test-only code.

**Resolution.** `resolveHermesBackend(cfg, log, keyFile = KEY_FILE)` in `src/backends.ts` is synchronous and runs once per `startAccount`. The checks run in this order; the first that matches wins:

| Check | Result | Log |
|---|---|---|
| `backends` or `backends.hermes` absent | off | none |
| `enabled` isn't `true` | off | `info` `yorozu: hermes backend off: disabled` |
| `fs.statSync` (follows symlinks) throws | off | `warn` `… off: key file unreadable (<error.code>)` |
| not a regular file (a directory, a pipe) | off | `warn` `… off: key file is not a regular file` |
| `(mode & 0o077) !== 0` | off | `warn` `… off: key file is readable by others` |
| `fs.readFileSync` throws | off | `warn` `… off: key file unreadable (<error.code>)` |
| empty after trimming and removing one pair of surrounding `"` or `'` | off | `warn` `… off: key file is empty` |
| otherwise | on: `{url: new URL("http://127.0.0.1:8652"), key}` | `info` `yorozu: hermes backend on` |

The API key is never logged and never put in a URL or an error message.

**Wiring in H1.** `startAccount` calls `resolveHermesBackend(ctx.cfg, ctx.log)` as a statement, for its log line only. Nothing else changes until H3.

### Client (H2)

`src/hermes-client.ts` imports Node built-ins only (it uses the global `fetch`) and joins the standalone list. Everything that touches OpenClaw lives in `backends.ts` and `hermes-turn.ts`.

- **Requests.** Every request sends `Authorization: Bearer <API key>` and uses `redirect: "manual"`: a 3xx is an `http` error and is never followed, so the API key can't reach another host.
- **Timeouts.** `createRun`, `status`, `deny`, `resolveUnknown` and `stop` each time out after `timeoutMs` (30 s). `events` takes the caller's `AbortSignal` and times out on connect (`timeoutMs`) and on idle (`idleMs`, 60 s with no bytes; comments count). Every timeout is a `setTimeout` that aborts an `AbortController` (not `AbortSignal.timeout`), so `node:test` mock timers drive them.
- **No retries inside the client.** Every retry is a park.

| Input | `HermesError.kind` |
|---|---|
| `fetch` rejects (refused, reset, socket), or a timeout fires | `unavailable` |
| 429; any 503 | `unavailable` |
| 401, 403 | `auth` |
| 404 | `not_found` |
| 409 with `error.code` `idempotency_key_conflict` | `conflict` |
| any other non-2xx (3xx, 400, other 409, other 5xx) | `http`, with `status` and `error.code` |
| a 2xx whose JSON lacks a required field below | `http`, `code: "bad_response"` |

`unavailable` covers both "never admitted" and "maybe admitted" (a timeout after the request was sent). Replaying the same request key is the documented way to handle both; replay after a Hermes restart is documented but unrecorded.

**JSON mapping.** Field names marked † are confirmed or renamed by the operator step 8–9 recordings ("Recordings feed back").

| Method | JSON | Field | Required |
|---|---|---|---|
| `createRun` | `run_id`, `status` (strings); `replayed` (boolean) | `runId`, `status`, `replayed` | `run_id`, `status`; `replayed` defaults to `false` |
| `status` | `status` (string) | `status` | yes |
| | `admission_id` (string), `execution_generation` (number) | `admissionId`, `generation` | no |
| | `output` (string) | `output` | no |
| | `usage.input_tokens`†, `usage.output_tokens`† (numbers) | `usage.inputTokens`, `usage.outputTokens` | no |
| | `pending_controls[]`: `request_id`†, `kind`†, `tool` | `pendingControls[]`: `id`, `kind`, `tool` | no; absent is `[]`; an item without `request_id` or `kind` is dropped |
| `events` | each `data:` object: `event` (string), `seq` (number) | `{event, seq, data}`, `data` the whole object | `event`; an object without it is skipped |

- **Event stream.** `events` parses SSE: `:` lines are comments; `id:` is ignored; consecutive `data:` lines are joined with `\n` and parsed as JSON. A `data` that isn't a JSON object is skipped. The iterator ends after a terminal event (`run.completed`, `run.failed`, `run.cancelled`, `run.interrupted`), on `: stream closed`, when the server closes the connection, or after the idle timeout.
- **Fixed bodies.** `deny` sends `{"request_id","execution_generation","choice":"deny"}`; `resolveUnknown` sends `{"admission_id","execution_generation"}`; `stop` sends none.
- **Errors.** A `HermesError` message holds the method, the path, the HTTP status and Hermes's `error.code`, never a header or a request body.

### Routing and commands (H3)

`routeMessage(deps, message)` decides from the text and `routedToHermes(convId)`. `/backend hermes` matches only the whole text, after trimming, collapsing whitespace and lower-casing (`/Backend  Hermes` matches; `/backend`, `/backend off` don't). `/new` and `/reset` match the whole text or its first word (`/new foo` is `/new`).

| Message | Not opted in | Opted in |
|---|---|---|
| `/backend hermes` | Session entry exists: `setRoute`; notice "This conversation now uses Hermes (test). Hermes doesn't see the earlier messages." No entry yet: notice "Send one message first, then /backend hermes." | Notice "This conversation already uses Hermes." |
| any other `/backend …` | `handleMessage`: OpenClaw passes it to its agent as text | `hermesTurn`: Hermes gets it as text |
| `/new`, `/reset` | `handleMessage` | Notice "Start a new conversation for a fresh Hermes session." |
| anything else | `handleMessage` | `hermesTurn` |

- The session entry check is `liveSessionId(agent, sessionKey)` from `history.ts`, with the thread session key from `resolveThreadSessionKeys`. Only `/backend hermes` needs it. A deleted opted-in conversation keeps its route-store entry; it is inert, because no message arrives for it.
- **Order.** `/backend hermes` and every opted-in message run on the conversation's FIFO, so a message sent right after the opt-in queues behind it. Messages for conversations that aren't opted in go straight to `handleMessage`, as today.
- **A notice** goes out through `sendDurableMessageBatch` with the options of `post` in `updates.ts` (`durability: "best_effort"`, `mirror`). When the session entry exists, the user message is mirrored first. With no entry, neither is mirrored: the notice shows on devices but not in history. A status other than `sent` is logged `yorozu: hermes notice not sent: <status>`. The ledger entry then ends through the notice's `turnEnded` call ("Sync 01 calls"): no `run_started`, typing or activity event.
- **Backend off.** Every message goes to `handleMessage` as today. With the backend on, `routeMessage` sees `/backend hermes` before OpenClaw does.
- **Pass-through, verified** (Coder, 2026-11-19, OpenClaw 2026.9.8, backend off; `passthrough-report.md` in Coder's context folder). OpenClaw has no built-in text or native command `backend`, so `/backend hermes` reaches the agent runner verbatim and the device gets only the agent's reply; `/help` on the same path still gets OpenClaw's command reply with no agent run. The check is `test/backend-passthrough.test.ts`, which Coder wrote then on `conversation-owner-fixture.ts` and keeps uncommitted; H3 commits it. **Caveat:** it uses isolated state and a fresh workspace; a skill or plugin that claims `/backend` would change the result.

**`/backend` claim check (H3, test only).** The Yorozu agent asked for a loud check that nothing claims `/backend`. It is a test and nothing more: no plugin code calls the SDK for it, so it can never affect plugin load. Three things in OpenClaw can take `/backend` before the agent sees it (`~/openclaw`, 2026.9.8, read only): a built-in command or text alias (`src/auto-reply/commands-registry-normalize.ts:137`, `:158`); a plugin command (`matchPluginCommandInvocation`, `src/auto-reply/reply/dispatch-from-config.plugin-binding.ts:67`, over commands added with `api.registerCommand`); a skill command (`src/auto-reply/reply/get-reply-inline-actions.ts:276-303`, matched by name in `src/skills/discovery/chat-command-invocation.ts:111-131`). Their public SDK exports: `listChatCommands({skillCommands})` (`openclaw/plugin-sdk/command-auth-native`; `src/auto-reply/commands-registry-list.ts:7` adds each skill with `nativeName` and the alias `/<name>`), `listSkillCommandsForAgents({cfg})` (`openclaw/plugin-sdk/skill-commands-runtime`) and `matchPluginCommand(body)` (`openclaw/plugin-sdk/plugin-runtime`, deprecated barrel; `src/plugins/commands.ts:21`).

`test/backend-claim.test.ts` holds everything:
- **`backendClaims({commands, plugin})`**, a pure function in the test file: takes the `listChatCommands` result (`{key, nativeName?, textAliases}[]`) and the `matchPluginCommand("/backend hermes")` result, and returns one label per claimant: the command's `key` (a skill's is already `skill:<name>`) or `plugin:<pluginId>/<name>`. A command claims `/backend` when its lower-cased `nativeName` is `backend` or a text alias is `/backend` (case-insensitive).
- **Not gated (CI):** fake lists: none → `[]`; a built-in alias `/backend`; a `nativeName` `Backend`; a skill named `backend`; a plugin match; `/backends` and a skill named `backend-x` don't claim.
- **Gated on `YOROZU_OPENCLAW_SDK`** exactly as `backend-passthrough.test.ts` (skipped in CI): imports the three exports dynamically, so a renamed export fails the test; with isolated state, `backendClaims` over the real lists is `[]`; with one plugin command `backend` registered through `registerPluginCommand` (same barrel; `src/plugins/command-registration.ts:296`) and removed with `clearPluginCommands` after, it names that command. Both need an active plugin registry (`src/plugins/commands.ts:25`); if the isolated run has none, the test sets one up as OpenClaw's own loader tests do. When `YOROZU_OPENCLAW_CONFIG` names a config file, the test also lists that config's skill commands with `listSkillCommandsForAgents({cfg})` and asserts none claims `/backend`. The Yorozu agent runs it so before operator step 14.

### A delegated turn (H3)

`hermesTurn(deps, message, retryAttempt = 0)` runs on the conversation's FIFO. Each entry point (`routeMessage`, `routedRerun`, `hermesTurn`) catches every unexpected throw: it ends the message with `t.fail("The Hermes test turn failed.")` (creating `t` first if needed), logs `yorozu: hermes turn failed: <errorTag>`, and writes the usage line. None of them ever rejects.

1. **Claimed.** The Hub's `claim` returned `"fresh"` and `delivered` went out.
2. **Live turn.** `t = externalTurn(deps.turn, message, retryAttempt)`.
3. **End earlier runs.** Turns of one conversation run one at a time, so every id in the route entry's `unsettled` belongs to a turn that has ended; its output is never delivered. For each: `status(id)`. If `unknown`: `resolveUnknown`, then `status` again. If still not terminal (running, waiting on an approval, `unknown`): `stop(id)`, then `status` again. Remove the id when it is terminal or `not_found`; otherwise keep it and log `yorozu: hermes earlier run not ended <id> <status>`. A throw keeps the id, is logged, and the turn goes on.
4. **Request key.** Read the key store. With no entry, write `{keyAttempt: 0}` and await it; if that fails, `t.fail("The Hermes request key couldn't be stored.")`. Then, only for a new entry, mirror the user message (Mirror). Key first, then mirror, so a crash between them loses a history line and never mirrors twice. A failed mirror is logged and the turn goes on; the history line is lost (accepted).
5. **Body.** `requestBody(message)` uses only the stored `Message` and fixed strings, so every attempt with one request key is byte-identical (a different body gets 409). `input` joins, with blank lines: a quote line `> <replyTo.text, whitespace collapsed, at most 500 characters>` (or `> (an earlier message)` with no text) when the message quotes one; the text; `[n attachment(s) not sent to the Hermes test]` when it has attachments. The body is `{input, session_id: "yorozu-<convId>", instructions: INSTRUCTIONS}`, where `INSTRUCTIONS` is exactly: `You are answering in Yorozu, a chat app on the owner's iPhone, iPad and Mac. Write plain Markdown; tables are fine. Your reply text is the message: don't use a message tool and don't use a card format.` The persona comes from the operator step 12 import.
6. **Hand, then create.** `await t.handing()`, then `createRun({key: "<messageId>:<keyAttempt>", body})`. Every attempt, a parked rerun included, passes `handing`. Each result logs `yorozu: hermes createRun <messageId>:<keyAttempt> run=<runId|-> replayed=<true|false|-> error=<kind|->`.
   - On success, `addUnsettled(runId)` (a failed write is logged). If `replayed`, read `status(runId)` and act by the status table. Otherwise attach (turn step 7).
   - `unavailable`: retry later with the same request key.
   - `auth`: `t.fail("The Hermes test backend refused the API key.")`.
   - `conflict`, `not_found`, `http`: `t.fail("Hermes answered <status> <code>.")` and a warning log.
   - A replayed run whose `status` throws: `unavailable` retries later with the same request key; other kinds fail as above.
7. **Attach.** `t.started()`, then read `events(runId)` and handle each event (Turn outcomes). The turn is capped at 30 minutes from `t.started()`: at the cap, `stop(runId)` (best effort; the id stays unsettled) and `t.fail("The Hermes run took over 30 minutes.")`.

   **Lost stream.** When the stream ends without a terminal event, or `events` throws, the turn polls `status(runId)` every 5 s and acts by the status table, until a row ends the turn or the cap fires. A polled status with pending controls of the approval kind is handled as an `approval.request` event. If `status` throws: `t.fail("Lost contact with the Hermes run.")`, with the id kept unsettled, so the next turn's turn step 3 ends it. After a lost stream the turn sees statuses only, so tool rows and Live Activity steps stop updating (typing goes on), and a temporary failure fails the turn instead of advancing the request key: events may have been missed, so the tool signal is unreliable.
8. **Deliver.** An empty `output` is `t.fail("Hermes finished with an empty reply.")`. Otherwise send `output`, then one line per denied approval, with `sendDurableMessageBatch` and the options of `post` in `updates.ts`. A status other than `sent` is `t.fail("The Hermes reply couldn't be sent: <status>.")`. Then the push (before-code question 3), then `t.done()`. No `maybeTitle` or `noteFirstMessage`: the conversation's first message was an OpenClaw turn, which set the title.

**Error text.** `<text>` is a `run.failed` event's `error` when it is a string, else its `message` field when that is a string, else its JSON; for a status, it is the failed run's `output`. `isTemporary` is `retry.ts`'s test (overloaded, rate limit, 429/503/529, "temporarily unavailable", `ECONNRESET`, `ETIMEDOUT`). Fixture 09's "not connected to any AI provider" isn't temporary, so it is reported at once.

**Status table.** The one mapping from a run's status to an action, used for a replayed run (turn step 6), for polling after a lost stream (turn step 7) and for terminal events (`run.<status>`). Every terminal row removes the id from `unsettled` first.

| Status | Action |
|---|---|
| `completed` | Deliver the event's `output`, or the status's `output` if the event has none (turn step 8). |
| `failed`, from a `run.failed` event on this turn's own unbroken stream, with no tool seen and `isTemporary(<text>)` | Write `{keyAttempt: keyAttempt + 1}` (awaited; if it fails, `t.fail("Hermes: <text>")`), then retry later. |
| `failed`, any other way (a replayed run, a polled status, a tool seen, a permanent error) | `t.fail("Hermes: <text, cut to 500 characters>")`. |
| `interrupted` | `t.fail("Hermes interrupted this run.")` |
| `cancelled` | `t.fail("Hermes cancelled this run.")` |
| `unknown` | `resolveUnknown`, then `status` once, then this table once more. Still `unknown`, or a throw: `t.fail("The Hermes run couldn't be resolved.")`, id kept unsettled. |
| any other (`started`, `running`, `queued`, …) | Attach (turn step 7), or keep polling after a lost stream. |

A replayed `failed` run is never retried: the turn can't tell whether a tool ran in it. An `interrupted` run isn't retried either: D3 advances the request key only after a temporary *failure*.

**Retry later** (the only retry path): `deps.park(message, retryAttempt)` (`retry.ts`, the same 5/15/30/60/120 s schedule as OpenClaw turns; a rejection counts as `false`). On `true`, `t.parked()` and log `yorozu: hermes run parked (retry <retryAttempt + 1> queued): <reason>`. On `false` (the schedule is used up after 5 retries): `t.fail` with "The Hermes test backend isn't answering." or "Hermes: <text>". A Hermes gateway that refuses connections therefore gets 6 POSTs in about 4 minutes, then one error; one that accepts connections and hangs takes up to about 7 minutes (six 30 s timeouts). A parked message reruns after any later message of its conversation; accepted, as for OpenClaw turns.

**Mirror.** `appendSessionTranscriptMessageByIdentity` (before-code question 1) appends one user message: `message.text` only (no quote line, no attachment note), with `__openclaw.transport.messageId = messageId`, `provenance.kind: "external_user"`, and the host receipt time. Quotes and attachments aren't in history for these messages; accepted.

### Turn outcomes (H3)

| Event | Action |
|---|---|
| `tool.started` | `t.tool(callId, name, "running")`. `callId` is `hermes:<runId>:<id>`, where `<id>` is the event's tool call id† if it has one, else its `seq`. |
| `tool.completed` | `t.tool(callId, name, ok ? "done" : "failed")` (the success field†). Without a tool call id, it matches the oldest open `tool.started` with the same name, else the oldest open one. |
| `approval.request` | `status(runId)`, then `deny` for each pending control of the approval kind†. Each adds "Denied: <tool> needed an approval Yorozu can't show yet." to the reply, `<tool>` from the control's `tool` field, else "a tool". With none pending, or if a `deny` throws: `stop(runId)` (best effort) and `t.fail("Hermes asked for an approval that could not be answered.")`. |
| `run.completed`, `run.failed`, `run.interrupted`, `run.cancelled` | The status table. |
| anything else | Ignored. Each unknown kind is logged once per process. |

† Named by the operator step 8–9 recordings.

### `externalTurn` (H3)

`externalTurn(ctx, message, attempt)` (`attempt` is `retryAttempt`) sits beside `handleMessage` in `conversation.ts` and reuses its module-private `registerTurn` and `removeTurn`. Its operations are idempotent, and the first end wins:

| Operation | What it does |
|---|---|
| (creation) | `registerTurn(message)` (a parked rerun reuses the live turn); reads `currentLedger()` once |
| `handing()` | the ledger's `handing` ("Sync 01 calls") |
| `started()` | the Hermes run is attached (for OpenClaw the same event marks the agent run's start): `run_started` once; typing on, repeated every 8 s by its own `setInterval`, capped at 30 min; the ledger's `runStarted` |
| `tool(callId, name, status)` | the `tool` event; on a new `callId`, `owner.steps` and `activityTurn {kind: "step"}` |
| `fail(text)` | `error {code: "run_failed", message: text}`; then as `done()` but with `activityTurn {kind: "failed"}` |
| `parked()` | typing off; live turn and Live Activity job kept; the ledger's `turnEnded` with `parked: true` |
| `done()` | typing off; live turn removed; `activityTurn {kind: "done"}`; the ledger's `turnEnded` with `parked: false` |
| `toolSeen` | true once `tool()` has run |

- It copies the about 25 lines of `run_started`, typing and tool handling from `handleMessage` instead of extracting them. `handleMessage` isn't changed (D1); `genui-golden` and `prerun-error` guard that.
- It doesn't touch `runningTurns`, a card-filing marker: Hermes sends no cards.
- A device that opens a session mid-turn learns of a Hermes turn from the next typing keepalive (up to 8 s), as for OpenClaw turns while sync 03 is deferred.

### Restarts, reloads and turning the backend off

| Event | What happens |
|---|---|
| Plugin reload, backend still on | Nothing is aborted. An in-flight Hermes turn keeps its deps and finishes. `broadcast`, `activityTurn` and `notifyReply` already forward to the current relay host. The Hermes state (route map, FIFO) is the module's one instance and survives. |
| Plugin reload, backend now off (the flag, or a key file that became unreadable), or the route store failed to load | New messages go to OpenClaw. A parked message with a key-store entry is never rerun: it ends with one `run_failed` "The Hermes test backend is off; this message wasn't rerun." Hermes may already have admitted it, so it never falls back to OpenClaw. |
| Restart, turn parked | The retry store holds it; its entry is `parked`. `runParked` reruns it through `routedRerun`, which finds its key-store entry and calls `hermesTurn` with the stored `retryAttempt` and the same request key (replay). |
| Restart before `handing` (turn steps 1–5) | Hermes never got the POST. The entry stays `accepted`, counted `not handed`. No device event, no rerun; the awaiting window ends the turn. A device resend of the same id is a duplicate. |
| Restart after `handing` | No requeue (sync decision 5), no device event: the entry stays `handed` or `started`; the awaiting window ends the turn. The Hermes run is orphaned; the next turn in that conversation stops it (turn step 3). |
| Hermes clean stop mid-run | `run.interrupted` (pending operator step 11): `run_failed`. |
| Hermes `kill -9` mid-run | Lost stream; `status` throws while Hermes is down: "Lost contact…", the id stays unsettled. The next turn resolves or stops it in turn step 3 once Hermes is back, also across a restart, because the id is in the route store. |
| OpenClaw Gateway and Hermes at once | Not tested on its own (Further notes). |

### Wiring (H3)

`Log` is `ChannelGatewayContext["log"]`. `YorozuConfig` (`channel.ts:49`) gains `backends?: { hermes?: { enabled?: boolean } }` in H1. Log lines use `errorTag` from `cards.ts`. `channel.ts` adds `park` to its `retry.js` import. `startAccount` builds the Hermes pieces after `openLedger` (sync 01) and before the relay host and `runParked` start:

```ts
const hermes = resolveHermesBackend(ctx.cfg, ctx.log);
const keys = cfg.backends?.hermes ? hermesKeys() : undefined;   // also with the backend off, so parked Hermes messages fail closed
const state = hermes && (await openHermesState(ctx.log));       // undefined, logged at warn, if the route store fails to load
const deps = hermes && keys && state && { client: hermesClients.create(hermes), state, keys, turn, park, log: ctx.log };
// onMessage: (message) => void (deps ? routeMessage(deps, message) : handleMessage(turn, message)),
runParked(abortSignal, (message, attempt) =>
  void (keys ? routedRerun({ keys, turn, deps, log: ctx.log }, message, attempt) : handleMessage(turn, message, attempt)));
// routedRerun: keys.lookup(messageId) has no entry → handleMessage(turn, …), as today.
//   An entry, with deps → on the FIFO, hermesTurn(deps, message, attempt).
//   An entry without deps, or a lookup that rejects → externalTurn(turn, message, attempt).fail(…) once; never handleMessage.
```

With `channels.yorozu.backends` absent, `keys` and `deps` are undefined, and `onMessage` and `runParked` are exactly as at the parent commit.

### Module signatures (sketch: names may change, shapes may not)

```ts
// src/hermes-client.ts (H2; Node built-ins only; in the standalone list)
export type HermesErrorKind = "unavailable" | "auth" | "not_found" | "conflict" | "http";
export class HermesError extends Error {
  readonly kind: HermesErrorKind; readonly status?: number; readonly code?: string;
  constructor(kind: HermesErrorKind, message: string, status?: number, code?: string);
}
export type RunStatus = {
  status: string;                      // "started" | "running" | "completed" | "failed" | "cancelled" | "interrupted" | "unknown" | …
  admissionId?: string; generation?: number;
  output?: string;                     // a failed run's output is its error text
  usage?: { inputTokens?: number; outputTokens?: number };
  pendingControls: { id: string; kind: string; tool?: string }[];
};
export type RunEvent = { event: string; seq?: number; data: Record<string, unknown> };
export interface HermesClient {
  createRun(req: { key: string; body: string }): Promise<{ runId: string; status: string; replayed: boolean }>;
  status(runId: string): Promise<RunStatus>;
  events(runId: string, signal?: AbortSignal): AsyncIterable<RunEvent>;
  deny(runId: string, requestId: string, generation: number): Promise<void>;
  resolveUnknown(runId: string, admissionId: string, generation: number): Promise<void>;
  stop(runId: string): Promise<void>;
}
export function createHermesClient(opts: { url: URL; key: string; timeoutMs?: number; idleMs?: number }): HermesClient;

// src/backends.ts (H1: the first three lines; H3: the rest)
export type HermesBackend = { url: URL; key: string };
export const KEY_FILE: string;                                      // ~/.hermes-yorozu-test/yorozu-plugin.key
export function resolveHermesBackend(cfg: OpenClawConfig, log?: Log, keyFile?: string): HermesBackend | undefined;
export type KeyRecord = { keyAttempt: number };
export function hermesKeys(): Keyed<KeyRecord>;                     // {namespace: "hermes-keys", maxEntries: 10_000, overflowPolicy: "evict-oldest"}
export type HermesState = {
  routedToHermes(convId: string): boolean;                          // sync, from the map
  setRoute(convId: string): Promise<"set" | "already">;             // rejects (map undone) if the store write fails
  unsettled(convId: string): string[];
  addUnsettled(convId: string, runId: string): Promise<void>;       // idempotent
  removeUnsettled(convId: string, runId: string): Promise<void>;
  serial(convId: string, fn: () => Promise<void>): Promise<void>;   // the FIFO; a .catch per link
};
export function createHermesState(open: <T>(opts: { namespace: string; retention: "retained" }) => Store<T>, log?: Log): Promise<HermesState>;
export function openHermesState(log?: Log): Promise<HermesState | undefined>;   // one per module, so a reload reuses it

// src/conversation.ts (H3; additions only)
export type TurnContext = /* the existing type, now exported */;
export type ExternalTurn = {
  handing(): Promise<void>; started(): void;
  tool(callId: string, name: string, status: ToolStatus): void;
  fail(text: string): void; parked(): void; done(): void;
  readonly toolSeen: boolean;
};
export function externalTurn(ctx: TurnContext, message: Message, attempt: number): ExternalTurn;

// src/hermes-turn.ts (H3)
export type HermesDeps = { client: HermesClient; state: HermesState; keys: Keyed<KeyRecord>; turn: TurnContext;
  park: (message: Message, retryAttempt: number) => Promise<boolean>; log?: Log };
export const hermesClients = { create: (backend: HermesBackend) => createHermesClient(backend) };   // only tests replace `create`
export function routeMessage(deps: HermesDeps, message: Message): Promise<void>;
export function routedRerun(r: { keys: Keyed<KeyRecord>; turn: TurnContext; deps?: HermesDeps; log?: Log }, message: Message, retryAttempt: number): Promise<void>;
export function hermesTurn(deps: HermesDeps, message: Message, retryAttempt?: number): Promise<void>;
export function requestBody(message: Message): string;
```

`Keyed` comes from `cards.ts` and `Store` from sync 01's `ledger.ts`. The route store is `{namespace: "backends", retention: "retained"}`, loaded into a map when the instance is created; `setRoute` and the `unsettled` writes go to the map, then the store, awaited; a failed store write undoes the map change and rejects. A failed load makes `openHermesState` log `warn` `yorozu: hermes state unavailable: <errorTag>` and return undefined.

### Tickets, order and gates

| # | PR | Base branch | May start | May merge |
|---|---|---|---|---|
| 0 | `docs: Hermes backend test design` (this file only) | `main` | now | on the owner's approval |
| H0 | Operator steps 7–13 (no PR) | — | now | — |
| H1 | `feat(plugin): accept the Hermes test backend config (dormant)` | `feat/sync-ledger` (sync 01's draft PR #751) | now | into `main`, after sync 01 merges and the stop rule passes |
| H2 | `feat(plugin): Hermes client with fake-server tests (dormant)` | H1's branch, draft | after operator steps 8–11 and 13, if the stop rule passes | into `main`, after H1 merges |
| H3 | `feat(plugin): run an opted-in conversation's turns on Hermes` | H2's branch, draft | after H2 is up, the owner's operator step 7 answers, and the stop rule passes | into `main`, after H2 merges and the before-code answers are in the PR |
| H6 | The test run, the report, and on a no-go the removal PRs | — | after H3 merges and operator step 14 | — |

- **Merged forward only.** History on these branches is never rewritten or rebased. New commits on a base branch are merged into the branch above it (`feat/sync-restart` → `feat/sync-ledger` → H1 → H2 → H3). Each PR merges into `main` with the repository's usual squash merge under its Conventional Commits title; then the next PR's base becomes `main`, and `main` is merged into it.
- **Deadline.** Real use needs at least two weeks before 2026-12-31. If H3 hasn't merged by 2026-12-17, the Yorozu agent tells the owner, who decides whether to extend.
- **Every merge** to `main` needs the owner's approval in the owner's own words.
- **PR bodies.** Each H PR body cites the owner-rule exception (#748, `8a278a5c`, `OWNER_DECISIONS.md:13`), names its release trigger (below) and links this spec.
- **Commits.** Each PR's first commit holds only red tests and the test harness changes they need; the PR body names each red test and its failure on the parent. Conventional Commits, signed.

**Release and deploy** (on push to `main`; merges between stacked branches start nothing). No PR touches `apps/relay`, `apps/ios`, `apps/windows`, `packages`, top-level `docs/*.md` or the plugin README.

| PR | Paths | Release Mac | Deploy website |
|---|---|---|---|
| 0 | `docs/designs/` (`generate.ts` reads only top-level `docs/*.md`) | no | no |
| H1 | `plugins/**`, `apps/mcp/scripts/generate.ts` | yes: a dormant Mac beta | no (`content.json` byte-identical) |
| H2 | `plugins/**`, this file | yes: a dormant Mac beta | no |
| H3 | `plugins/**`, this file if a recording changed it | yes: a Mac beta, dormant until the flag is on | no |

**H1: config (dormant).**

| Action | File | What |
|---|---|---|
| Modify | `plugins/openclaw-yorozu/openclaw.plugin.json` | the `backends` property |
| Create | `plugins/openclaw-yorozu/src/backends.ts` | `KEY_FILE`, `resolveHermesBackend` |
| Modify | `plugins/openclaw-yorozu/src/channel.ts` | `YorozuConfig`; the `resolveHermesBackend` call |
| Modify | `apps/mcp/scripts/generate.ts` | `TEST_ONLY_KEYS`, skipped by `hostSettings` |
| Create | `plugins/openclaw-yorozu/test/backends-config.test.ts` | red tests; a copy of the `channel()` helper from `presentations.test.ts:947` that takes a `cfg` argument |

Red tests (each passes the key file path as `resolveHermesBackend`'s third argument, a temp file):
1. The manifest has `backends.hermes` with `additionalProperties: false` at both levels, and `enabled` defaults to `false`.
2. `backends` absent: `resolveHermesBackend` returns undefined and logs nothing, even with a valid key file; through `startAccount`, a stubbed global `fetch` is never called.
3. `enabled: false`: one `hermes backend off: disabled`.
4. Each refusal with its line: a missing file (`unreadable (ENOENT)`), a directory (`not a regular file`), mode 0644, an empty key, a key of only quotes.
5. Mode 0600 and 0400 are accepted. A quoted key loses its quotes. The URL is `http://127.0.0.1:8652/`.
6. The API key never appears in any log line from tests 3–5.

Guards: `hub-session`, `prerun-error`, `genui-golden`, `presentations`.

**H2: client (dormant).** H2's PR first adds the operator step 8–11 recordings to "Hermes API facts" and applies "Recordings feed back".

| Action | File | What |
|---|---|---|
| Create | `plugins/openclaw-yorozu/src/hermes-client.ts` | the client |
| Modify | `plugins/openclaw-yorozu/tsconfig.standalone.json` | add `src/hermes-client.ts` to `include` |
| Create | `plugins/openclaw-yorozu/test/fixtures/hermes-0.23.1/` | the H0 fixtures the red tests read (01–17 and the operator step 8, 9.3 and 11 recordings), without `probe.sh`, **scrubbed before commit**: home paths become `/Users/owner`, and host names, file listings, command output and model text become placeholders of the same JSON type, keeping every field name and event shape. Operator step 9.2's ten command outputs aren't fixtures. A `README.md` lists each file, its source and date, and what was replaced. |
| Create | `plugins/openclaw-yorozu/test/hermes-server.ts` | a `node:http` fake Hermes on `127.0.0.1:0` that plays an ordered script per test: method, path and `Idempotency-Key` → a fixture or an inline response (429, 503, 307, a hang, a reset socket, a mid-stream close). It records each request's headers and body, and `request(n)` resolves when the n-th arrives. Not a `*.test.ts`. |
| Create | `plugins/openclaw-yorozu/test/hermes-client.test.ts` | red tests, with real timers and `timeoutMs: 50, idleMs: 100` |

Red tests:
1. Each error-kind row, one test each. `unavailable` covers a closed port, 429, 503, a hang past `timeoutMs` and a reset socket.
2. A 307 to another server is `http`, and the other server gets no request.
3. `createRun` sends the `Idempotency-Key` and the body byte for byte. Fixture 11 parses as `{replayed: true, status: "failed"}`; a 2xx without `run_id` is `bad_response`.
4. `status` parses fixture 10 by the mapping table, including `admissionId`, `generation` and empty `pendingControls`. Fixture 16 is `not_found`.
5. `events` on fixture 09 yields one `run.failed` with `seq` 0 and `data.error` as recorded, and ends. It ignores comments, joins multi-line `data`, skips non-JSON `data` and objects without `event`, ends on a server close without `: stream closed`, and ends after `idleMs`.
6. The exact bodies of `deny` and `resolveUnknown`; `stop` has none.
7. For every error kind, neither `String(error)` nor `error.stack` contains the API key.
8. Scrub: no fixture file contains `Authorization`, matches `/Bearer [A-Za-z0-9]/`, or contains a `/Users/` path other than `/Users/owner`.
9. One test per recording: the completed run's status gives `usage` numbers and its events give the tool call id and success field; the approval recording gives `pendingControls` with `id`, `kind` and `tool`; the interrupted stream yields `run.interrupted` and ends; the `unknown` status gives `admissionId` and `generation`, and `resolveUnknown` sends them.

Guards: the standalone typecheck passes with `hermes-client.ts` included.

**H3: delegated turns.**

Before code, Coder answers these by reading `~/openclaw` (2026.9.8, read only) and writes the answers in the PR. If an answer is unclear, Coder stops and reports to the Yorozu agent; a "no" does what its cell says.

| # | Question | If yes | If no |
|---|---|---|---|
| 1 | Is `appendSessionTranscriptMessageByIdentity` (`openclaw/plugin-sdk/session-transcript-runtime`) reachable from a plugin installed with `--link`, the call for a user message with `__openclaw.transport.messageId` and `provenance.kind: "external_user"`, and does it leave an existing session entry unchanged? | use it for the mirror | stop and report |
| 2 | Does an appended user message leave OpenClaw with no pending turn (no run, no restart-recovery marker)? | as designed | stop and report |
| 3 | Does `sendDurableMessageBatch` run the outbound adapter's `afterDeliverPayload`, which sends the push? | no push call in `hermesTurn` | call `notifyReply(convId, results[0]?.messageId, text)` once after a `sent`, as `channel.ts:256` reads the result; with no id, skip the push and log `yorozu: hermes push skipped: no message id` |

| Action | File | What |
|---|---|---|
| Create | `plugins/openclaw-yorozu/src/hermes-turn.ts` | `routeMessage`, `routedRerun`, `hermesTurn`, `requestBody`, `hermesClients` |
| Modify | `plugins/openclaw-yorozu/src/backends.ts` | `hermesKeys`, `createHermesState`, `openHermesState` |
| Modify | `plugins/openclaw-yorozu/src/conversation.ts` | export `TurnContext`; add `externalTurn` |
| Modify | `plugins/openclaw-yorozu/src/channel.ts` | Wiring; `park` added to the `retry.js` import |
| Modify | `plugins/openclaw-yorozu/test/genui-host.js` | Recording stubs: `sendDurableMessageBatch` (records its arguments; returns `{status: host.batchStatus ?? "sent", results: [{messageId}]}`), `appendSessionTranscriptMessageByIdentity` (records; rejects when `host.mirror === "reject"`, never settles when `"hang"`). `runRelayHost` and `runParked` keep their last arguments in `host.relay` and `host.rerun`. If sync 01's harness doesn't already, the fake store keeps every row when `maxEntries` is undefined (today `genui-host.js:25-36` drops them all; the `retry` and `backends` stores need it). |
| Create | `plugins/openclaw-yorozu/test/hermes-turn.test.ts` | red tests |
| Create | `plugins/openclaw-yorozu/test/backend-claim.test.ts` | the `/backend` claim check: new checks, pure part in CI, SDK part gated |
| Create | `plugins/openclaw-yorozu/test/backend-passthrough.test.ts` | the pass-through check (Routing), committed as Coder wrote it; gated, a new check |

**Test seams.**
- **Level.** Turn tests call `routeMessage` and `routedRerun` with injected `HermesDeps`: a real client from `createHermesClient` bound to `hermes-server.ts` on port 0, a `createHermesState` and `hermesKeys` over the fake keyed store, the stand-in `TurnContext`, and the real `park`; reruns go through the real `runParked`. Each turn test calls the test ledger's `claim(message)` before `routeMessage`, as the Hub does. Three wiring tests (2, 3, 21) go through `startAccount`; they share the module's one `openHermesState` instance and run in file order. Test 3 replaces `hermesClients.create` with one that binds the fake server's port.
- **Resolve hook.** As `prerun-error.test.ts` does (it imports `./genui-hooks.ts` at line 4, then registers its own `registerHooks` resolve hook at line 19, so its hook runs first), the test file sends `./retry.js` imported from `src/hermes-turn.ts`, and the test's own import of `src/retry.ts`, to the real file with `shortCircuit`, and `./relay.js` imported from `src/conversation.ts` and `src/hermes-turn.ts` to a recorder module for `activityTurn` and `notifyReply` (`prerun-error.test.ts:14-18`). `retry.ts`'s own `./runtime.js` import still reaches the stub, so `park` writes the fake `retry` store. `channel.ts` keeps the stub `retry`.
- **Time.** `mock.timers.enable({apis: ["setTimeout", "setInterval", "Date"]})`. A test advances time only after awaiting `server.request(n)` for the request it expects, so ticks and socket I/O alternate. The client gets the real 30 s and 60 s defaults.
- **From sync 01**, used unmodified: `createLedger` over fake stores, with `handDeadlineMs` where a test needs it; its fake-store write-failure and slow modes and call-order recorder; the way `conversation-ledger.test.ts` connects `conversation.ts`'s calls to a test ledger. Ledger results are read from the `runs` store rows and the `restart ledger` line.
- **Restart simulation** (sync 01's restart seam, plus Hermes state). The turn before the restart is left hanging (the fake server never answers its open requests; mock time doesn't reach its cap). Then a new `createLedger` over the same fake store rows with a new `bootId` and `load()`; a new `createHermesState` over the same rows; new deps. `conversation.ts`'s module state isn't reset, so restart tests assert only store rows, device events after the restart, and the fake server's requests.
- **What the stubs drive.** The `sendDurableMessageBatch` stub doesn't run the outbound adapter, so tests check its call (text, `mirror`) instead of `reply` events, and count pushes only through `notifyReply` when before-code question 3 is "no".

Red tests:
1. Routing: one test per cell of the routing table, including the no-entry notice (no `setRoute`, no mirror), `/Backend  Hermes` opting in, and `/backend` and `/backend off` passing through to OpenClaw (not opted in) and to Hermes as text (opted in). After every notice the `runs` entry is `settled` and no `run_started`, typing or activity event went out.
2. Backend off (`backends` absent), through `startAccount`: `host.relay`'s `onMessage` and `host.rerun` reach `handleMessage`; the fake server gets no request; neither namespace exists.
3. Backend on, through `startAccount`: an opted-in message reaches the fake server through `hermesClients.create`; a second `startAccount` (reload) sees the same route.
4. A plain turn: `run_started` once; typing on, then off; the batch called once with `output` and `mirror`; the user message mirrored once with the Mirror fields; `activityTurn` `done`; ledger entry `settled`; one `createRun` line and one usage line with `outcome=completed`; one push per before-code question 3.
5. When the fake server receives the POST, the key-store row exists and the `runs` entry is `handed` under the current boot id (the recorder shows the `handing` write settled before the request); then `started`, then `settled`. A parked rerun writes `handed` again before its POST. A failing `handing` write is logged and the POST still goes; a `handing` write that never lands lets the POST go after 2 s with `run ledger write slow`. No `dispatch returned` or `follow-up started after dispatch` line.
6. Bounded retries: the fake server refuses every connection. Exactly 6 POSTs and 6 `createRun … error=unavailable` lines, each after its scheduled delay (5, 15, 30, 60, 120 s, each within one 5 s tick of the previous attempt's end), all with request key `<id>:0` and the same body. Then one `run_failed`, `outcome=unreachable`, `run=-`, and no 7th request after another 10 minutes of mock time.
7. A timeout after admission, then a rerun: the second POST carries the same request key, the server replays, the turn attaches, the server saw one run, and both `createRun` lines that name a run name the same one.
8. Replay by status: `completed` delivers once; `failed` (fixtures 11 and 10) is `run_failed` with no batch call, even for a temporary error; `cancelled` and `interrupted` are `run_failed`; `running` attaches and delivers; `unknown` calls `resolveUnknown` with the exact body, then maps.
9. `run.failed` temporary (`rate limit`) with no tool: request key `:1`, parked, and the rerun answers. The same after a `tool.started`: `run_failed`. Fixture 09's permanent error: `run_failed` at once.
10. `run.interrupted`, with or without a tool: `run_failed`, the request key unchanged.
11. Lost stream: a stream that closes at once makes the turn poll `status` every 5 s; `running` then `completed` delivers once; a polled temporary `failed` is `run_failed` with the request key unchanged; a polled status with an approval control is denied as in test 13; `events` throwing `not_found` polls too; a `status` throw fails with `outcome=lost` and the id kept unsettled.
12. Earlier runs, across a simulated restart, on the next message: an `unknown` id gets `resolveUnknown`; a `running` id gets `stop`; both are removed once terminal; the new run runs.
13. Approval: `deny` with the exact body; the "Denied:" line ends the reply; the run completes. No pending control, or a failing `deny`: `stop`, then `run_failed`.
14. `requestBody`: byte-identical across reruns; `instructions` is exactly `INSTRUCTIONS`; the quote line with text, with multi-line text, and without text; the attachments note with 1 and with 3; text only.
15. The 30-minute cap: the fake server answers `running` to every status read and the stream ends at the idle timeout, so the turn polls until the cap: `stop`, then `run_failed`, `outcome=capped`, the id kept unsettled.
16. Plugin reload mid-turn: a second deps over the same state instance while the first turn's stream is open; the reply is delivered once.
17. Restart interplay, each across a simulated restart: a turn held before `handing` (the mirror stub hangs; the fake server got no POST) stays `accepted`, is counted `not handed 1` in the `restart ledger` line, gets no device event and is never rerun; a turn cut off after its POST stays `handed` or `started`, is counted so, gets no error and is never rerun; a parked one stays `parked`, is counted so, and reruns through `routedRerun` with the same request key; for each, the new ledger's `claim` of the same message answers `"duplicate"`.
18. A message OpenClaw parked reruns on OpenClaw after its conversation was opted in; a key-store lookup that rejects fails the message closed with one `run_failed`, with no `handleMessage`.
19. Error paths, one test each: `auth` and `conflict` from `createRun`; an empty `output`; a batch status other than `sent`; a failing key write; a failing mirror (logged, the turn goes on); an unexpected throw (one `run_failed`, the FIFO's next message still runs). Each writes one usage line with its `outcome`.
20. FIFO: two messages in one opted-in conversation run in order; a message right after `/backend hermes` queues behind the opt-in; a throwing link doesn't block the next.
21. Backend off at a reload, through `startAccount` with `enabled: false`: a parked Hermes message ends with one `run_failed` "…wasn't rerun", with no `handleMessage` and no request; a message OpenClaw parked still reruns on OpenClaw. The same with the backend on and the route store failing to load, which also logs `hermes state unavailable`.
22. No log line from any test contains the API key.
23. State: `setRoute` then `routedToHermes` is true, and a second `setRoute` answers `"already"`; a new `createHermesState` over the same rows (restart) sees the route; `addUnsettled` twice keeps one; a failing store write rejects and leaves the map unchanged.

Guards: `genui-golden`, `prerun-error`, `hub-session`, `presentations` and the sync 01 tests. New checks: `backend-claim` (its pure part runs in CI) and `backend-passthrough`; run with `YOROZU_OPENCLAW_SDK=$HOME/openclaw`, their gated parts must pass; without it, they are skipped, as in CI.

### Recordings feed back (operator steps 8–11)

H2's PR adds the recordings to "Hermes API facts" and makes these changes before any H2 code:

| Recording | Result | Change |
|---|---|---|
| Operator step 8: usage, tool event fields | the names | the † names in the JSON mapping and Turn outcomes; H2 test 9 asserts them |
| Operator step 8: `run.failed`'s `partial` | Hermes's own "work was done" flag | the status table's temporary row uses `partial: false` in place of "no tool seen"; H3 test 9 asserts it |
| | anything else | as written |
| Operator step 9.4: `approvals.mode` denies every escalation server-side while the run continues | yes | H2 drops `deny` and its part of test 6; H3 drops the `approval.request` row, the polled-approval rule, the "Denied:" line and test 13's body, which becomes: an escalation fails that tool step and the run completes with Hermes's own message (D4 holds; P11 passes so) |
| | no | as written |
| Operator step 9.5: `stop` ends a run waiting on an approval | no | turn step 3 can't end such an orphan: a Risks row, and the run ends at Hermes's own limits |
| Operator step 11: `GET /api/sessions/{id}` names the session's running or `unknown` run | yes | turn step 3 reads it instead of `unsettled`; `unsettled`, `addUnsettled`, `removeUnsettled` and the route entry's field go (the route store value becomes `{}`); H3 tests 11, 12, 15 and 23 assert the session read instead |
| | no | as written |
| Operator step 10 | — | information only; H3's FIFO serializes either way |

### Operator steps (H0 and enablement)

The Yorozu agent runs every step on the Mac mini, except where it says the owner. Coder runs none of them.

`H` stands for `HERMES_HOME=~/.hermes-yorozu-test ~/.hermes-yorozu-test/hermes-agent/.hermes/bin/hermes`.

**Forbidden commands:** `hermes` with any other home or without `HERMES_HOME`; `hermes claw cleanup`; `hermes claw migrate`; any `--migrate-secrets`. `import-agent` only as written in operator step 12.

**Start and stop of the hand-started Hermes gateway** (until operator step 14):
- Start: `mkdir -p ~/.hermes-yorozu-test/logs && date >> ~/.hermes-yorozu-test/logs/starts.txt`, then `H gateway run >> ~/.hermes-yorozu-test/logs/hand.log 2>&1 &`. Check the subcommand with `H gateway --help` first.
- Stop: `kill $(lsof -tiTCP:8652 -sTCP:LISTEN)`. Hard stop for operator step 11: `kill -9` instead. Check with `lsof -iTCP:8652`.

**`probe.sh`** lives in the box handover fixtures folder. Copy it to `~/.hermes-yorozu-test/probe/` on the mini and run it from there. Each new recording takes the next free `NN` and adds a line to `index.txt`. Recordings go back to the handover folder; Coder scrubs the ones that become fixtures (H2).

**Done (2026-11-19):** operator steps 1–6, as one install:
1. A separate clone at `3b42157858`, home `~/.hermes-yorozu-test`, `cli.expose_on_path: false`.
2. The API server only, on `127.0.0.1:8652`, with its API key in the home's `.env` (0600) and `auth.adopt_external_logins: false`. No messaging platform. Fixtures 01–04.
3. OpenClaw unchanged (`~/.openclaw/openclaw.json` mtime and sha256 recorded in the rollback note).
4. A client-chosen `session_id` accepted (fixtures 08, 14).
5. Idempotency (fixtures 11–13).
6. Failure shapes (fixtures 09, 10, 16, 17).

**Pending:**

7. **The owner: Codex sign-in and two questions** (about 5 minutes; the device code shown in Terminal lasts 15 minutes). The owner signs in with the same ChatGPT account OpenClaw uses, so the two share its quota.
   1. In Terminal on the mini: `HERMES_HOME=~/.hermes-yorozu-test ~/.hermes-yorozu-test/hermes-agent/.hermes/bin/hermes model`.
   2. Choose OpenAI Codex, and answer **N** to importing the Codex CLI tokens.
   3. Open `https://auth.openai.com/codex/device`, enter the device code, sign in.
   4. The Yorozu agent checks with `H auth status openai-codex`.
   5. The Yorozu agent asks the owner, yes or no: (a) Does the Hermes gateway (Python) run as a third-party runtime, outside "never Python"? (b) In an opted-in conversation, may `/new` and `/reset` answer with a notice instead of resetting in place? A "no" to (a) stops the test. A "no" to (b) holds H3 until the Yorozu agent and the owner settle what `/new` does there.
8. **A completed run with a tool.** POST a run with `session_id` `yorozu-h0-probe-8` and input "Run `date` in the terminal and tell me the output." Record the event stream, the status (with `usage`), and the tool events' fields (tool call id, success field). Separately, record a `run.failed` after a tool ran, if one can be provoked, to learn what `partial` means.
9. **Approvals.** Hermes's `approvals.mode: smart` runs commands it judges safe and asks for the rest.
   1. Set `agent.disabled_toolsets: [cronjob]` in the test home's `config.yaml`.
   2. Send each command of a fixed list of 10 as its own run (session `yorozu-h0-probe-9-<n>`): `ls ~`, `cat /etc/hosts`, `mkdir -p /tmp/yorozu-h0 && touch /tmp/yorozu-h0/a`, `rm -rf /tmp/yorozu-h0`, `curl -sI https://example.com`, `git -C ~/.hermes-yorozu-test/hermes-agent status`, `chmod 777 /tmp/yorozu-h0-x`, `sudo -n true`, `osascript -e 'display notification "h0"'`, `kill -0 1`. For each, record only whether `approval.request` came (no output). The result is the list of commands `smart` runs without asking.
   3. For one that asked: record `approval.request`, the status's `pending_controls` (with the approval kind's name), the `deny` exchange, and what the run did next.
   4. Check whether `approvals.mode` can deny every escalation server-side while the run continues.
   5. For another that asked: `POST /v1/runs/{id}/stop` while it waits, and record whether the run ends.
10. **Two runs at once on one session.** Two POSTs with different request keys and the same `session_id`, under 1 s apart. Record whether the second waits, fails or runs alongside.
11. **Interrupted and unknown runs.** Start a run with a long tool ("Run `sleep 60`, then say done."), stop the Hermes gateway cleanly mid-run, and record `run.interrupted`. Repeat with `kill -9`, start Hermes again, and record `unknown`, a second run on that session waiting, `resolve-unknown`, and whether `GET /api/sessions/{id}` names the session's running or `unknown` run.
12. **Persona.**
    1. `H plugins install agent-importers`.
    2. `H import-agent openclaw --dry-run`, and confirm from its output that it only reads `~/.openclaw`.
    3. Review each MCP server it would import (name, command, `trust`). Drop any that writes outside the Hermes home.
    4. `H import-agent openclaw` (without `--migrate-secrets`).
    5. Check that `~/.openclaw/openclaw.json`'s mtime and sha256 still match the rollback note.
13. **The quality batch (P12, P13).** The Yorozu agent runs it while the owner isn't using Yorozu.
    1. Pick 20 read-only prompts (no sends, no writes) from the owner's past Yorozu conversations and list them in the vault note first.
    2. Hermes: for each, POST `/v1/runs` as `probe.sh` does, with body `{input: <prompt>, session_id: "yorozu-p12-<n>", instructions: <INSTRUCTIONS from turn step 5>}`, and read the event stream to the terminal event. Time: from sending the POST to receiving the terminal event.
    3. OpenClaw: for each, OpenClaw's CLI agent command (check the form with `openclaw agent --help`) in a throwaway session `p12-<n>` that no Yorozu conversation uses. Time: from starting the command to its exit, with `/usr/bin/time -p`. This includes the CLI's start-up, so P13 compares the two knowing that.
    4. Blinding: strip each pair of backend names, model names and tool traces; assign A and B per task with `jot -r 1 0 1`; keep the assignment in a separate file outside the vault note until the owner has picked. The owner sees one vault note with 20 sections and writes A, B or tie for each.
14. **Enablement.** After H3 merges, with the owner's approval of these yes/no questions, asked together:
    - Edit the OpenClaw config to turn on the flag (and restart the OpenClaw Gateway if needed)?
    - Run the Hermes gateway under launchd (label `local.hermes-yorozu-test`, `KeepAlive: true`) instead of by hand?

    A "no" to the second keeps Hermes hand-started. Then:
    1. Check that the plugin the OpenClaw Gateway loads includes the H3 merge: `git -C <main checkout> merge-base --is-ancestor <H3 merge commit> HEAD`. Run the `/backend` claim check with the live config: `YOROZU_OPENCLAW_SDK=$HOME/openclaw YOROZU_OPENCLAW_CONFIG=$HOME/.openclaw/openclaw.json node --test plugins/openclaw-yorozu/test/backend-claim.test.ts`, and `backend-passthrough.test.ts` with the same SDK. A failure goes to Coder, and nothing below runs.
    2. Check that `grep -c '^API_SERVER_KEY=' ~/.hermes-yorozu-test/.env` prints 1, then `cd ~/.hermes-yorozu-test && (umask 077; grep '^API_SERVER_KEY=' .env | cut -d= -f2- > yorozu-plugin.key)`.
    3. `cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak-hermes-test`.
    4. `openclaw config set channels.yorozu.backends.hermes.enabled true`. Check that `openclaw config get channels.yorozu.backends.hermes.enabled` prints `true` (a boolean, not `"true"`) and the OpenClaw Gateway log shows `yorozu: hermes backend on`.
    5. Write `~/Library/LaunchAgents/local.hermes-yorozu-test.plist`, with `<home>` the absolute path of `~/.hermes-yorozu-test`: `Label` `local.hermes-yorozu-test`; `ProgramArguments` `[<home>/hermes-agent/.hermes/bin/hermes, gateway, run]`; `WorkingDirectory` `<home>`; `EnvironmentVariables` `{HERMES_HOME: <home>, PATH: <home>/hermes-agent/.hermes/bin:/usr/bin:/bin:/usr/sbin:/sbin}`; `KeepAlive` true; `StandardOutPath` and `StandardErrorPath` `<home>/logs/launchd.log`.
    6. Stop the hand-started Hermes gateway, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.hermes-yorozu-test.plist`.
    7. Check with `openclaw config get channels.yorozu.backends` and `launchctl print gui/$(id -u)/local.hermes-yorozu-test`.

**Stop rule.** H2 and H3 don't start, nothing merges, and the result goes to the owner as a no-go, if either holds:
- by operator step 11, Hermes hasn't completed a run with a tool on the Codex sign-in;
- in operator step 13, Hermes is preferred in fewer than 5 of the 20 pairs.

### Test plan and go/no-go report (H6)

| Row | Scenario | Where | Pass |
|---|---|---|---|
| P1 | Plain chat over the relay and the direct listener | The owner's devices | ✓✓, then the reply, the same on both devices |
| P2 | A long tool run (about 5 min) | The owner's devices | Tool rows and Live Activity steps update; typing never lapses |
| P3 | A device offline during the turn | The owner's devices | The reply shows after catch-up, once (the app merges items by id), in order |
| P4 | Two devices, sending from one | The owner's devices | The other shows the message and the reply, no duplicates |
| P5 | The Yorozu agent stops the Hermes gateway, then the owner sends a message, and starts it again within 3 min; separately, a clean stop and a `kill -9` mid-run | Test home + a device | Stopped and back in time: the reply arrives once. Every other case: one error row, no stuck typing, and the next message in that conversation runs. |
| P6 | An OpenClaw Gateway restart mid-turn | H3 test 17 | Before `handing`: counted `not handed`, no rerun. After: counted, no device event, no rerun. Parked: the rerun replays the same request key (one Hermes run). A resend gets only `delivered`. |
| P7 | The same message twice; a timeout after admission; a rerun after a park | H2/H3 tests | One Hermes run per request key; the key advances only after a temporary `run.failed` with no tool |
| P8 | Rename, pin, archive, delete; `/new` | The owner's devices | As on OpenClaw; `/new` gets the notice |
| P9 | History after reinstalling the app | The owner's device | The full conversation, including the `/backend hermes` line, each Hermes reply once |
| P11 | A command that needs approval | H3 test 13, plus one real check after operator step 14 | Denied with the plain line; the run continues |
| P12 | Quality on the 20 tasks | Operator step 13 | Hermes / OpenClaw / tie counts |
| P13 | Latency and tokens | Operator step 13 times; usage lines | p50 and p90 per backend over the 20 paired tasks; tokens per Hermes turn |

- **Real use** starts after operator step 14 and runs at least two weeks. Only turns sent while the Hermes gateway was up count. Turns cut off by an OpenClaw Gateway restart are excluded for both backends.
- **Restarts.** OpenClaw Gateway restarts from `~/.openclaw/logs/gateway-restart.log`. Hermes restarts: under launchd, the `runs = N` line of `launchctl print gui/$(id -u)/local.hermes-yorozu-test`; hand-started, the lines of `~/.hermes-yorozu-test/logs/starts.txt`.
- **Quota.** The Yorozu agent runs `rg -i 'rate.?limit|\b429\b' ~/.openclaw/logs/ | rg -v 'yorozu: hermes'` daily. During the P12 batch, an OpenClaw 429 stops the batch. During real use, it makes the Yorozu agent ask the owner to stop sending in opted-in conversations. The flag stays on.
- **Tool gaps.** When a Hermes reply says it lacks a tool OpenClaw has, the owner or the Yorozu agent adds it to the test's vault note under `Projects/Yorozu/`.
- **Double run.** Two different run ids in the `createRun` lines for one request key: Hermes's. One message with two request keys whose first run had used a tool: the plugin's.
- **Lost reply.** A delegated message whose usage line says `outcome=lost`, or that has a `createRun` line and no usage line, excluding turns cut off by an OpenClaw Gateway restart. The Yorozu agent reads that run's status afterwards: `completed` means the plugin lost a finished reply (the plugin's); a run that never ended, or that Hermes no longer knows, is Hermes's.
- **Spend.** At the go/no-go the owner checks the ChatGPT account: no new subscription or billing line.
- **Report.** The Yorozu agent writes it to the vault under `Projects/Yorozu/`: P1–P9 and P11 pass or fail; double runs and lost replies with blame; the P12 counts; P13; restart counts; spend; tool gaps.
- **Outcome.** At n = 20 the numbers are indicative only, so the owner decides: **go** (the Yorozu backend switch, which opens ADR-H4), **extend** (moves the go/no-go date; the code stays until then, and a date past 2026-12-31 needs a new owner exception), or **no-go**. One rule is fixed: any double run or lost reply blamed on Hermes is a no-go. With no decision by 2026-12-31, the outcome is no-go.

## Testing decisions

- **Dormant until the flag is on.** No Hermes code path runs while `channels.yorozu.backends` is absent; H1 test 2 and H3 test 2 check this. Every merge still ships a Mac beta.
- **Seams, highest first.**
  - H3: `routeMessage` and `routedRerun` with injected deps (the real client against the fake Hermes, the stand-in `TurnContext`, the real `retry.ts`), plus three `startAccount` wiring tests.
  - H2: the client against the same fake server, from the scrubbed fixtures.
  - H1: `resolveHermesBackend` on real temp files; `startAccount` on the `presentations.test.ts` base.
- **What a good test checks:** the requests the fake Hermes received (method, path, request key, body), the events each device receives, the batch and mirror calls, store rows (including the `runs` ledger), log lines (including the `createRun` and usage lines). Not private maps.
- **Prior art:** `prerun-error` (the resolve hook and the `relay.js` recorder) and `genui-golden` (turns on the stand-in host); `presentations.test.ts` (`startAccount`); `relay-integration` (a real local server in a test); `conversation-owner.test.ts` and its fixture (the SDK-gated tests); the sync 01 tests (ledger, restart seam, call-order recorder).
- **Acceptance commands** (Node 26, as CI):
  - `node --test 'plugins/openclaw-yorozu/test/*.test.ts'` from the repository root.
  - `tsc -p plugins/openclaw-yorozu/tsconfig.standalone.json --typeRoots <dir>/node_modules/@types` with TypeScript 7.0.2 and `@types/node` 26.6.2 installed in `<dir>`, as `plugin-typecheck.yml` does.
  - The full plugin typecheck against the OpenClaw checkout ([plugin README](../../plugins/openclaw-yorozu/README.md#typecheck)), with no errors in plugin files.
  - H1: `node apps/mcp/scripts/generate.ts --check`; `git diff --exit-code apps/mcp/src/content.json` after `node apps/mcp/scripts/generate.ts`; and CI's `mcp` job: `pnpm --filter @yorozu/help-mcp check`, `typecheck` and `test`.
  - H3: `YOROZU_OPENCLAW_SDK=$HOME/openclaw node --test plugins/openclaw-yorozu/test/backend-passthrough.test.ts plugins/openclaw-yorozu/test/backend-claim.test.ts` (local only; CI runs `backend-claim`'s pure part and skips the rest).
  - Every PR: every CI job it starts passes (including `plugin`, `relay` and the Windows core job); `git diff --stat` shows no change to the guard files.

## Alternatives considered

- **Option A: a Hermes platform plugin (Python) as a second Yorozu host.** It ports the Noise sessions, the relay host, history and push to Python, needs a re-pair, and puts Yorozu code in Python.
- **Option C: a standalone Yorozu host that talks to Hermes.** The retirement shape; breaks "No Mac host process". Considered only after a go (ADR-H4).
- **Option D: OpenClaw's agent pointed at Hermes over ACP** (Agent Client Protocol). It moves one OpenClaw agent, so it moves all of Yorozu unless OpenClaw can bind ACP per thread, which wasn't checked.
- **D1 alternative: a backend interface.** More code for a test whose code is deleted after a no-go.
- **D2 alternative: a Hermes-only conversation record.** The list, pin, archive and history would all need new code.
- **D3 alternative: a fresh request key per attempt.** A timeout after admission would run the work twice.
- **D4 alternative: stop the run on a denied approval.** One gated tool would lose the whole answer.
- **D5 alternative: fixed pass bars.** At n = 20 a fixed bar would decide on noise.
- **Opting in with the first message of a new conversation.** Cut: OpenClaw would answer the literal `/backend hermes` on the shared quota, and the conversation would stay untitled (`sessions.ts:210` and `push.ts:57` skip `/` text).
- **Retrying a replayed or interrupted run with the next request key.** Cut: the turn can't tell whether a tool ran in a replayed run, and D3 covers only temporary failures.
- **Re-attaching to the event stream after it is lost** (with `Last-Event-ID` or a re-attach loop). Cut: unverified on v0.23.1, and polling the status needs neither replay handling nor a re-attach limit.
- **Delivering a finished orphan's output as a late reply.** Cut: it would arrive out of order, no Test plan row needs it, and turn step 3 stops orphans instead.
- **A cap on opted-in conversations or on unsettled ids.** Cut: no Test plan row needs them and both guard against no stated risk.
- **A start-up `/backend` claim warning in the plugin.** Cut: static SDK imports could stop the channel module loading on every install; the claim check is a test instead.
- **Rerunning parked Hermes messages on OpenClaw when the backend goes off.** Cut: Hermes may already have admitted them, so they could run on both backends.
- **Seeding the Hermes session with OpenClaw's history.** Opting in after one OpenClaw turn keeps that turn small instead.
- **Aborting Hermes turns on a plugin reload.** It drops answers OpenClaw turns keep across a reload.
- **The unsettled run id in memory.** Lost on a restart, it could block a conversation behind an `unknown` run for good.
- **A circuit breaker for the shared quota.** Departs from the auto-retry rule and needs the owner.
- **Mirroring tool rows into the transcript.** Unverified API, and no Test plan row needs it.
- **Retrying a failed mirror (with sync 01's `findUserMessage`).** One lost history line, logged, doesn't justify another sync 01 dependency.
- **Documenting `backends` in `docs/setup.md`.** It would start Deploy website for a test-only key.

## Risks

| Risk | Mitigation or check |
|---|---|
| Hermes's terminal, file and browser tools run as the owner's macOS user. They can read `~/.openclaw` and the key file, and web pages can inject prompts. | The same exposure OpenClaw's own exec tools have, for what `approvals.mode: smart` runs without asking (operator step 9); the plugin denies every escalation that asks. `cronjob` is disabled. If operator step 9 shows `smart` runs something OpenClaw would ask about, the Yorozu agent reports it before operator step 14. |
| An orphaned Hermes run after a restart keeps going, and may use tools, until the next turn in that conversation stops it; its output is never delivered. | It was handed, so nothing reruns it; the awaiting window ends it on the device. Counted in the restart ledger line and the report. |
| A run whose id was never stored (a restart between the POST and `addUnsettled`, or a failed `addUnsettled` write) can't be stopped by the plugin. | It runs to its own end. If Hermes makes later runs on the session wait (operator step 10), the next turn waits behind it, bounded by the 30-minute cap. |
| `resolveUnknown` keeps failing for an `unknown` run. | The id stays; each next turn tries again and logs `earlier run not ended`; the Yorozu agent reports such lines to Coder. |
| A failed or slow `handing` write leaves a handed Hermes turn `accepted`. | At a restart it is miscounted as `not handed`; sync 01 acts on no count. Logged `run ledger write failed` or `run ledger write slow` (both should never appear). |
| Sync 01's restart ledger lines mix both backends. | The `createRun` lines name every Hermes message id, so the Yorozu agent can split the counts by id. |
| Turning the backend off fails a parked Hermes message instead of rerunning it. | Accepted: one error row, and the owner resends. Rollback step 2 waits until none is left. |
| A plugin command of the live install claims `/backend`. | The claim check covers built-ins and the live config's skills, not live plugin commands (they need the OpenClaw Gateway's plugin registry). With the backend on, `/backend hermes` never reaches OpenClaw, so this matters only while it is off. |
| Imported MCP servers | Reviewed one by one at operator step 12; no secrets migrated. |
| The shared ChatGPT quota | The daily 429 check (Test plan). |
| Dormant code in a public beta | Nothing merges before the stop rule; the flag is off by default; H1 test 2 and H3 test 2 check that no Hermes path runs without the config entry. |
| Owner data in committed fixtures | Scrubbed before commit; H2 test 8; Coder reads each file. |
| The sync work slips | The whole stack waits on sync 01 only; the 2026-12-17 deadline rule. |
| Hermes and OpenClaw histories drift | Opt-in needs one OpenClaw turn first; `/new` and `/reset` answer with a notice. |
| Reply ids differ from the transcript ids | The app's existing text match applies, as for cron deliveries (unverified for Hermes replies; checked in P9). |
| The API key leaks | No redirects followed; never logged or put in an error; H2 test 7 and H3 test 22. |
| The `.env` API key format differs from what operator step 14.2 expects | The reader strips one pair of quotes; a wrong key fails with `auth` and "refused the API key". |

## Further notes

- **For the later sync spec (02–04).** If it re-parks never-handed messages into the retry store (A-9), `routedRerun` dispatches by the key store: an opted-in message cut off before turn step 4's key write has no key and would rerun on OpenClaw. Whatever report the later spec sends for cut-off turns applies to Hermes turns unchanged, since their entries carry the same states.
- **Rollback (also the no-go clean-up).** In this order:
  1. Turn the flag off: `openclaw config set channels.yorozu.backends.hermes.enabled false`, or restore `~/.openclaw/openclaw.json.bak-hermes-test`. This edits the OpenClaw config, so it needs the owner's approval. Every new message goes to OpenClaw from the reload.
  2. With the OpenClaw Gateway running, wait at least 5 minutes (the longest retry delay is 120 s), and check that no `hermes run parked` line is newer than step 1. Then `openclaw config unset channels.yorozu.backends`, before any revert of H1: otherwise the leftover entry fails the restored schema's `additionalProperties: false`.
  3. `launchctl bootout gui/$(id -u)/local.hermes-yorozu-test`, and delete the plist.
  4. Stop the Hermes gateway, then `rm -rf ~/.hermes-yorozu-test` (this also removes the key file).
  5. Revoke the Hermes session in ChatGPT's connected apps.
  6. Revert H3, then H2, then H1 (with `TEST_ONLY_KEYS`), or close them if unmerged.

  Left behind, inert: the keyed-store namespaces `backends` and `hermes-keys`; Hermes messages' `runs` entries, which age out after 24 h; and the mirrored messages in transcripts, which are normal history. Step 2's wait leaves no Hermes message in the `retry` store. The rollback note for the H0 install is in the owner's vault (`Projects/Yorozu/2026-11-19 Hermes H0 test install rollback`).
- **Unverified.** Operator steps 8–13; the three before-code questions; per-thread ACP routing in OpenClaw (Option D); the Codex plan's limits with two agents on it; the OpenClaw Gateway and Hermes failing at the same moment; `gateway run`, `agent.disabled_toolsets`, `import-agent` and `plugins install` in the test home; replay after a Hermes restart (documented, not recorded); whether the app's text match pairs a Hermes reply with its transcript line; whether `listSkillCommandsForAgents` accepts the live config file as read.
- **ADRs.** ADR-H1 (D1), ADR-H3 (D3) and ADR-H6 (D2) are the decisions above. ADR-H2: Hermes runs from its own clone and home, on loopback, with no messaging platforms. ADR-H4 (deferred): OpenClaw retirement. ADR-H5: Hermes conversations are text only.

## Review dispositions (round 2)

EGM round 2 of this dev spec, on v4 (`.egm/20261119-134218/`, git-ignored). Directions from Coder's brief for v5.

| Id | Disposition | Reason |
|---|---|---|
| X-1 | FIXED | Test seams and prior art cite `prerun-error.test.ts` (`./genui-hooks.ts` at line 4, its own hook at line 19), whose `relay.js` recorder also gives the `activityTurn` recorder. |
| M-1 | FIXED | Stage 8's polling: after a lost stream the turn polls `status` every 5 s until a terminal row or the cap; "Lost contact" only when `status` throws. Re-attach loop, `lastSeq` and the event-replay recording removed. After a lost stream a temporary `failed` fails the turn without advancing the request key. Operator step 8 records `partial`; "Recordings feed back" says when it replaces `toolSeen`. Test 15 reaches the cap through polling. |
| M-2 | FIXED | Turn step 3 now `stop`s any earlier run still not terminal (FIFO makes every such id an ended turn's); the 10-id cap, its log line and test removed (scope rule). Risks rows for a never-stored id and a failing `resolveUnknown`; operator step 9.5 records `stop` on an approval-waiting run. S5 B2 (late delivery) not adopted, in Alternatives. |
| M-3 | FIXED | Never falls back: the key store is opened whenever `backends.hermes` is present, and a keyed parked message with the backend off (flag, unreadable key file, or failed state load) ends with one `run_failed`. Story 11, the restart table, red test 21 and Rollback step 2's wait match. State-load failure logs at `warn`. |
| M-4 | FIXED | One `createRun` line per POST; double run and lost reply defined from it, with blame. Offset by dropping `first_event_ms` and `model` (N-2). |
| M-5 | FIXED as directed | The check stays, as a test only: `backendClaims` lives in the test file (non-gated in CI), the SDK part is gated and imports dynamically; `checkBackendClaim`, the `startAccount` call, the three claim stubs, `src/backend-claim.ts`, test 23, before-code question 4 and the start-up log check removed. Live coverage by running the test with `YOROZU_OPENCLAW_CONFIG` at operator step 14.1. `backend-passthrough.test.ts`'s source named. New tests called "new checks". |
| M-6 | FIXED | `/backend hermes` matches exactly (case-insensitive, whitespace collapsed); other `/backend …` passes through to whichever agent, as the pass-through check verified. Routing row and test 1 cases added. |
| M-7 | FIXED | Wording option: two "What differs" bullets (commands as text; a mid-run message waits); story 3 narrowed. |
| M-8 | FIXED | One "Sync 01 calls" table, checked against PR #751's code (including A-12's 2 s `handing` deadline), with the notice's direct `turnEnded`; every other copy now points there. `externalTurn` signature and `runStarted` shape fixed. Red tests 1 and 5 assert the notice and slow-write paths. |
| M-9 | FIXED | "Turn step N" and "operator step N" throughout, with a glossary row. |
| M-10 | FIXED | Six done operator steps listed. |
| M-11 | FIXED | "Awaiting window" glossary row pointing to the sync spec's S2. |
| M-12 | FIXED | Labels line in the header; glossary rows for before-code question and A-n; A-9 and A-12 rows. Round 1's dispositions left to git history (`0e63bcad`). |
| M-13 | FIXED | Nothing in H1 or H2 uses `HermesState`, so it and the key store move to H3; H1 is the schema, `resolveHermesBackend` and `TEST_ONLY_KEYS`. The state tests become H3 test 23. |
| M-14 | FIXED | H2's PR records operator steps 8–11 first; "Recordings feed back" gives each outcome's concrete changes. |
| M-15 | FIXED | 20-conversation cap, `"full"`, its notice, cell and tests removed (scope rule); deleted conversations' routes stated inert. |
| M-16 | FIXED | JSON mapping table with required fields per method; H2 test 9's assertions stated. |
| M-17 | FIXED | `relay.js` recorder via the test's hook; `claim` before `routeMessage`; hold by a hanging mirror stub; resend as `claim === "duplicate"`; timers via `setTimeout`, mocked APIs and test client options stated; harness changes in the red-test commit; real `runParked`; `channel()` takes `cfg`. |
| M-18 | FIXED | `INSTRUCTIONS` is a literal string used by `requestBody` and operator step 13; both commands, timing points and the blinding procedure stated. |
| M-19 | FIXED | The 429 check excludes `yorozu: hermes` lines and says what it stops during real use; "is enough for a test" removed. |
| M-20 | FIXED | Fixtures are scrubbed before commit, listed in a README; operator step 9.2 records no output; scrub test extended to home paths. |
| M-21 | FIXED | Check order `statSync`, regular file, mode, read, empty; a directory gives "not a regular file". |
| M-22 | FIXED | Question 3's "no" uses `results[0]?.messageId` (`channel.ts:256`) and skips the push, logged, without one. |
| M-23 | FIXED | Problem states the question; measures point to Measurement and the Test plan; restart sentence rewritten as proposed. Why a replacement is considered isn't in the brief beyond the owner's request, so nothing was invented. |
| M-24 | FIXED | Extend handled in Solution and D1; story 6 "doesn't knowingly"; story 11 "one config change"; asked and not-asked readings marked; before-code lead-in fixed; the "changes nothing" line replaced. |
| M-25 | FIXED | Real use at least two weeks; the deadline is now H3 merged by 2026-12-17; hand-started Hermes restarts counted from `starts.txt`. |
| M-26 | FIXED | "The Yorozu agent"; API key, key file, request key, key store, config entry; "OpenClaw Gateway" and "Hermes gateway" in full; "sync spec" and "sync 01" defined once; auto-retry rule rewritten; `externalTurn` facts split into bullets. |
| N-1 | FIXED | Explicit `HermesError` fields; 4 vs 7 minutes; invariant sentence deleted; `started()` meaning stated; park reordering accepted. |
| N-2 | FIXED | Key file path fixed (deletes `keyFile` and two refusal rows); `first_event_ms` and `model` dropped; tool gaps' source named. |
| N-3 | NOT ADOPTED | A failed mirror loses one logged history line; another sync 01 dependency isn't worth it (Alternatives). |
| N-4 | FIXED | `externalTurn` and Wiring get their own headings; ticket tags on headings consistent; Solution, Non-goals and Referenced decisions de-duplicated. |
| N-5 | FIXED | Story 10 narrowed; section references match headings; error text and `isTemporary` above the status table; wordings fixed; EGM, Codex, standalone list, help bundle, `approvals.mode: smart` and the device code defined at first use; "Production-grade code" dropped. |
| N-6 | FIXED | Counts follow from the new lists; stale round-1 rows and emoji gone with the round-1 table; bare "H" replaced by "the H tickets". |
| N-7 | FIXED | H3 start gate names the stop rule; operator step 14 checks the `.env` name, uses absolute `<home>`, adds `WorkingDirectory` and `PATH`, checks the boolean and the installed commit with git; squash merge stated; fixture README; P5 method; P11 after operator step 14; `park` import; `--typeRoots`; all CI jobs; "once" depends on merge by id; revert H3, H2, H1; leftovers include `runs` and `retry`. |
| N-8 | FIXED | "Prove" gone; release paragraph is a table; "unless it goes", "can't carry a bar", "rare case" and "target 0" rewritten; actors named in operator step 13; the claim-line handoff is gone with the runtime check. |
