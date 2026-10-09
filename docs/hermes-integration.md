# Hermes integration

How the Mac app drives Nous Research's Hermes Agent when it is the main harness (`[harness] kind = "hermes"`), and the Hermes behaviours the code depends on. The seam every adapter implements is in [architecture.md](architecture.md#harness-seam); install and provider steps are in [setup.md](setup.md#hermes-agent). Code: `HermesHarness.swift` (the adapter), `HermesSSE.swift` (`HermesClient`, `HermesRun`, the SSE reader) and `HermesProfiles.swift` (profile setup).

Everything here was written against Hermes v0.21.6 (2026-10-08): its docs (`website/docs/user-guide/features/api-server.md`, `developer-guide/programmatic-integration.md`, `user-guide/profiles.md`) and its source (`gateway/platforms/api_server*.py`). Hermes is pre-1.0 and documents breaking changes for clients, so read the source of the installed version rather than guessing. The adapter has been compile-checked only; nothing below has been run against a live Hermes yet ([status.md](status.md)).

## Transport

- One API server, run inside `hermes gateway` by the default profile, on `[harness] hermes_url` (default `http://127.0.0.1:8642`). Only a loopback `http`/`https` URL with no path, query or credentials is accepted, at config validation and again in `HermesClient`.
- Multiplexing (on by default in Hermes): the default profile's listener serves each named profile at `<root>/p/<profile>/…`, and each profile takes only the `API_SERVER_KEY` from its own `.env`. Yorozu calls only `/p/yorozu-worker/` and `/p/yorozu-roles/`. A named profile must not start its own listener.
- Auth: `Authorization: Bearer <key>`, the profile's key read from the Keychain (`to.yumi.yorozu.hermes`, account = profile) on every request. The key is never logged, put in a URL, written to a receipt or quoted in an error. A missing item is `harness_not_ready` ("Run the Hermes setup step"); a 401 or 403 says Hermes refused the key.
- An ephemeral `URLSession` (no cookies, cache or credential store) with a 60 s idle timeout. A transport failure means nothing is known about admission and is reported as uncertain.
- A 429 is `harness_busy`: Hermes already runs its maximum of 10 runs at once and started nothing. Other refusals become an uncertain error with Hermes's error code and message, the message dropped when it looks like a secret.

## Profiles

Yorozu owns two profiles and writes nothing else under `~/.hermes` (owner decision). `HermesProfiles.plan` lists every write so the setup step can show it first, and `apply` runs it; only an explicit setup action calls `apply`. That setup step belongs to onboarding (#317) and has no UI yet.

| Write | Both | `yorozu-worker` | `yorozu-roles` |
|---|---|---|---|
| Profile folder, if missing: `hermes -p default profile create <name> --no-alias --no-skills` | ✓ | | |
| `API_SERVER_KEY` in the profile's `.env` (mode 0600, other lines kept; an existing key of 32+ characters is kept, else 32 random bytes as base64url), mirrored to the Keychain | ✓ | | |
| `memory.memory_enabled false`, `memory.user_profile_enabled false`: Hermes's own memory off | ✓ | | |
| `auxiliary.background_review.enabled false`, `curator.enabled false`: no background self-review | ✓ | | |
| `agent.disabled_toolsets ["cronjob", "skills"]`: no cron jobs and no skill writes | ✓ | | |
| `auth.adopt_external_logins false`: Hermes does not adopt, and by refreshing sign out, the user's Claude Code and Codex logins | ✓ | | |
| `approvals.mode off`: no per-step approvals; the ask-first rules stay in Yorozu's prompts | | ✓ | |
| `terminal.cwd`: `dev_repo`, else the home folder | | ✓ | |
| `compression.threshold_tokens`: half the usable window, 129,200 when none is known | | ✓ | |
| `mcp_servers` (with `--force`): Yorozu's `[mcp_servers]`, `command` and `args` only, none marked `trust: untrusted` | | ✓ | |
| An empty `work` folder as `terminal.cwd`, `platform_toolsets.api_server ["no_mcp"]`, `SOUL.md` with the role identity | | | ✓ |

- Keys are written with Hermes's own type-checked writer, `hermes -p <profile> config set [--force] <key> <value>`; `.env` and `SOUL.md` are written directly (temp file in the same folder, then rename). Yorozu has no YAML library.
- Guards: only the two profile names, only `profile create` and `config set` with exactly those shapes, no write through a symlinked `profiles/`, profile folder or file, `HERMES_HOME` unset and `HOME` pinned for the child, 120 s per command. Yorozu never runs Hermes's installer, `hermes update`, `hermes setup` or any `hermes claw` command.
- `yorozu-worker` keeps Hermes's default API-server toolsets: its workers get the harness's default tools.
- Skills: Hermes 0.21.6 has no switch for skill writes alone, so the whole `skills` toolset is disabled.
- An empty toolset list still loads every MCP server, so `yorozu-roles` sets `no_mcp`.
- MCP: Hermes reloads `mcp_servers` within about a minute. `HermesProfiles.confirmMCP` reads `GET /v1/toolsets` for `mcp-<name>` entries, but 0.21.6's handler lists only built-in and plugin toolsets, so an empty answer means unconfirmed, not missing. A changed `[mcp_servers]` reaches Hermes only when the profile setup runs again; nothing re-projects it on reload yet.
- Default profile (open question 1 default): Hermes serves `/p/<profile>/` only while the default profile's API server is on. `HermesProfiles.defaultProfileAPIServerStep` checks `~/.hermes/.env` and `config.yaml` read-only and, when it is off or has no key of 16+ characters, returns the commands for the user ([setup.md](setup.md#hermes-agent)). Yorozu never edits the default profile.

## Readiness

`HermesHarness.readiness()` is read-only and runs at launch and before each message while something is wrong; the result shows in the popover ([architecture.md](architecture.md#harness-seam)). Hermes is ready when there are no problems:

- the `hermes` launcher on `PATH` or at `~/.local/bin/hermes`, and `~/.hermes`;
- both profile folders;
- per profile, an unauthenticated `GET /health` answering 200 with `platform: "hermes-agent"` (its `version` is reported);
- per profile, `GET /v1/capabilities` with every one of `run_status`, `run_events_sse`, `run_stop`, `run_steer`, `session_model_lock`, `tool_progress_events`, `model_options` true in `features`.

A version not in `HermesHarness.testedVersions` (0.21.6; a leading `v` is ignored) is only a warning. Hermes not ready still launches the app: messages are saved and runs fail with the reason.

## Calls

All under `<root>/p/<profile>`.

| Call | Profile | Used for | Notes |
|---|---|---|---|
| `GET /health` | both | Readiness | No auth. |
| `GET /v1/capabilities` | both | Readiness | Feature flags above. |
| `GET /api/model/options` | both | Model metadata ([Models](#models)) | |
| `POST /api/sessions` | worker | Topic and coding sessions | `{id, title, source: "yorozu", provider, model, require_model_lock: true}`. 400 `invalid_title` retries without the title; 409 `session_exists` locks the existing session with `POST /api/sessions/{id}/model {provider, model}`. Once per session and model per app run. Hermes 0.21.6 keeps only its own source names and stores `source` as `api_server`. |
| `GET /api/sessions/{id}/messages?limit=1` | worker | Compaction check | Reads `session_id`, the session's live id. |
| `POST /v1/runs` | both | Every run | `{input, instructions, provider, model}` plus `session_id` for workers, header `Idempotency-Key`. 200 or 202 with `run_id` (the server's `run_<uuid>`). An identical retry within 24 h returns the original run (`Idempotency-Replayed`). A run without `session_id` gets a new session. A bare model name without a provider is ignored by Hermes, so Yorozu always sends both. |
| `GET /v1/runs/{id}/events` | both | Progress and the terminal status | SSE ([Progress](#progress)). |
| `GET /v1/runs/{id}` | both | Reconcile, stop confirmation, fallback after SSE | `status`, `output`, `error`, `session_id`, `pending_steer`, `runtime {provider, model, requested {provider, model}}`. 404 for an unknown or forgotten run: terminal runs stay about 1 h in memory and 24 h durably. |
| `POST /v1/runs/{id}/steer` | worker | Live steer | `{input: <encoded amendment>}`. |
| `POST /v1/runs/{id}/stop` | both | Stop, role timeout, unexpected approval | Settles the run as `cancelled`. |
| `POST /v1/runs/{id}/approval` | worker | Unexpected approval | `{choice: "deny", all: true}`. |
| `GET /v1/toolsets` | worker | MCP confirmation (setup) | See [Profiles](#profiles). |

Run statuses: `queued`, `running`, `stopping`, `waiting_for_approval`, then terminal `completed`, `failed`, `cancelled` or `interrupted` (a gateway restart marks live runs `interrupted`).

## Role runs

The secretary, the stronger review and extraction (owner default H6.1):

- Each call is a fresh one-shot run in `yorozu-roles` with no `session_id`, an explicit provider and model, and `Idempotency-Key: yorozu-role-<uuid>`.
- Routing: `instructions` is a short role framing plus the routing policy; `input` is the shared routing prompt with the policy replaced by a pointer to the instructions. Extraction: `instructions` is the framing, `input` the shared extraction prompt. The two together stay within the shared 20000-byte cap; `rawPromptCap` is that cap less the framing, so the Engine's trim still fits.
- The run is followed over SSE for at most 120 s, then stopped and reported uncertain.
- Model check: the output is used only when `runtime.provider` and `runtime.model` equal the requested pair exactly; anything else, a fallback model included, is `model_mismatch` and the output is discarded.
- Hermes always prepends its own core system prompt to `instructions`, and `SOUL.md` of `yorozu-roles` tells it it serves Yorozu's roles with no tools.

## Workers

| | Thinking worker | Coding worker |
|---|---|---|
| Session | `yorozu-<topicID>`, title the topic label | `yorozu-<topicID>-hermes`, title "<label> · coding" |
| Model | `models.worker` | `models.coding.hermes`, else the worker model |
| Run input | `WorkerInput.wire` or a follow-up's amendments, plus one `Attached document: <path>` line per file the work carries (`Prompts.workerMessage`); or a memory result | `Prompts.codingTask`: task, run marker, the user's message verbatim with the work's `Attached document:` lines, recent topic conversation |
| Run instructions | `Prompts.thinkingContract` plus a note that Hermes's own memory, skills and scheduled jobs are not the worker's to use (Yorozu's memory goes through `memoryCall`) | `Prompts.codingContract` with the worktree the worker creates |
| Run id (`Idempotency-Key`) | `yorozu-run-<uuid>`, one per step | `yorozu-code-<uuid>` |
| Steps | Up to 7: memory round trips are further runs in the same session | One run |
| Result | The contract's JSON `{text, appliedRevision, files?}`; returned files from `files` and `MEDIA:` lines | The final text; no diffstat (open question 8 default); returned files from a `Files:` section and `MEDIA:` lines, relative paths resolved against the worktree |

- Coding (open question 2 default): one executor, `hermes` ("Hermes"), Hermes's own agent loop in `yorozu-worker`, with Yorozu's MCP servers and live steer; not ready while `dev_repo` is empty. Hermes has no per-session or per-request working folder and no managed worktrees, so the contract has the worker create `<dev repo>-yorozu-<label slug>-<topicID prefix>` on branch `yorozu/<label slug>-<topicID prefix>` from the base branch with `git worktree add`, reuse it on later turns, and run every command there. Claude Code and Codex are not offered through Hermes's bundled skills or its Codex runtime: that route has no progress or steer and writes `~/.codex/config.toml`.
- Attachments (#316): attached files reach Hermes workers by path only; Yorozu sends Hermes no image input yet, whatever the model takes (inline images on Hermes are #318's to add). Returned files are copied into the file store as on OpenClaw ([architecture.md](architecture.md#attachments)); Hermes has no payload media, so only the JSON's `files`, `MEDIA:` lines and a coding reply's `Files:` section count. A `message.interim` progress message with a `MEDIA:` line naming an image shows that image in the sub-chat.
- Each step (`HermesHarness.step`): the size guard (`input` plus `instructions` within `workerGuard`, 32000 bytes) before anything is stamped; the run handle stamped with the Yorozu run id; `POST /v1/runs`; the server run id stored; the SSE stream followed; then the terminal status, the model check and the compaction check.
- Controller key: `hermes:<Yorozu run id>:<server run id>` once Hermes answers, or `hermes:<Yorozu run id>:refused` when it answered and did not admit the run, so nothing ran. Steer, stop and reconcile take the server run id from it after a restart; within an app run it is also kept in memory. The topic's `sessionKey` column is unused under Hermes.
- Submitting: a request receipt (`harness: "hermes"`) is written before the first attempt and fails closed; a dropped connection is retried twice, 2 s apart, with the identical body, which Hermes answers with the original run. The receipt then records `admitted`, `rejected`, `not-sent` or `uncertain`. A crash between the POST and its answer (open question 7 default) stores no body: the work becomes uncertain and the watch and reconcile path takes over.
- A run that ends other than `completed`: `cancelled` is "The Hermes run was stopped."; `interrupted` is `run_interrupted`; an error mentioning compression or compaction posts a failure notice to the main timeline and fails the task as an overflow; an error matching the context-overflow wording fails it as an overflow; anything else is "Hermes run failed: …".

### Progress

`HermesClient.follow` reads `GET /v1/runs/{id}/events` (`Accept: text/event-stream`): frames are `id: <seq>` plus one `data: <json>` line whose `event` field names the event; `:` lines (`: open`, `: keepalive` every 10 s, `: stream closed`) are skipped. After a drop it resumes with `Last-Event-ID`, backing off 2 s per failure up to 15 s, at most 10 failures in a row. A stream that closes without a terminal event is checked against the run status. Once Hermes has dropped the buffer (404: 300 s after the last subscriber left) or the stream keeps failing, it polls `GET /v1/runs/{id}` every 5 s, and gives up as uncertain after about 10 minutes of Hermes being unreachable.

Events become sub-chat rows (`HermesHarness.event`, id `<task>:<run>:event:<seq>`); `sensitive()` drops secret-shaped text:

| Event | Row |
|---|---|
| `run.*` | `lifecycle`, "Worker lifecycle: <state>" |
| `subagent.start`, `subagent.complete` | `lifecycle` |
| `tool.started` | `tool`, the tool row with no arguments (`mcp__<server>__<tool>` loses its `mcp__` prefix); for the `terminal` tool, `command` with Hermes's redacted preview as `$ <command>` |
| `tool.completed` | `output`, or `error` when it failed: Hermes's redacted preview of at most 500 characters |
| `message.interim` | `message`, unless it is the contract's JSON |
| `message.delta`, `reasoning.*`, `approval.*`, others | none |

### Approvals

Approvals are off in `yorozu-worker` (owner default H6.3), and Hermes's smart approvals would fail closed after 300 s anyway. An `approval.request` arriving all the same (open question 6 default) is answered `deny` for all, the run is stopped and the task fails with `approval_requested`, naming the profile setting to check.

## Steer, stop and reconcile

- Steer (live, owner default H6.2): `POST /v1/runs/{id}/steer`; 200 or 202 is admitted, applied by Hermes at the next tool boundary. A 409 (not `running`) or no known server run leaves the amendment for a follow-up turn. Text Hermes queued but never delivered comes back as `pending_steer` on the terminal status; the adapter lowers `appliedRevision` below the first undelivered revision, so `Store.finish` runs it as a follow-up turn.
- Stop: no run id means nothing was dispatched (confirmed); an unknown server run id is not confirmed (Engine retries); `refused` is confirmed. Otherwise `POST /v1/runs/{id}/stop`, then poll the status once a second for about 30 s: terminal or 404 is confirmed.
- Reconcile: `GET /v1/runs/{id}`. `completed` is delivered when the model check passes and the output parses (the contract's JSON for thinking work, the text for coding), else stopped; `cancelled`, `interrupted` and `failed` are stopped; `queued`, `running`, `stopping` and `waiting_for_approval` are running; 404 or no known server run is unknown. After an app restart the Engine's watch reconciles by status; the adapter does not re-attach to a run's SSE stream.

## Compaction

Hermes compacts a session itself once it passes `compression.threshold_tokens`, which setup sets in `yorozu-worker` to Yorozu's threshold (half the usable window, owner default H6.6). Compaction rotates the session to a continuation that Hermes maps back to the same id, so Yorozu keeps sending `yorozu-<topicID>`. Before a step the adapter reads the session's live id (`GET /api/sessions/{id}/messages?limit=1`, `session_id`); a different one after the step posts a `compaction` event, "Hermes compacted this topic's session." A failed compaction posts to the main timeline and fails the task as an overflow ([Workers](#workers)).

## Models

`HermesHarness.models()` reads `GET /api/model/options` from both profiles and keeps models both list, since each role runs in one of them. Rows come from `providers[]` (those not marked `authenticated: false`): id `<slug>/<model>`, price the sum of `pricing.<model>.input` and `.output` when both are `$<number>` per million tokens (`free` or missing is unknown), runtime `hermes`. The primary model is `yorozu-worker`'s `provider/model`. The payload has no context window, output cap or input kinds, so the automatic choice ([setup.md](setup.md#models)) falls back to the primary model for every role.

## Limits

- At most 10 runs at once across the server (429, `harness_busy`).
- The SSE buffer is dropped 300 s after the last subscriber leaves; a run's status stays 1 h in memory and 24 h durably.
- No per-session or per-request working folder: `terminal.cwd` is profile-wide, so thinking workers start in `dev_repo` (or home) and coding workers make their own worktree.
- MCP servers and toolsets are profile-wide: every `yorozu-worker` session gets the same servers, and a change needs the setup step again.
- Hermes's core system prompt is always prepended to Yorozu's `instructions`.
- No coding diffstat.
- `GET /v1/toolsets` may not list MCP servers on 0.21.6.

## OpenClaw migration hazards

Hermes's setup wizard (which an interactive install runs) detects `~/.openclaw` and offers to import it. Decline. `hermes claw migrate` imports OpenClaw's settings, memories, skills and API keys into Hermes, and the migration guide then suggests `hermes claw cleanup`, which renames leftover OpenClaw directories to `.pre-migration/`; that breaks the OpenClaw harness and the user's other OpenClaw agents. Never run either: Yorozu needs both harnesses to stay as installed (owner default H6.7), and its code runs no `hermes claw` command.

## Probing Hermes by hand

- Call only `/p/yorozu-worker/` and `/p/yorozu-roles/` on the loopback root, with the profile's key from the Keychain (`security find-generic-password -s to.yumi.yorozu.hermes -a <profile> -w`), and keep it out of shell history and notes.
- Read-only first: `/health`, `/v1/capabilities`, `/api/model/options`, `GET /v1/runs/{id}`. A test run uses a throwaway session id outside `yorozu-<topicID>`.
- Leave the user's own profiles and the default profile's config alone, and never run `hermes setup`, `hermes update` or `hermes claw`.
