# Hermes Agent as a second backend: side-by-side test

- **Status:** reviewed (EGM round 4, `.egm/20261119-103629/consolidated_review_report.md`, git-ignored). This dev spec resolves its 4 🔴 and 23 🟡 items; the dispositions are at the end.
- **Brief:** the Hermes backend test spec v4 with its §8 decisions (box handover `transfers/20261119-yorozu-hermes-backend-spec.md`), handed to Coder as `Tier: feature`. The direction is final.
- **Stacks on:** the sync restart durability spec v2 (box handover `transfers/`, Coder's copy `sync-restart-v2.md`): its run ledger, start-up sweep and shape A1(b).
- **Baseline:** `origin/main` at `8a278a5c`. Everything Hermes in this spec is future tense. The sync ledger, sweep and session-open report don't exist at `8a278a5c` either: they land with sync tickets 01 and 02 on `feat/sync-restart-plugin`.
- **Roles:** *the owner* uses the app and approves. *Yorozu (the agent)* owns the product decisions and runs the operator steps on the Mac mini. *Coder* wrote this spec and implements H1–H3. "Yorozu" alone means the product: the apps and the plugin `plugins/openclaw-yorozu`.
- **Box handover:** the folder the agents share, `/home/box/handover` on the box (the shared Linux machine). `transfers/` holds the source specs and the H0 fixtures.

## Problem

The owner asked (2026-11-19) to "start testing of hermes agent backend as replacement to openclaw". Today every Yorozu turn runs on OpenClaw, so there is no way to compare. The test answers one question: in the owner's own Yorozu conversations, how does Hermes Agent compare with OpenClaw on answer quality, tools and latency?

Any benefit for Gateway restarts belongs to the later OpenClaw-retirement shape (ADR-H4). The plugin stays inside the OpenClaw Gateway here, so this test only counts restarts of each process.

## Solution

- The plugin gains a test-only, off-by-default config key, `channels.yorozu.backends.hermes`.
- With it on, the owner opts one conversation in by sending `/backend hermes`. From then on, that conversation's agent turns run on Hermes Agent through its runs API on `127.0.0.1:8652`. Everything else stays on the plugin and OpenClaw: pairing, the relay, push, the conversation list, history, titles, pin, archive, delete.
- An opted-in conversation is still an OpenClaw session. The user message and Hermes's final reply are mirrored into its transcript, so history and new devices work unchanged.
- Hermes conversations are text only. Cards, Automations, reactions and image input stay on OpenClaw.
- Nothing changes on the wire, the relay or the apps.
- The test ends at the go/no-go or on 2026-12-31, whichever is first. Unless the outcome is go, the flag and its code are removed.

## User stories

1. As the owner, I want to opt a conversation into Hermes by sending `/backend hermes`, so that I can try Hermes on real work without re-pairing.
2. As the owner, I want `/backend hermes` as the first message of a new conversation to work too, so that I don't have to send a throwaway message first.
3. As the owner, I want every other conversation to keep running on OpenClaw exactly as before, so that the test can't break my daily use.
4. As the owner, I want an opted-in conversation to look the same as any other: ✓✓, typing, tool rows, Live Activity steps, the reply, push, history on every device.
5. As the owner, I want a short Hermes outage (Hermes restarting, a rate limit) before any tool ran to fix itself within about four minutes, as OpenClaw turns do, and a single clear error after that, so that I never wait forever.
6. As the owner, I want a Hermes run that failed for a permanent reason (no model provider, a refused key) to show its error once and never be retried, so that I learn about it at once.
7. As the owner, I want a message to run at most once on Hermes, even when the plugin retries it or Hermes replays it, so that tools don't repeat.
8. As the owner, I want a Hermes run that needs an approval to have that step denied with a plain line in the reply while the rest of the answer arrives, so that one gated tool doesn't lose the whole answer.
9. As the owner, I want `/new` and `/reset` in an opted-in conversation to tell me to start a new conversation, so that the Hermes and OpenClaw sessions can't drift apart.
10. As the owner, I want a turn cut off by a Gateway restart to end with the same Interrupted row the sync work gives OpenClaw turns, and nothing resent without my tap.
11. As the owner, I want a `channels.yorozu` config change (a plugin reload) not to lose a Hermes reply that is on its way.
12. As the owner, I want turning the flag off to return every conversation to OpenClaw at once, so that rollback is one config edit.
13. As Yorozu (the agent), I want one log line per Hermes turn with its outcome, timings and tokens, so that I can write the go/no-go report from logs and transcripts.
14. As Coder, I want each PR dormant until the flag is on, with tests at the plugin's existing seams, so that merging it changes nothing for anyone.

## Implementation decisions

### Referenced decisions

These are final. This spec builds on them and doesn't reopen them.

| Label | Who and when | What it says |
|---|---|---|
| Owner-rule exception | The owner, 2026-11-19 09:18 JST; recorded under `OWNER_DECISIONS.md` line 12 (the sub-bullet at line 13) by #748, merged as `8a278a5c` | "the Hermes backend test may run Hermes Agent as a second backend inside the plugin, behind `channels.yorozu.backends.hermes` (off by default) and opted into per conversation. OpenClaw stays the default throughout." Test only; ends at the go/no-go or on 2026-12-31; with no go, the flag and its code are removed. |
| Test approval | The owner, 2026-11-19 08:43 JST | Go with Yorozu's recommendations, and set up the Hermes test install on the mini. |
| D1 | Yorozu (the agent), 2026-11-19 | Test-grade code behind `channels.yorozu.backends.hermes`, off by default. No backend interface. Deleted after the go/no-go unless the outcome is go. |
| D2 | Yorozu (the agent), 2026-11-19 | The OpenClaw session entry stays the record. Only the agent turn is delegated to Hermes. |
| D3 | Yorozu (the agent), 2026-11-19 | The `Idempotency-Key` is `<messageId>:<keyAttempt>`. `keyAttempt` is stored before the POST. It advances only when Hermes itself ended the previous key's run with a temporary failure. Every other rerun replays the same key. |
| D4 | Yorozu (the agent), 2026-11-19 | A denied approval ends only that tool step, with a plain message. The run continues. |
| D5 | Yorozu (the agent), 2026-11-19 | Measure from the plugin logs and the H0 20-task set, with the owner's blind A/B/tie pick per task. |
| Schema in H1 | Yorozu (the agent), 2026-11-19 | `backends` is added to the plugin config schema in H1. |
| Sync A1(b), decision 5 | Sync spec v2 | Cut-off runs are reported with the existing `error run_failed`. No `resendOf`. No automatic requeue after a Gateway restart; the auto-retry rule (`retry` store) is unchanged. |
| Auto-retry rule | The owner, `OWNER_DECISIONS.md:92` | A run that fails for a moment before any reply or tool runs again by itself for about four minutes. |

**Yorozu's reading of the exception** (Yorozu's, not the owner's words; put to the owner as yes/no questions at step 14, which waits for the answers):
- The exception covers the plugin delegating turns to Hermes.
- The Hermes gateway is a third-party agent runtime, like OpenClaw. Yorozu (the agent) installed it and has run it by hand on the mini since 2026-11-19. It isn't Yorozu's own code, so "never Python" doesn't apply to it.
- Yorozu still has no host process: the plugin keeps the host keys and the relay.
- `/new` and `/reset` in an opted-in conversation answer with a notice instead of resetting the session in place. That departs from `OWNER_DECISIONS.md:25` for the test only.

### Glossary

| Term | Meaning |
|---|---|
| Gateway | The OpenClaw Gateway on the Mac mini. The plugin runs inside it. Always capitalised. |
| Hermes gateway | Hermes Agent's own server process (v0.23.1, its API on `127.0.0.1:8652`, home `~/.hermes-yorozu-test`). Always written "Hermes gateway". |
| Hermes | Hermes Agent, the second backend under test. |
| Plugin reload | `startAccount` runs again in the same Gateway process after a `channels.yorozu` change. Not a restart. |
| Restart | The Gateway process stops and starts. |
| Opted-in conversation | A conversation with a route-store entry. Its turns run on Hermes once its OpenClaw session entry exists. |
| Delegated turn | One message of an opted-in conversation, handled by `hermesTurn`. |
| Route store | Keyed-store namespace `backends`: one entry per opted-in conversation, holding its unsettled run ids. |
| Key store | Keyed-store namespace `hermes-keys`: `keyAttempt` per message id (D3). |
| `retryAttempt` | The auto-retry counter: the index into the retry store's 5/15/30/60/120 s schedule, carried by `park` and `runParked`. Starts at 0. |
| `keyAttempt` | D3's counter, the suffix of the `Idempotency-Key`. Starts at 0. Always `keyAttempt ≤ retryAttempt`. |
| Unsettled run | A Hermes run this plugin created and hasn't seen end. Kept in the route-store entry until Hermes reports it ended or 404s. |
| Replay | `POST /v1/runs` with a key Hermes already holds: it returns the existing `run_id` with `replayed: true`. |
| Run ledger, claim, writers, sweep | From sync tickets 01 and 02. The ledger keeps one record per message id (`open`, `queued`, `settled`, `interrupted`). The Hub claims each message before `delivered`. The writers are `runStarted(messageId, awaiting)` and `turnEnded(messageId, parked)`. The once-per-process sweep turns unparked `open` entries an earlier process left into `interrupted`. |
| Interrupted error | Sync's `error {code: "run_failed", message: "interrupted by a host restart"}`. Sync ticket 03 shows it as an Interrupted row with Resend. |
| Release Mac | `.github/workflows/release-mac.yml`. A push to `main` touching `plugins/**` (among others) builds and publishes a Mac beta prerelease from this public repository, so any plugin code merged ships publicly in it. |
| Deploy website | `.github/workflows/deploy-web.yml`. A push to `main` touching `apps/web/**`, `apps/mcp/src/**` (which holds the generated `content.json`) or `apps/mcp/package.json` deploys the production website. |
| ACP | Agent Client Protocol, OpenClaw's way to run an external agent (Option D). |
| Red test, guard | A red test fails on the parent commit and passes after the change. A guard is an existing test that must stay green unmodified. |
| Stop rule | The H0 result that must hold before H1–H3 merge (Operator steps). |
| H0–H3, H6 | Tickets. H4 and H5 were dropped; the numbers are kept so references stay stable. |
| P1–P13 | Test rows. P10 was dropped; the numbers are kept. |

### Blocker resolutions

| EGM item | Resolution |
|---|---|
| A1: retry attempt | `hermesTurn(deps, message, retryAttempt = 0)`. `runParked` passes the stored attempt. Every retry goes through `retry.ts` `park(message, retryAttempt)`, the same function and the same 5/15/30/60/120 s schedule OpenClaw turns use. `park` returns `false` once `retryAttempt` reaches 5, and the turn then reports one `run_failed`. A stopped Hermes therefore gets 6 POSTs in about 4 minutes, then one error; never a 5 s loop. D3's counter is renamed `keyAttempt` so the two can't be confused. |
| A2: standalone typecheck | Only `src/hermes-client.ts` joins `tsconfig.standalone.json`. It imports node built-ins only (`node:http` isn't even needed: it uses the global `fetch`). Everything that touches OpenClaw (config reading, key file, stores, routing, the turn) lives in `src/backends.ts` and `src/hermes-turn.ts`, outside the standalone list. |
| A3: order | One order, settled: (0) this docs PR from `origin/main`; (1) H1 as a draft PR on `feat/sync-restart-plugin` (sync tickets 01+02); (2) H2 on H1; (3) H3 on H2. H3 doesn't wait for sync ticket 03 (the app's Interrupted row and Resend): Hermes needs no change for it, because an interrupted Hermes turn is reported by sync 02's sweep with the existing error, which shipped apps already show as a failed row. The deadline rule watches the only real dependency, the sync plugin PR (Tickets). |
| A4: replay | After a replay, the turn reads the run's status before anything else and acts by status: `completed` → post `output` once; `failed` → `run_failed` with Hermes's error, or a park with the next key when D3's retry rule holds; `cancelled` → `run_failed`; `interrupted` → D3's retry rule; `unknown` → resolve, then by status; still running → attach to its event stream. A replayed run's `output` is posted only for `completed` (fixture 10 shows a failed run's `output` is an error text). "Once" holds through the ledger: the Hub claim drops a repeated message id, only a parked (`open`) entry reruns, a park happens only before any reply, and the reply is followed by `turnEnded`, which settles the entry. |

### Components and data flow

```
device ─relay/direct─▶ Hub ─claim (ledger), delivered─▶ onMessage (channel.ts)
                                                         │ backend off: handleMessage (unchanged)
                                                         ▼ backend on
                                                  routeMessage (hermes-turn.ts)
                         ┌───────────── command notice / OpenClaw (handleMessage)
                         ▼ opted in and session entry exists
                 hermesTurn ─▶ HermesClient (hermes-client.ts) ─HTTP─▶ Hermes gateway 127.0.0.1:8652
                    │  externalTurn (conversation.ts): run_started, typing, tool rows, Live Activity, ledger writers
                    │  park / runParked (retry.ts): the owner's auto-retry schedule
                    ▼
       sendDurableMessageBatch(mirror) ─▶ outbound adapter ─▶ reply event; transcript mirror; push
```

Data kept:
- `backends` (route store): `{since, unsettled: string[]}` per opted-in conversation id.
- `hermes-keys` (key store): `{keyAttempt}` per message id.
- `retry` (existing): parked messages, Hermes and OpenClaw alike.
- `runs`, `run-sweep`, `run-told` (sync): unchanged.
- The OpenClaw transcript: the mirrored user message and reply.

### Hermes API facts

Recorded by `probe.sh` from the running test install with no model provider signed in, 2026-11-19. Fixtures: `transfers/20261119-yorozu-hermes-h0-fixtures/NN-name.{headers,body,sse}`. `index.txt` starts with one line `session_id=… messageId=…`, then one line per fixture, `NN-name METHOD path -> status` (fixture 09 ends `-> exit 0`, and a `run_id=…` line follows 08).

| # | Fact |
|---|---|
| 01 | Without the key, `GET /v1/capabilities` answers 401 `gateway_auth_failed`. |
| 02 | `GET /health` answers 200 `{"status":"ok","platform":"hermes-agent","version":"0.23.1"}`. That it needs no key is from the docs; the probe sent one. |
| 04 | Capabilities include `run_submission`, `runs_idempotency` (`durable: true`, `retention_seconds: 86400`), `run_status`, `run_events_sse`, `run_stop`, `run_approval_response`, `tool_progress_events`, `approval_events` and `run_unknown_resolution`, with endpoints `/v1/runs/{id}/{events,approval,stop,resolve-unknown}`. |
| 06 | Vision is `configured: false`. |
| 08 | `POST /v1/runs` with a client-chosen `session_id` and no prior session answers 202 `{"run_id","status":"started","replayed":false}`. |
| 09 | The event stream sends `: open`, then `id: 0` / `data: {"event":"run.failed","run_id","timestamp","error","completed","partial","interrupted","seq"}`, then `: stream closed`. |
| 10 | `GET /v1/runs/{id}` answers `{"object":"hermes.run","status","session_id","output","usage","admission_id","execution_generation","pending_controls",…}`. For a failed run, `output` is an error text for humans. |
| 11 | The same key and the same body, after the run failed, answers 202 with the same `run_id`, `"status":"failed"`, `"replayed":true` and the header `Idempotency-Replayed: true`. |
| 12 | The same key with a different body answers 409 `idempotency_key_conflict`. |
| 13 | A new key starts a new run. |
| 14 | `GET /api/sessions/yorozu-<convId>` finds the session the run created. |
| 16, 17 | An unknown run (`run_not_found`) or session answers 404. |

From the v0.23.1 docs (`website/docs/user-guide/features/api-server.md` in the test clone):
- **Replay** (lines 489–495). An identical keyed retry returns the original `run_id` "including after a gateway restart and after the run has completed, failed, or been cancelled". A run the gateway couldn't admit "keeps no reservation, so an exact retry is safe". Keys are kept for 24 h after the run's last status update. The docs don't promise exactly-once (lines 646–647).
- **Durable runs** (lines 533, 600–624). A clean shutdown ends a running run as `interrupted`. A run whose gateway died mid-turn reports `unknown`, which isn't terminal: later runs in that session wait until `POST /v1/runs/{id}/resolve-unknown` gets exactly `{admission_id, execution_generation}`. Both are pending step 11.
- **Approvals** (lines 659–677). An answer is `{"request_id": <prompt id>, "execution_generation": n, "choice": …}` from the run's `pending_controls`. Line 665 shows `"once"`. `"deny"` appears only at line 677, in the MCP passage, so `"deny"` here is inferred until step 9 records it.
- **Session leases** (line 499) serialize runs on one session.
- **Why `/v1/runs`.** Chat Completions and Responses also take idempotency keys (lines 79–92). `/v1/runs` was chosen because only it adds run status, the event stream, approval answers and `unknown` resolution.

Pending the owner's Codex sign-in (steps 8–11): a completed run with tools and `usage`; `approval.request` and what `approvals.mode: smart` decides by itself; `run.interrupted` and `unknown`; two runs at once on one session; whether the event stream replays a finished run's events from `seq` 0.

### Config, key file and stores (H1)

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

The URL isn't configurable: it is fixed at `http://127.0.0.1:8652`.

**Help bundle.** `apps/mcp/scripts/generate.ts` (`hostSettings`) fails `--check` for any schema key missing from the Config table in `docs/setup.md`. Documenting the key there would change `apps/mcp/src/content.json` and start Deploy website. So H1 adds a `TEST_ONLY_KEYS = new Set(["backends"])` that `hostSettings` skips, with a comment naming this spec and the 2026-12-31 expiry. `content.json` stays byte-identical. H1 changes no `docs/*.md` and no plugin README. Coder doesn't update `docs/openclaw-channel.md` or the plugin README for test-only code either; this design doc is the reference.

**Resolution.** `resolveHermesBackend(cfg, log)` in `src/backends.ts` runs once per `startAccount`:

| Case | Result | Log (once per `startAccount`) |
|---|---|---|
| `backends` or `backends.hermes` absent | off | none |
| `enabled` isn't `true` | off | `yorozu: hermes backend off: disabled` |
| `keyFile` missing or not starting with `/` (this includes `~/…`) | off | `… off: keyFile must be an absolute path` |
| `fs.stat` fails | off | `… off: keyFile unreadable (<error code>)` |
| not a regular file (`stat` follows a symlink to its target) | off | `… off: keyFile is not a regular file` |
| `(mode & 0o077) !== 0` | off | `… off: keyFile is readable by others` |
| empty after trimming and removing one pair of surrounding `"` or `'` | off | `… off: keyFile is empty` |
| otherwise | on: `{url: new URL("http://127.0.0.1:8652"), key}` | `yorozu: hermes backend on` |

The key is never logged, never put in a URL and never put in an error message. The `<error code>` is `error.code` only (for example `ENOENT`), never the message.

The flag is off from H1 until step 14, whenever a key-file check fails, and at rollback.

**Stores.** `openHermesStores()` in `src/backends.ts` runs only when the backend resolved. With it off, neither namespace is opened, read or written.

| Namespace | Value | Options | Notes |
|---|---|---|---|
| `backends` | `{since: number, unsettled: string[]}` | `{namespace: "backends", maxEntries: 1_000, overflowPolicy: "evict-oldest"}` | Loaded into a module-level `Map` on the first open. A plugin reload reuses the map and doesn't reload it. `routedToHermes` reads the map synchronously. Writes go to the map first, then the store, awaited. |
| `hermes-keys` | `{keyAttempt: number}` | `{namespace: "hermes-keys", maxEntries: 10_000, overflowPolicy: "evict-oldest"}` | Read and written per turn. 10,000 matches the ledger. |

No repository store uses `reject-new`, and its failure shape is unverified. So the cap on opted-in conversations is checked in code: `setRoute` refuses when the map already holds 20 routes (Goal 1 is one conversation at a time; 20 leaves room for mistakes). `unsettled` keeps at most 10 ids; adding an 11th drops the oldest with `yorozu: hermes unsettled list full, dropped <runId>`.

**Wiring in `channel.ts` `startAccount`.** After the sync sweep and before `runParked`:

```ts
const hermes = resolveHermesBackend(ctx.cfg, ctx.log);       // H1
const stores = hermes && (await openHermesStores(ctx.log));  // H1; undefined when off or the store fails
```

H1 stops there; nothing uses them yet. H3 builds the deps and branches `onMessage` and `runParked` (below). When `stores` is undefined, both calls stay exactly as they are at the parent commit.

### Client (H2)

`src/hermes-client.ts` imports node built-ins only and joins `tsconfig.standalone.json`.

- **Loopback only.** `createHermesClient` throws `HermesError("refused")` unless the URL is `http:`, its hostname is `127.0.0.1` or `[::1]`, it has no user info, and its path is `/`. `localhost` is refused, because its address comes from the hosts file.
- **Requests.** Every request sends `Authorization: Bearer <key>` and uses `redirect: "manual"`. A 3xx is an `http` error and is never followed, so the key can't reach another host.
- **Timeouts.** `createRun`, `status`, `deny`, `resolveUnknown` and `stop` each time out after 30 s (`AbortSignal.timeout`, combined with the caller's signal). `events` times out only on connect (30 s) and on idle (60 s with no bytes; comments count as bytes).
- **No retries inside the client.** Every retry is a park (A1).

| Input | `HermesError.kind` |
|---|---|
| `fetch` rejects (`ECONNREFUSED`, `ECONNRESET`, DNS, socket), or the 30 s timeout fires | `unavailable` |
| 429; 503 (`runtime_draining`, `storage_unavailable`) | `unavailable` |
| 401, 403 | `auth` |
| 404 | `not_found` |
| 409 with `error.code` `idempotency_key_conflict` | `conflict` |
| any other non-2xx (400, other 409, 5xx other than 503, 3xx) | `http`, with `status` and `error.code` |
| a 2xx whose JSON lacks the fields the method needs | `http`, `code: "bad_response"` |
| a URL that isn't loopback | `refused` (thrown by `createHermesClient`) |

`unavailable` covers both "never admitted" and "maybe admitted" (a timeout after the request was sent). Both are safe to replay with the same key: Hermes either replays the admitted run or admits it now.

- **Event stream.** `events` parses SSE: `:` lines are comments; `id:` is ignored; consecutive `data:` lines are joined with `\n` and parsed as JSON; an event is yielded at each blank line. A `data` that isn't a JSON object is skipped. The iterator ends after a terminal event (`run.completed`, `run.failed`, `run.cancelled`, `run.interrupted`), on `: stream closed`, when the server closes the connection, or after 60 s idle. After a terminal event it stops reading at once.
- **Fixed bodies.** `deny` sends exactly `{"request_id":<id>,"execution_generation":<n>,"choice":"deny"}`. `resolveUnknown` sends exactly `{"admission_id":<id>,"execution_generation":<n>}`. `stop` sends no body.
- **Errors.** A `HermesError` message holds the method, the path with the run id, the HTTP status and Hermes's `error.code`. It never holds a header or a request body.

### Routing and commands (H3)

`routeMessage(deps, message)` in `src/hermes-turn.ts` decides, using the trimmed text, `routedToHermes(convId)`, and whether the conversation's OpenClaw session entry exists (`liveSessionId(agent, sessionKey)` from `history.ts`, with the thread session key from `resolveThreadSessionKeys`):

| Message | No session entry yet | Entry exists, not opted in | Opted in, entry exists |
|---|---|---|---|
| exactly `/backend hermes` (case-sensitive) | `setRoute`, then `handleMessage` runs it on OpenClaw as a normal first turn, which creates the entry | `setRoute`, then the notice "This conversation now uses Hermes (test). Hermes doesn't see the earlier messages." | Notice: "This conversation already uses Hermes." |
| exactly `/new` or `/reset` | OpenClaw, as today | OpenClaw, as today | Notice: "Start a new conversation for a fresh Hermes session." |
| anything else | OpenClaw | OpenClaw | `hermesTurn` (queued on the conversation's FIFO) |

- **Why the first-message rule.** Only OpenClaw's own turn creates the session entry, and the list, history, pin, archive and titles all read it. Running `/backend hermes` itself as the OpenClaw turn guarantees the turn OpenClaw saw and Hermes didn't is trivial. It also means a Hermes turn always has a session to mirror into.
- **A route without an entry** (the OpenClaw first turn failed) keeps going to OpenClaw until the entry exists.
- **Full route store.** When `setRoute` refuses, the notice is "Too many Hermes test conversations." and nothing else happens.
- **A notice** goes out through `sendDurableMessageBatch` with the same options as `post` in `updates.ts` (`durability: "best_effort"`, `mirror: {sessionKey, agentId, text}`). The user message is mirrored first (as in a turn). A status other than `sent` is logged as `yorozu: hermes notice not sent: <status>`. Then `turnEnded(messageId, false)` settles the ledger entry.
- **No opt-out command.** Turning the flag off returns every conversation to OpenClaw. A message that arrives while an earlier OpenClaw turn of that conversation still runs can overlap with it on Hermes; accepted for the test.
- **Flag off.** Every message goes to `handleMessage` as today, `/backend hermes` included.

### A delegated turn (H3)

`hermesTurn(deps, message, retryAttempt = 0)` runs on a per-conversation promise chain (the FIFO) kept at module level, so a plugin reload doesn't reset it. The FIFO has no cap.

1. **Claimed.** The Hub has claimed the message in the ledger and sent `delivered`. Nothing here repeats that.
2. **Live turn.** `t = externalTurn(deps.turn, message)` registers the live turn (`registerTurn`, which a parked rerun reuses).
3. **Settle earlier runs.** For each id in the route entry's `unsettled`, call `status(id)`:

   | Outcome | Action |
   |---|---|
   | `not_found` | Remove the id. |
   | `completed`, `failed`, `cancelled`, `interrupted` | Remove the id. Its output isn't delivered (Risks). |
   | `unknown` | `resolveUnknown(id, admissionId, generation)`. On 2xx, remove the id. On `http` 409, read `status` once more and remove the id if it is now terminal. Otherwise keep it and log. |
   | any other status (`started`, `running`, `queued`) | Keep it. Log `yorozu: hermes earlier run still running <id>`. The new run waits behind it under Hermes's session lease. |
   | the call throws (`unavailable`, `auth`, `http`) | Keep it. Go on: the POST below meets the same outage and parks. |

4. **Key.** Read the key store. If there is no entry, write `{keyAttempt: 0}` and await it. If that write fails: `t.fail("The Hermes request key couldn't be stored.")` and stop (D3: stored before the POST). Then, only for a new entry, mirror the user message into the transcript (key first, then mirror, so a crash between them loses a history line and never mirrors twice). A failed mirror is logged and the turn goes on.
5. **Body.** `requestBody(message)` builds the body from the stored `Message` and fixed strings only, so every attempt with one key is byte-identical (a different body gets 409):

   ```ts
   const quote = message.replyTo
     ? `> ${message.replyTo.text?.replace(/\s+/g, " ").trim().slice(0, 500) || "(an earlier message)"}`
     : undefined;
   const n = message.attachments?.length ?? 0;
   const note = n ? `[${n} attachment${n === 1 ? "" : "s"} not sent to the Hermes test]` : undefined;
   const input = [quote, message.text, note].filter((part) => part !== undefined && part !== "").join("\n\n");
   return JSON.stringify({ input, session_id: `yorozu-${message.convId}`, instructions: INSTRUCTIONS });
   ```

   `INSTRUCTIONS` is exactly: "You are answering in Yorozu, a chat app. Reply in plain Markdown; tables are fine. There is no message tool and no card format: put everything in your reply." The persona comes from the step-12 import into the Hermes test home; these instructions only add Yorozu's output format per run.
6. **Create.** `createRun({key: `${messageId}:${keyAttempt}`, body})`. On success, add `runId` to `unsettled` (awaited; a failed write is logged). Errors:

   | Error | Action |
   |---|---|
   | `unavailable` | Retry later with the same key. |
   | `auth` | `t.fail("The Hermes test backend refused the key.")` |
   | `conflict`, `http`, `not_found` | `t.fail("Hermes answered <status> <code>.")` and a warning log. |

7. **Replayed run.** If `replayed`, call `status(runId)` first and act by status:

   | Status | Action |
   |---|---|
   | `completed` | Deliver `output` (step 9). |
   | `failed` | The ended-by-Hermes rule with `error`, and `toolSeen` taken from a replay of the run's events (below). Never posts `output`. |
   | `interrupted` | The ended-by-Hermes rule as interrupted, `toolSeen` as for `failed`. |
   | `cancelled` | `t.fail("Hermes stopped this run.")` |
   | `unknown` | `resolveUnknown`, then `status` once more and this table again. A still-`unknown` run: `t.fail("The Hermes run couldn't be resolved.")`. |
   | anything else | Attach (step 8). |
   | `status` throws | `unavailable`: retry later with the same key. Other kinds: `t.fail` as in step 6. |

   **`toolSeen` for a replayed run.** The turn reads `events(runId)` (30 s cap). It counts as "no tool ran" only if that stream starts at `seq` 0, ends with the run's terminal event, and contains no `tool.started`. Anything else counts as "a tool may have run", which means no retry. Step 8 records whether Hermes replays a finished run's events; if it doesn't, a replayed failed run is never retried, and that is the safe side.
8. **Attach.** `t.started()`, then read `events(runId)` and map each event (Turn outcomes). The turn is capped at 30 minutes from `t.started()`. At the cap, call `stop(runId)` (best effort, the id stays unsettled) and `t.fail("The Hermes run took over 30 minutes.")`. If the stream ends without a terminal event, call `status(runId)` once: a terminal status maps by the table in step 7; `unknown` is resolved and then counts as `run.interrupted`; still running means attach again (still under the cap); a throw means `t.fail("Lost contact with the Hermes run; it may still finish.")`, with the id kept in `unsettled`.
9. **Deliver.** Remove `runId` from `unsettled`. An empty `output` is `t.fail("Hermes finished with an empty reply.")`. Otherwise send `output`, plus one line per denied approval, with `sendDurableMessageBatch` using the options of `post` in `updates.ts`. A status other than `sent` is `t.fail("The Hermes reply couldn't be sent: <status>.")`. Then the push (before-code question 4), then `t.done()`, which calls `turnEnded(messageId, false)`. No `maybeTitle` and no `noteFirstMessage`: the entry and its title came from the first OpenClaw turn.

**Retry later** (the only retry path):

```ts
const queued = await deps.park(message, retryAttempt).catch(() => false);   // retry.ts park: false once retryAttempt is 5
if (queued) { t.parked(); log(`yorozu: hermes run parked (retry ${retryAttempt + 1} queued): ${reason}`); }
else t.fail(finalText);   // "The Hermes test backend isn't answering." or "Hermes: <error>"
```

**Ended-by-Hermes rule** (D3, A7). Hermes ended this key's run, and:
- no tool event was seen for this run, and
- either the run failed with `isTemporary(error)` (`retry.ts`), or it was interrupted (including an `unknown` run once resolved).

Then write `{keyAttempt: keyAttempt + 1}` (awaited; if the write fails, `t.fail` with Hermes's error rather than replay a key Hermes already ended) and retry later. Otherwise `t.fail("Hermes: <error, cut to 500 characters>")`, or for an interrupted run, "Hermes stopped this run.".

The permanent error in fixture 09 ("not connected to any AI provider") isn't temporary, so it is reported at once.

### Turn outcomes (H3)

| Situation | Action |
|---|---|
| `tool.started` | `t.tool(callId, name, "running")`. `callId` is `hermes:<runId>:<id>`, where `<id>` is the event's own tool call id if it has one (field name from step 8), else the event's `seq`. |
| `tool.completed` | `t.tool(callId, name, ok ? "done" : "failed")`. Without a tool call id, it matches the oldest open `tool.started` with the same tool name, else the oldest open one. |
| `approval.request` | `status(runId)`, then `deny` for each approval in `pending_controls`. Each denial adds "Denied: <tool> needed an approval Yorozu can't show yet." to the reply, where `<tool>` is the event's `tool` field or "a tool". Hermes's own `tool.completed` ends the tool row. With no pending approval, or if any `deny` throws: `stop(runId)` (best effort) and `t.fail("Hermes asked for an approval that could not be answered.")`. Step 9 can remove this row (Further notes). |
| `message.interim`, `message.delta`, `reasoning.*`, `subagent.*`, keepalives, unknown kinds | Ignored. Each unknown kind is logged once per process. |
| `run.completed` | Deliver its `output`, or the status's `output` if the event has none (step 9). |
| `run.failed` | Remove from `unsettled`. The ended-by-Hermes rule. |
| `run.interrupted` | Remove from `unsettled`. The ended-by-Hermes rule as interrupted. |
| `run.cancelled` | Remove from `unsettled`. `t.fail("Hermes stopped this run.")` |
| The stream ends without a terminal event | Step 8. |

`externalTurn` operations (all idempotent; the first end wins):

| Operation | What it does |
|---|---|
| (creation) | `registerTurn(message)` |
| `started()` | `run_started` once; typing on, repeated every 8 s, capped at 30 min; `runningTurns.set(convId, …)`; ledger `runStarted(messageId, true)` |
| `tool(callId, name, status)` | The `tool` event; on a new `callId`, `owner.steps` and `activityTurn {kind: "step"}` |
| `fail(text)` | `error {code: "run_failed", message: text}`; typing off; `runningTurns` cleared; live turn removed; `activityTurn {kind: "failed"}`; ledger `turnEnded(messageId, false)` |
| `parked()` | typing off; `runningTurns` cleared; live turn and Live Activity job kept; ledger `turnEnded(messageId, true)` |
| `done()` | typing off; `runningTurns` cleared; live turn removed; `activityTurn {kind: "done"}`; ledger `turnEnded(messageId, false)` |
| `toolSeen` | true once `tool()` has run |

`externalTurn` sits beside `handleMessage` in `conversation.ts` and reuses its module-private `registerTurn`, `removeTurn` and `runningTurns`. It copies the roughly 15 lines of `runStarted`/`setTyping`/`tool` instead of extracting them, and drives typing with its own `setInterval` rather than `createTypingCallbacks`, whose dispatcher-less methods are unverified. `handleMessage` isn't changed (D1), and `genui-golden` and `prerun-error` guard that.

### Restarts, reloads and the sync ledger

Hermes turns use the sync ledger exactly as OpenClaw turns do: the same Hub claim, the writers `runStarted` and `turnEnded`, and the same sweep. They never call `dispatchReturned`: each Hermes message is its own run.

| Event | What happens |
|---|---|
| Plugin reload | Nothing is aborted. An in-flight Hermes turn keeps its deps and finishes. `broadcast`, `activityTurn` and `notifyReply` already forward to the current relay host. The module-level route map and FIFO survive. The new `startAccount` resolves the backend again: if it is now off, new messages go to OpenClaw, and parked Hermes messages rerun on OpenClaw. |
| Gateway restart, turn parked | The retry store keeps it. The sweep leaves it `open`. `runParked` reruns it: `routedRerun` finds its key-store entry and calls `hermesTurn` with the stored `retryAttempt` and the same key (replay). |
| Gateway restart, turn not parked | No requeue (sync decision 5). The sweep reads the conversation's OpenClaw session entry. Usually nothing is pending, so the entry becomes `interrupted` and each device gets the interrupted error at its next session open. The Hermes run is orphaned: it may still finish, its output isn't delivered, and it stays in `unsettled` for the next turn's step 3. |
| Restart between the reply and `turnEnded` | The entry is still `open`. The sweep marks it `interrupted`, so a device shows an Interrupted row under a reply it already has. Nothing runs again. The owner need not resend. |
| Hermes gateway clean stop mid-run | `run.interrupted` (pending step 11). With no tool yet: retry with the next key. With a tool: `run_failed`. |
| Hermes gateway `kill -9` mid-run | The stream ends without a terminal event. `status` throws while Hermes is down: `run_failed` "Lost contact…", the id stays unsettled. The next turn resolves it in step 3 once Hermes is back, even after a Gateway restart in between, because the id is in the route store. |
| Gateway and Hermes at once | Not tested on its own (Further notes). |

`runParked` in `channel.ts` dispatches by the key store, not by the current route, so a message OpenClaw parked never reruns on Hermes:

```ts
runParked(abortSignal, (message, attempt) =>
  void (deps ? routedRerun(deps, message, attempt) : handleMessage(turn, message, attempt)));
// routedRerun: (await keys.lookup(message.messageId)) ? hermesTurn(deps, message, attempt) : handleMessage(deps.turn, message, attempt)
```

### Measurement (D5)

**Usage line.** It is written once per delegated turn that got a `run_id`, at its end (delivered, failed, parked or capped):

```
yorozu: hermes turn conv=<convId> message=<messageId> key_attempt=<n> retry=<retryAttempt> run=<runId> outcome=<completed|failed|parked|capped|lost> first_event_ms=<n|-> total_ms=<n> input_tokens=<n|-> output_tokens=<n|-> model=<m|->
```

- `first_event_ms`: from the `createRun` call to the first `data:` event (comments don't count).
- `total_ms`: from the `createRun` call to the end.
- Tokens: from the run status's `usage`.
- `model`: the status's `runtime.model`; the exact field is confirmed at step 8.
- A missing value is `-`. The line never holds message text or the key.

**Latency (P13).** One measure for both backends, from the OpenClaw transcripts: the user message's timestamp to the timestamp of the turn's last assistant message with text (the final answer), before the next user message. The Hermes reply is mirrored at send time (before-code question 3), so the two are comparable.

**The H0 20-task set.** The 20 tasks and both backends' answers from step 13, kept in the owner's notes vault under `Projects/Yorozu/`.

### Module signatures (sketch: names may change, shapes may not)

```ts
// src/hermes-client.ts (H2; node built-ins only; in tsconfig.standalone.json)
export type HermesErrorKind = "unavailable" | "auth" | "not_found" | "conflict" | "http" | "refused";
export class HermesError extends Error {
  constructor(readonly kind: HermesErrorKind, message: string, readonly status?: number, readonly code?: string);
}
export type RunStatus = {
  status: string;                      // "started" | "running" | "completed" | "failed" | "cancelled" | "interrupted" | "unknown" | …
  admissionId?: string; generation?: number;
  output?: string; error?: string; model?: string;
  usage?: { inputTokens?: number; outputTokens?: number };
  pendingControls: { id: string; kind: string; tool?: string }[];
};
export type RunEvent = { event: string; seq: number; data: Record<string, unknown> };
export interface HermesClient {
  createRun(req: { key: string; body: string }): Promise<{ runId: string; status: string; replayed: boolean }>;
  status(runId: string): Promise<RunStatus>;
  events(runId: string, signal?: AbortSignal): AsyncIterable<RunEvent>;
  deny(runId: string, requestId: string, generation: number): Promise<void>;
  resolveUnknown(runId: string, admissionId: string, generation: number): Promise<void>;
  stop(runId: string): Promise<void>;
}
export function createHermesClient(opts: { url: URL; key: string; timeoutMs?: number; idleMs?: number }): HermesClient;

// src/backends.ts (H1; imports OpenClaw types and the runtime store)
export type HermesBackend = { url: URL; key: string };
export type Route = { since: number; unsettled: string[] };
export type KeyRecord = { keyAttempt: number };
export type Store<T> = {
  lookup(key: string): Promise<T | undefined>;
  register(key: string, value: T): Promise<void>;
  delete(key: string): Promise<unknown>;
  entries(): Promise<{ key: string; value: T }[]>;
};
export type HermesStores = {
  routes: {
    routedToHermes(convId: string): boolean;                       // sync, from the module-level map
    setRoute(convId: string): Promise<"set" | "already" | "full">;
    unsettled(convId: string): string[];
    addUnsettled(convId: string, runId: string): Promise<void>;
    removeUnsettled(convId: string, runId: string): Promise<void>;
  };
  keys: Store<KeyRecord>;
};
export function resolveHermesBackend(cfg: OpenClawConfig, log?: Log): HermesBackend | undefined;
export function openHermesStores(log?: Log): Promise<HermesStores | undefined>;   // undefined (logged) if the load fails

// src/conversation.ts (H3; additions only)
export type TurnContext = /* the existing type, now exported */;
export type ExternalTurn = {
  started(): void;
  tool(callId: string, name: string, status: ToolStatus): void;
  fail(text: string): void;
  parked(): void;
  done(): void;
  readonly toolSeen: boolean;
};
export function externalTurn(ctx: TurnContext, message: Message): ExternalTurn;

// src/hermes-turn.ts (H3)
export type HermesDeps = {
  client: HermesClient;
  stores: HermesStores;
  turn: TurnContext;
  park: (message: Message, retryAttempt: number) => Promise<boolean>;   // retry.ts park
  now?: () => number;                                                   // tests
};
export function routeMessage(deps: HermesDeps, message: Message): Promise<void>;
export function routedRerun(deps: HermesDeps, message: Message, retryAttempt: number): Promise<void>;
export function hermesTurn(deps: HermesDeps, message: Message, retryAttempt?: number): Promise<void>;
export function requestBody(message: Message): string;
```

`Log` is `ChannelGatewayContext["log"]`. In H3, `startAccount` builds `deps` once per call from `hermes`, `stores`, `createHermesClient(hermes)`, the existing `turn` object and `park`, then:

```ts
onMessage: (message) => void (deps ? routeMessage(deps, message) : handleMessage(turn, message)),
```

### Tickets, order and gates

**Order.**

| # | PR | Base branch | May open | May merge |
|---|---|---|---|---|
| 0 | `docs: Hermes backend test design` (this file only) | `main` (from `origin/main`) | now | on the owner's approval |
| H1 | `feat(plugin): accept the Hermes test backend config (dormant)` | `feat/sync-restart-plugin` (sync tickets 01+02), as a draft | now | after the sync plugin PR merges to `main` (then retarget to `main`) and the stop rule passes |
| H2 | `feat(plugin): Hermes client with fake-server tests (dormant)` | H1's branch, as a draft | after H1 opens | after H1 merges and H0 steps 8–11 replaced every `test.todo` |
| H3 | `feat(plugin): run an opted-in conversation's turns on Hermes` | H2's branch, as a draft | after H2 opens | after H2 merges, step 9 settled approvals, and the before-code answers are in the PR |
| H6 | The test run, the report, and on a no-go the removal PRs | — | after H3 merges and step 14 | — |

The critical path is: sync plugin PR (01+02) merges → H1 → H2 → H3 merge → step 14 → real use → report by 2026-12-31. H3 doesn't wait for sync ticket 03.

**Deadline.** If the sync plugin PR hasn't merged by 2026-12-10, real use can't run long enough before the exception ends. Yorozu (the agent) then tells the owner, who decides whether to extend.

**Every merge** to `main` needs the owner's approval in the owner's own words.

**Commits.** Each PR's first commit holds only red tests, and the PR body names each one and its failure on the parent. Conventional Commits, signed.

**Release and deploy triggers** (on push to `main`; merges between stacked branches trigger nothing):

| PR | Paths | Release Mac | Deploy website | Notes |
|---|---|---|---|---|
| 0 | `docs/designs/hermes-backend.md` | no | no | `generate.ts` reads only top-level `docs/*.md`, so `content.json` doesn't change. |
| H1 | `plugins/**`, `apps/mcp/scripts/generate.ts` | yes | no | Needs the `apps/mcp/scripts` change for `TEST_ONLY_KEYS`; `apps/mcp/**` is outside Release Mac, and `scripts/` is outside Deploy website. No `docs/*.md`, no README. |
| H2 | `plugins/**` | yes | no | — |
| H3 | `plugins/**` | yes | no | — |

**H1: config and stores (dormant).**

| Action | File | What |
|---|---|---|
| Modify | `plugins/openclaw-yorozu/openclaw.plugin.json` | the `backends` property |
| Create | `plugins/openclaw-yorozu/src/backends.ts` | `resolveHermesBackend`, `openHermesStores` |
| Modify | `plugins/openclaw-yorozu/src/channel.ts` | `startAccount`: resolve, then open the stores only when on; `YorozuConfig` gains `backends?: { hermes?: { enabled?: boolean; keyFile?: string } }` |
| Modify | `apps/mcp/scripts/generate.ts` | `TEST_ONLY_KEYS`, skipped by `hostSettings` |
| Create | `plugins/openclaw-yorozu/test/backends-config.test.ts` | red tests |

Red tests:
1. The manifest has `backends.hermes` with `additionalProperties: false` at both levels, and `enabled` defaults to `false`.
2. Flag absent: `resolveHermesBackend` returns undefined and logs nothing. `startAccount` (on the `presentations.test.ts` base) opens neither `backends` nor `hermes-keys` (`host.stores` has neither), and a stubbed global `fetch` is never called.
3. `enabled: false`: one `hermes backend off: disabled`.
4. Each refusal with its reason: a relative path, a `~/` path, a missing file, a directory, mode 0644, an empty key, a key of only quotes.
5. Mode 0600 and 0400 are accepted. A quoted key loses its quotes. The URL is `http://127.0.0.1:8652/`.
6. The key text never appears in any log line from cases 3–5.
7. With the flag on: both namespaces opened; `setRoute` then `routedToHermes` is true; a second `openHermesStores` (reload) keeps the map; the 21st `setRoute` answers `"full"`; `unsettled` keeps 10.

Guards: `hub-session`, `prerun-error`, `genui-golden`, `presentations` unmodified.

**H2: client (dormant).**

| Action | File | What |
|---|---|---|
| Create | `plugins/openclaw-yorozu/src/hermes-client.ts` | the client |
| Modify | `plugins/openclaw-yorozu/tsconfig.standalone.json` | add `src/hermes-client.ts` to `include` (nothing else) |
| Create | `plugins/openclaw-yorozu/test/fixtures/hermes-0.23.1/` | a byte-exact copy of `transfers/20261119-yorozu-hermes-h0-fixtures/` without `probe.sh`, plus a `README.md` naming the source and date. Each body's size is checked against its `Content-Length`. |
| Create | `plugins/openclaw-yorozu/test/hermes-server.ts` | a `node:http` fake Hermes on `127.0.0.1:0` that plays an ordered script per test: method, path and `Idempotency-Key` → a fixture, or an inline response (429, 503 with `Retry-After`, 307, a hang, a reset socket, a mid-stream close). It records each request's headers and body. Not a `*.test.ts`, so the glob doesn't run it. |
| Create | `plugins/openclaw-yorozu/test/hermes-client.test.ts` | red tests |

Red tests:
1. `createHermesClient` refuses `http://192.168.1.2:8652`, `http://localhost:8652`, `https://127.0.0.1:8652`, `http://user:pw@127.0.0.1:8652`, and `http://example.com`. It accepts `http://127.0.0.1:<port>` and `http://[::1]:<port>`.
2. Each error-kind row, one test each. `unavailable` covers a closed port, 429, 503, a hang past `timeoutMs` and a reset socket.
3. A 307 to another server is `http`, and the other server gets no request.
4. `createRun` sends the `Idempotency-Key` and the body byte for byte. Fixture 11 parses as `{replayed: true, status: "failed"}`. The same key sent twice reaches the server identically twice.
5. `status` parses fixture 10, including `admissionId`, `generation` and empty `pendingControls`. Fixture 16 is `not_found`.
6. `events` on fixture 09 yields one `run.failed` with `seq` 0 and ends. It ignores comments, joins multi-line `data`, skips non-JSON `data`, ends on a server close without `: stream closed`, and ends after `idleMs` with no bytes.
7. The exact bodies of `deny` and `resolveUnknown`; `stop` has none.
8. For every error kind, neither `String(error)` nor `error.stack` contains the key.
9. Scrub: no fixture file contains `Authorization` or matches `/Bearer [A-Za-z0-9]/`.
10. `test.todo` for the step 8–11 shapes (a completed run with tools and `usage`, `approval.request`, `run.interrupted`, `unknown` and `resolve-unknown`, an event replay of a finished run). Each is replaced by a fixture test before H2 merges.

Guards: the standalone typecheck passes with `hermes-client.ts` included.

**H3: delegated turns.**

Before code, Coder answers these by reading `~/openclaw` (2026.9.8, read only) and writes the answers in the PR. If an answer is "no" or unclear, Coder stops and reports to Yorozu (the agent) before coding.

| # | Question | If yes | If no |
|---|---|---|---|
| 1 | Is `appendSessionTranscriptMessageByIdentity` (`openclaw/plugin-sdk/session-transcript-runtime`) the call for a user message with `__openclaw.transport.messageId` and `provenance.kind: "external_user"`, and does it leave an existing session entry unchanged? | use it for the mirror | stop and report |
| 2 | Does an appended user message leave OpenClaw with no pending turn (no run, no restart-recovery marker)? | as designed | stop and report |
| 3 | Is a `sendDurableMessageBatch` mirror stamped at send time? | P13 as designed | P13 uses the plugin log's `total_ms` for Hermes, and that is stated in the report |
| 4 | Does `sendDurableMessageBatch` run the outbound adapter's `afterDeliverPayload`, which sends the push? | no push call in `hermesTurn` | call `notifyReply(convId, firstMessageId, text)` once after a `sent` |
| 5 | Does OpenClaw pass `/backend hermes` to the agent as text (unknown slash commands pass through, `OWNER_DECISIONS.md:25`)? | as designed | stop and report |

| Action | File | What |
|---|---|---|
| Create | `plugins/openclaw-yorozu/src/hermes-turn.ts` | `routeMessage`, `routedRerun`, `hermesTurn`, `requestBody`, the FIFO |
| Modify | `plugins/openclaw-yorozu/src/conversation.ts` | export `TurnContext`; add `externalTurn` beside `handleMessage` |
| Modify | `plugins/openclaw-yorozu/src/channel.ts` | build `deps`; branch `onMessage` and `runParked` |
| Modify | `plugins/openclaw-yorozu/test/genui-host.js` | recording stubs for `sendDurableMessageBatch` (returns `{status: "sent"}` unless told otherwise) and `appendSessionTranscriptMessageByIdentity`; the ledger writer recorder if sync 01's fake lacks one |
| Modify | `plugins/openclaw-yorozu/test/genui-hooks.ts` | map the new SDK modules to `genui-host.js` |
| Create | `plugins/openclaw-yorozu/test/hermes-turn.test.ts` | red tests |

The seam is the highest available. `hermesTurn` runs with the **real** client against `hermes-server.ts`, the `genui-host.js` stand-in for OpenClaw, and the **real** `retry.ts` loaded through sync ticket 02's resolve hook with `node:test` mock timers.

Red tests:
1. The routing table: one test per cell (9).
2. Flag absent: `onMessage` and `runParked` reach `handleMessage`, the fake server gets no request, and neither store namespace exists.
3. A plain turn: `run_started` once; typing on, then off; the reply sent once through `sendDurableMessageBatch` with `mirror`; the user message mirrored once; `activityTurn` `done`; ledger `runStarted` then `turnEnded(false)`; one usage line; exactly one push.
4. The key-store row exists when the fake server receives the POST.
5. Bounded retries: the fake server refuses every connection. Exactly 6 POSTs, at about 0, 5, 20, 50, 110 and 230 s (the 5/15/30/60/120 s delays added up, each plus up to one 5 s tick), all with `Idempotency-Key` `<id>:0` and the same body. Then exactly one `run_failed`, and no 7th request after another 10 minutes of mock time.
6. A timeout after admission, then a rerun: the second POST carries the same key, the server replays, the turn attaches, and the server saw one run.
7. Replay `completed`: one reply with the run's `output`.
8. Replay `failed` (fixtures 11 and 10): `run_failed` with Hermes's error. No `reply` event and no `sendDurableMessageBatch` call, so fixture 10's `output` text is never posted.
9. Replay `failed` with a temporary error and an event replay from `seq` 0 with no tool: the next POST uses `:1`, through `park`. The same with a tool, or without an event replay: `run_failed`, no retry.
10. Replay `cancelled`: `run_failed`. Replay `running`: attaches and delivers. Replay `unknown`: `resolveUnknown` with the exact body, then mapped.
11. `run.failed` temporary (`rate limit`) with no tool: key `:1`, parked, and the rerun answers. The same after a `tool.started`: `run_failed`. Fixture 09's permanent error: `run_failed` at once.
12. `run.interrupted` with no tool: key `:1` and parked. With a tool: `run_failed`.
13. Stream end without a terminal event: status `running` re-attaches; `unknown` resolves, then counts as interrupted; a throw fails with the id kept in `unsettled`.
14. `kill -9`, then a Gateway restart (fresh module state over the same stores), then the next message: step 3 calls `resolveUnknown(<admission_id>, <generation>)` from the route store, and the new run runs.
15. Approval: `deny` with the exact body; the "Denied:" line ends the reply; the run completes. No pending control: `stop`, then `run_failed`. A failing `deny`: `stop`, then `run_failed`.
16. `requestBody`: byte-identical across reruns; the quote line with text, with multi-line text, and without text; the attachments note with 1 and with 3; text only.
17. The 30 min cap: `stop`, then `run_failed`, with the id kept in `unsettled`.
18. Plugin reload mid-turn: a second `startAccount` while the stream is open; the reply is still delivered once.
19. Sync interplay: an unparked Hermes turn across a simulated restart is marked `interrupted` by the sweep and never rerun; a parked one reruns through `routedRerun` with the same key.
20. A message OpenClaw parked reruns on OpenClaw even after its conversation was opted in.
21. No log line from any test contains the key.

Guards: `genui-golden`, `prerun-error`, `hub-session` and the sync 01/02 tests, unmodified.

### Operator steps (H0 and enablement)

Yorozu (the agent) runs every step on the Mac mini, except where it says the owner. Coder runs none of them.

`H` stands for `HERMES_HOME=~/.hermes-yorozu-test ~/.hermes-yorozu-test/hermes-agent/.hermes/bin/hermes`.

**Forbidden commands:** `hermes` with any other home or without `HERMES_HOME`; `hermes claw cleanup`; `hermes claw migrate`; any `--migrate-secrets`. `import-agent` is allowed only as written in step 12 (`docs/history/hermes-integration.md` explains the risk).

**Start and stop of the hand-started Hermes gateway** (until step 14):
- Start: `mkdir -p ~/.hermes-yorozu-test/logs`, then `H gateway run >> ~/.hermes-yorozu-test/logs/hand.log 2>&1 &`. Check the subcommand with `H gateway --help` first.
- Stop: `kill $(lsof -tiTCP:8652 -sTCP:LISTEN)`. Hard stop for step 11: `kill -9` instead. Check with `lsof -iTCP:8652`.

**`probe.sh`** lives in the box handover fixtures folder, next to `index.txt`. Copy it to `~/.hermes-yorozu-test/probe/` on the mini and run it from there. Each new recording takes the next free `NN` and adds a line to `index.txt`. Recordings go back to the handover folder, scrubbed (the H2 scrub test checks).

**Done (2026-11-19):**
1. A separate clone at `3b42157858`, home `~/.hermes-yorozu-test`, `cli.expose_on_path: false`.
2. The API server only, on `127.0.0.1:8652`, with its key in the home's `.env` (0600) and `auth.adopt_external_logins: false`. No messaging platform.
3. OpenClaw unchanged (`~/.openclaw/openclaw.json` mtime and sha256 recorded in the rollback note).
4. Fixtures 01–17.

**Pending:**

7. **The owner: Codex sign-in** (about 5 minutes; the code lasts 15 minutes). The owner signs in with the same ChatGPT account OpenClaw uses, so the two share its quota.
   1. In Terminal on the mini: `HERMES_HOME=~/.hermes-yorozu-test ~/.hermes-yorozu-test/hermes-agent/.hermes/bin/hermes model`.
   2. Choose OpenAI Codex, and answer **N** to importing the Codex CLI tokens.
   3. Open `https://auth.openai.com/codex/device`, enter the code, sign in.
   4. Yorozu (the agent) checks with `H auth status openai-codex`.
8. **A completed run with a tool.** POST a run with `session_id` `yorozu-h0-probe-8` and input "Run `date` in the terminal and tell me the output." Record the event stream, the status (with `usage` and `runtime`), the tool events' fields (including any tool call id), and the event stream fetched again after the run finished (does it replay from `seq` 0?).
9. **Approvals.**
   1. Set `agent.disabled_toolsets: [cronjob]` in the test home's `config.yaml`.
   2. Send each command of a fixed list of 10 as its own run (session `yorozu-h0-probe-9-<n>`): `ls ~`, `cat /etc/hosts`, `mkdir -p /tmp/yorozu-h0 && touch /tmp/yorozu-h0/a`, `rm -rf /tmp/yorozu-h0`, `curl -sI https://example.com`, `git -C ~/.hermes-yorozu-test/hermes-agent status`, `chmod 777 /tmp/yorozu-h0-x`, `sudo -n true`, `osascript -e 'display notification "h0"'`, `kill -0 1`. For each, record whether `approval.request` came. The list is what `smart` approves by itself.
   3. For one that asked: record `approval.request`, the status's `pending_controls`, the `deny` exchange, and what the run did next.
   4. Check whether `approvals.mode` has a setting that denies every escalation server-side while the run continues. Write the result; H3 uses it (Further notes).
10. **Two runs at once on one session.** Two POSTs with different keys and the same `session_id`, under 1 s apart. Record whether the second waits, fails or runs alongside. For information only: H3's FIFO serializes either way.
11. **Interrupted and unknown runs.** Start a run with a long tool ("Run `sleep 60`, then say done."), stop the Hermes gateway cleanly mid-run, and record `run.interrupted`. Repeat with `kill -9`, start Hermes again, and record `unknown`, a second run on that session waiting, and `resolve-unknown`.
12. **Persona.**
    1. `H plugins install agent-importers`.
    2. `H import-agent openclaw --dry-run`, and confirm from its output that it only reads `~/.openclaw`.
    3. Review each MCP server it would import (name, command, `trust`). Drop any that writes outside the Hermes home.
    4. `H import-agent openclaw` (without `--migrate-secrets`).
    5. Check that `~/.openclaw/openclaw.json`'s mtime and sha256 still match the rollback note.
13. **The quality batch (P12).** Run it while the owner isn't using Yorozu.
    1. Yorozu (the agent) picks 20 read-only prompts (no sends, no writes) from the owner's past Yorozu conversations, and lists them in the vault note first.
    2. Hermes answers each in a fresh session `yorozu-p12-<n>`, with the fixed `INSTRUCTIONS`.
    3. OpenClaw answers each in a throwaway session that no Yorozu conversation uses, through OpenClaw's CLI agent command (check the exact form with `openclaw agent --help`; never a Yorozu conversation).
    4. Each pair is stripped of backend names, model names and tool traces, and put as A and B by a coin flip. The key stays in a separate file. The owner sees one vault note with 20 sections and writes A, B or tie for each.
14. **Enablement.** It runs after H3 merges, with the owner's approval of these yes/no questions, asked together:
    - Edit the OpenClaw config to turn on `channels.yorozu.backends.hermes` (and restart the Gateway if needed)?
    - Run the Hermes gateway under launchd (label `local.hermes-yorozu-test`, `KeepAlive: true`) instead of by hand, as Hermes has run since 2026-11-19?
    - Is Yorozu's reading of the exception right: Hermes's gateway (Python) runs as a third-party runtime, outside "never Python"?
    - In an opted-in conversation, `/new` and `/reset` answer with a notice instead of resetting in place?

    A "no" to the second or third question keeps Hermes hand-started, or stops the test, as the owner says. Then:
    1. Check that the Gateway's plugin is at the H3 merge or later (`openclaw plugins list`).
    2. `cd ~/.hermes-yorozu-test && (umask 077; grep '^API_SERVER_KEY=' .env | cut -d= -f2- > yorozu-plugin.key)`.
    3. `cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak-hermes-test`.
    4. `openclaw config set channels.yorozu.backends.hermes.keyFile ~/.hermes-yorozu-test/yorozu-plugin.key` (expanded to an absolute path), then `openclaw config set channels.yorozu.backends.hermes.enabled true`. Check that the Gateway log shows `yorozu: hermes backend on`.
    5. Write `~/Library/LaunchAgents/local.hermes-yorozu-test.plist`: `Label` `local.hermes-yorozu-test`; `ProgramArguments` `[<home>/hermes-agent/.hermes/bin/hermes, gateway, run]`; `EnvironmentVariables` `{HERMES_HOME: <home>}`; `KeepAlive` true; `StandardOutPath` and `StandardErrorPath` `<home>/logs/launchd.log`.
    6. Stop the hand-started Hermes gateway, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.hermes-yorozu-test.plist`.
    7. Check with `openclaw config get channels.yorozu.backends` and `launchctl print gui/$(id -u)/local.hermes-yorozu-test`.

**Stop rule.** H1–H3 don't merge, and the result goes to the owner as a no-go, if either of these holds:
- by step 11, Hermes hasn't completed a run with a tool on the Codex sign-in;
- in step 13, Hermes is preferred in fewer than 5 of the 20 pairs.

### Test plan and go/no-go report (H6)

| Row | Scenario | Where | Pass |
|---|---|---|---|
| P1 | Plain chat over the relay and the direct listener | The owner's devices | ✓✓, then the reply, the same on both devices |
| P2 | A long tool run (about 5 min) | The owner's devices | Tool rows and Live Activity steps update; typing never lapses |
| P3 | A device offline during the turn | The owner's devices | The reply shows after catch-up, once, in order |
| P4 | Two devices, sending from one | The owner's devices | The other shows the message and the reply, no duplicates |
| P5 | Hermes stopped, and separately `kill -9`, mid-turn | Test home + a device | No tool yet and Hermes back within about 4 min: the reply arrives once. Otherwise one error row, and no stuck typing. The next message in that conversation runs. |
| P6 | A Gateway restart mid-turn | H3 test 19 | Unparked: the entry is `interrupted`, nothing reruns. Parked: the rerun replays the same key (one Hermes run). |
| P7 | The same message twice; a timeout after admission; a rerun after a park | H2/H3 tests | One Hermes run per key; the key advances only by the ended-by-Hermes rule |
| P8 | Rename, pin, archive, delete; `/new` | The owner's devices | As on OpenClaw; `/new` gets the notice |
| P9 | History after reinstalling the app | The owner's device | The full conversation, including the `/backend hermes` line |
| P11 | A command that needs approval | H3 test 15 + one real check after step 9 | Denied with the plain line; the run continues |
| P12 | Quality on the 20 tasks | Step 13 | Reported as Hermes / OpenClaw / tie counts |
| P13 | Latency and tokens | Transcripts and usage lines | p50 and p90 for both backends; tokens per Hermes turn |

- **Real use** starts after step 14. Only turns sent while the Hermes gateway was up count. Turns cut off by a Gateway restart are excluded for both backends.
- **Restarts.** Gateway restarts from `~/.openclaw/logs/gateway-restart.log`; Hermes restarts from the `runs = N` line of `launchctl print gui/$(id -u)/local.hermes-yorozu-test`.
- **Quota.** Yorozu (the agent) checks `rg -i 'rate.?limit|\b429\b' ~/.openclaw/logs/` daily. Any OpenClaw 429 stops the P12 batch, and Yorozu (the agent) asks the owner to stop sending in opted-in conversations. The flag stays on; no config edit.
- **Blame.** A double run or lost reply is Hermes's when the plugin log shows one `createRun` per key and Hermes ran it twice or sent no terminal event. Otherwise it is the plugin's.
- **Spend.** At the go/no-go the owner checks the ChatGPT account: no new subscription or billing line.
- **Report.** Yorozu (the agent) writes it to the vault under `Projects/Yorozu/`: P1–P9, P11 pass or fail; double runs and lost replies with blame; the P12 counts; P13 p50 and p90; restart counts; spend; tool gaps (OpenClaw tools Hermes lacked, from the transcripts).
- **Outcome.** At n = 20 the quality numbers are indicative only, so the owner decides: go (the Yorozu backend switch, which opens ADR-H4), extend (moves the go/no-go date; the code stays until then, and a date past 2026-12-31 needs a new owner exception), or no-go. One rule is fixed: any double run or lost reply blamed on Hermes is a no-go. With no decision by 2026-12-31, the outcome is no-go.

## Testing decisions

- **Seams, highest first.**
  - H3: `hermesTurn` and `routeMessage` with the real client against the `node:http` fake Hermes, the `genui-host.js` stand-in for OpenClaw, and the real retry module with mock timers (sync ticket 02's hook).
  - H2: the client against the same fake server, from the recorded fixtures.
  - H1: `resolveHermesBackend` on real temp files, and `startAccount` on the `presentations.test.ts` base.
- **What a good test checks:** the HTTP requests the fake Hermes received (method, path, key, body), the events each device receives, ledger writer calls, the store rows, log lines. Not private maps.
- **Prior art:** `prerun-error` and `genui-golden` (conversation turns on the stand-in host); `presentations.test.ts` (`startAccount`); `relay-integration` (a real local server in a test); the sync 01/02 tests (ledger and retry hook).
- **Acceptance commands** (Node 26, as CI):
  - `node --test 'plugins/openclaw-yorozu/test/*.test.ts'` from the repository root (the full plugin suite, as `checks.yml`).
  - `tsc -p plugins/openclaw-yorozu/tsconfig.standalone.json` with TypeScript 7.0.2 and `@types/node` 26.6.2 (as `plugin-typecheck.yml`).
  - The full plugin typecheck against the OpenClaw checkout ([plugin README](../../plugins/openclaw-yorozu/README.md#typecheck)), with no errors in plugin files.
  - H1: `node apps/mcp/scripts/generate.ts --check` passes, and `git diff --exit-code apps/mcp/src/content.json` after `node apps/mcp/scripts/generate.ts`.
  - Every PR: `git diff --stat` shows no change to `genui-golden.test.ts`, `prerun-error.test.ts` or `hub-session.test.ts`.

## Alternatives considered

- **Option A: a Hermes platform plugin (Python) as a second Yorozu host.** It ports the Noise sessions, the relay host, history and push to Python, needs a re-pair, and puts Yorozu code in Python.
- **Option C: a standalone Yorozu host that talks to Hermes.** It is the retirement shape and breaks "No Mac host process". Considered only after a go (ADR-H4).
- **Option D: OpenClaw's agent pointed at Hermes over ACP.** It moves one OpenClaw agent, so it moves all of Yorozu unless OpenClaw can bind ACP per thread. That source read wasn't done (Review dispositions, A9).
- **D1 alternative: a backend interface.** More code for a test that is deleted unless it goes.
- **D2 alternative: a Hermes-only conversation record.** The list, pin, archive and history would all need new code.
- **D3 alternative: a fresh key per attempt.** A timeout after admission would run the work twice.
- **D4 alternative: stop the run on a denied approval** (the earlier Yorozu-on-Hermes design, `docs/history/hermes-integration.md`). One gated tool would lose the whole answer.
- **D5 alternative: fixed pass bars.** At n = 20 the numbers can't carry a bar; the owner decides.
- **Seeding the Hermes session with OpenClaw's history.** The first-message rule makes the OpenClaw-only turn trivial instead.
- **Aborting Hermes turns on a plugin reload** (spec v4). It drops answers OpenClaw turns already keep across a reload.
- **The unsettled run id in memory or in `hermes-keys`** (spec v4). Lost on a restart, it could block a conversation behind an `unknown` run for good.
- **Extracting `turnSignals` from `handleMessage`** (spec v4). It changes the default path for test code; `externalTurn` copies about 15 lines instead.
- **A requeue of unacted Hermes turns after a Gateway restart** (spec v4 §6.6). Withdrawn by sync decision 5.
- **`reject-new` for the route store.** Unused in the repository and its failure shape unverified; a count check in code is plain.
- **Documenting `backends` in `docs/setup.md`.** It would start Deploy website for a test-only key; `TEST_ONLY_KEYS` avoids it.

## Risks

| Risk | Mitigation or check |
|---|---|
| Hermes's terminal, file and browser tools run as the owner's macOS user. They can read `~/.openclaw` and the key file, and web pages can inject prompts. | The same exposure OpenClaw's own exec tools have, but only for what `approvals.mode: smart` approves by itself, which step 9 records; the plugin denies every escalation that asks. `cronjob` is disabled. If step 9 shows `smart` approves something OpenClaw would ask about, Yorozu (the agent) reports it before step 14. |
| An orphaned Hermes run after a Gateway restart keeps going, its output is never delivered, and a Resend repeats its work and tool side effects. The owner may not know Hermes is still running when tapping Resend. | Recorded cost, as the sync spec accepts "Resend repeats an action". The next turn's step 3 sees the orphan. Re-attaching by stored key is an ADR-H4 benefit. Counted in the report. |
| A replayed failed run is retried after a tool already ran in it. | Retried only when an event replay from `seq` 0 shows no tool; otherwise reported. |
| A restart between the reply and `turnEnded` shows an Interrupted row under a delivered reply. | Accepted, as the sync spec does; no double send, because nothing is requeued. |
| A Gateway restart while the OpenClaw session entry still carries `abortedLastRun` from the first OpenClaw turn. | The sync classifier reads "recovery pending": no Interrupted row, and the device waits out the 10-minute window. Fail-safe direction. |
| Imported MCP servers | Reviewed one by one at step 12; no secrets migrated. |
| The shared ChatGPT quota | The daily 429 check (Test plan). |
| Dormant code in a public beta (Release Mac publishes every plugin merge) | Nothing merges before the stop rule; the flag is off by default; the flag-absent test proves no Hermes path runs. |
| The sync work slips | The 2026-12-10 deadline rule. |
| Hermes and OpenClaw histories drift | The first-message rule; `/new` and `/reset` answer with a notice. |
| Reply ids differ from the transcript ids | The app's existing text match applies, as for cron deliveries (unverified for Hermes replies; checked in P9). |
| The key leaks | Loopback only, no redirects, never logged or put in an error; tests 8 (H2) and 21 (H3). |
| The `.env` key format differs from what step 14.2 expects | The reader strips one pair of quotes; a wrong key fails with `auth` and "refused the key". |

## Out of scope

- OpenClaw retirement (ADR-H4).
- Production-grade code: no backend interface, no general multi-backend support (D1).
- Cards, Automations (cron), reactions and image input on Hermes (ADR-H5). Reactions are stored as today and not passed on.
- OpenClaw's own tools (iMessage, Meet, Signal and the owner's other tools) on Hermes. Gaps go in the report.
- An approval screen in the app.
- Any relay, app or wire change.
- An opt-out command.
- Release, TestFlight and merges: draft PRs only, until the gates in Tickets.

## Further notes

- **Rollback (also the no-go clean-up).** In this order:
  1. Turn the flag off: `openclaw config set channels.yorozu.backends.hermes.enabled false`, or restore `~/.openclaw/openclaw.json.bak-hermes-test`. This edits the OpenClaw config, so it needs the owner's approval. Every conversation is back on OpenClaw at the reload.
  2. Before any revert of H1 merges: `openclaw config unset channels.yorozu.backends`. Otherwise the leftover key fails the restored schema's `additionalProperties: false`.
  3. `launchctl bootout gui/$(id -u)/local.hermes-yorozu-test`, and delete the plist.
  4. Stop the Hermes gateway, then `rm -rf ~/.hermes-yorozu-test` (this also removes the key file).
  5. Revoke the Hermes session in ChatGPT's connected apps.
  6. Revert H3, H2, H1 (including `TEST_ONLY_KEYS`), or close them if unmerged.

  Left behind, inert: the keyed-store namespaces `backends` and `hermes-keys`, and the mirrored messages in transcripts, which are normal history. The rollback note for the H0 install is in the owner's vault (`Projects/Yorozu/2026-11-19 Hermes H0 test install rollback`).
- **Approvals, decided at step 9.** If `approvals.mode` can deny every escalation server-side while the run continues, H3 drops `deny`, the `approval.request` row and the "Denied:" line; P11 then passes when the tool step fails and the run continues with Hermes's own message (D4 still holds). Otherwise H3 builds the plugin-side deny as specified. H3's PR states which.
- **Unverified.**
  - H0 steps 8–13.
  - The five before-code questions.
  - Per-thread ACP routing in OpenClaw (Option D).
  - The Codex plan's limits with two agents on it.
  - The Gateway and Hermes failing at the same moment.
  - `gateway run`, `agent.disabled_toolsets`, `import-agent` and `plugins install` in the test home.
  - Replay after a Gateway restart (documented, not recorded).
  - Whether the app's text match pairs a Hermes reply with its transcript line.
- **ADRs.** ADR-H1 (D1, accepted): a flagged branch in the plugin. ADR-H2 (accepted): Hermes runs from its own clone and home, on loopback, with no messaging platforms. ADR-H3 (D3, accepted): the key is `messageId:keyAttempt`, stored before the POST, and advanced only when Hermes itself ended the run with a temporary failure. ADR-H4 (deferred): OpenClaw retirement, only after a go, keeping every pairing. ADR-H5 (accepted): Hermes conversations are text only. ADR-H6 (D2, accepted): the OpenClaw session is the record.
- **Owner's v1 answers** (2026-11-19 08:43 JST, "as recommended"): "replacement" means the Yorozu backend switch; per-conversation opt-in on real devices; the Codex sign-in with no new spend; import the persona without secrets; deny approvals with a plain message (D4); the owner rules stay as they are until the go/no-go, apart from the 09:18 exception.

## Review dispositions

Every 🔴 and 🟡 item of EGM round 4 is fixed as below unless marked CONTEST.

- A1: fixed (Blocker resolutions; `retryAttempt` and `keyAttempt`; H3 test 5).
- A2: fixed (only `hermes-client.ts` joins the standalone list).
- A3: fixed (Tickets: one order table, one gate per ticket, the 2026-12-10 rule on the sync plugin PR; H3 no longer waits for sync 03; P6 is a sync-02 sweep test).
- A4: fixed (step 7 table; H3 tests 7–10).
- A5: fixed (no abort on reload; H3 test 18).
- A6: fixed (`unsettled` in the route store; step 3 outcomes; 30 s timeouts; H3 test 14).
- A7: fixed (the ended-by-Hermes rule with `isTemporary`; P5).
- A8: fixed (the first-message rule; `/new` departure in Yorozu's reading; before-code question 5; Hermes routing needs an entry, so the mirror always has a session).
- A9: CONTEST - the direction is final (Option B, approved by the owner on 2026-11-19), and the Option D read can't change H1–H3 without reopening it. The rest is done: the P13 reason is dropped from Option D, the stop rule gates every merge on P12, and the Appendix B claim "the owner asked to start them" is gone (building the drafts first is Coder's call under the brief).
- A10: fixed (Risks: orphan runs and Resend repeats; no "runs twice never" claim; exactly-once disclaimer; ADR-H4 benefit).
- A11: fixed differently: with no requeue after a restart (sync decision 5), the reply can't be sent twice; the remaining gap (an Interrupted row under a delivered reply) is in Risks.
- A12: fixed (step 9 decides; citation fixed and `deny` marked inferred; a failed `deny` stops and fails; the tool-exposure risk is conditional on step 9).
- A13: fixed (`externalTurn` beside `handleMessage`; no H1 stub; types in Module signatures; `fail` sends `activityTurn failed`; typing by interval). T2's `holdTurn` isn't in sync spec v2, so it isn't used.
- A14: fixed (route-store signatures and module-level cache; count cap instead of `reject-new`; `openHermesStores` opens both).
- A15: fixed (`requestBody`).
- A16: fixed (before-code table with follow-ups; push question; `maybeTitle` dropped).
- A17: fixed (H3 Create/Modify table).
- A18: fixed (Client: timeouts, error kinds for every method, stream end on close).
- A19: fixed (Measurement: one latency measure; `runtime.model`; exit paths; data events only; the 20-task set defined).
- A20: fixed (Operator steps: who, start and stop, `probe.sh`, concrete probes, P12 procedure, the stop rule as fail conditions).
- A21: fixed (step 12 commands; read-only check; mtime and sha256 re-check; exact forbidden list).
- A22: fixed (rollback step 2).
- A23: fixed (step 14 yes/no questions; "installed and started by Yorozu (the agent)").
- A24: fixed (when the flag is off; "the `run.interrupted` row"; the quota actor and log pattern; "extend" keeps the code).
- A25: fixed (Baseline tense; sync v2 terms; no 4-minute requeue exists in v2; T3b doesn't exist in v2).
- A26: fixed ("canonical mode" dropped; `/v1/runs` reason restated; `index.txt` format; fixture 14).
- A27: fixed (Glossary: Gateway, Hermes gateway, Release Mac, Deploy website, box handover; one rollback-note reference).
- A28: fixed (ACP, red, guard glossed; "direct listener" throughout; H4, H5 and P10 noted as dropped).
- A29: mostly fixed (Status line, data-flow subsection, template layout). Appendix B is replaced by these dispositions.
- A30: mostly fixed. Kept: "real use" as a defined phase name.
- A31: partly. `keyFile` checks kept (a secret on disk; five lines). The `mcp` check test dropped (CI and acceptance cover it). CONTEST (FIFO) - kept: a few lines make order independent of step 10's lease result.
- A32: fixed (JSON block placement, reason strings, `YorozuConfig`, `stat`, key before mirror, quotes, step 14 preconditions, the CI test command, function names, byte-exact fixture copy, the opt-in race and no opt-out, `docs/openclaw-channel.md` deliberately left).
- A33: fixed (no overflow; the shared ChatGPT account; persona and instructions; project names removed; Appendix B dropped; Resend repeats in Risks).
