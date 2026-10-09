# OpenClaw integration

How the Mac app calls the local OpenClaw Gateway when OpenClaw is the main harness (`[harness] kind = "openclaw"`, the default), and the Gateway behaviours the code depends on. The agent entry and models are in [setup.md](setup.md); what each worker does is in [architecture.md](architecture.md#workers), and the seam every adapter implements in [architecture.md](architecture.md#harness-seam). The other adapter is in [hermes-integration.md](hermes-integration.md). The Gateway's source is `~/openclaw`: method handlers in `src/gateway/server-methods/`, parameter schemas in `packages/gateway-protocol/src/schema/`. Read them rather than guessing the contract.

## Transport

Live mode uses the native WebSocket client by default ([Native transport](#native-transport)). The CLI transport runs when `[harness] transport = "cli"` ([setup.md](setup.md#settings-configtoml); `PROJECTX_TRANSPORT` overrides it), for any launch whose native client is not enrolled or does not connect within 3 s, and, on a native launch, for each call that needs `operator.admin` ([Admin-scope calls](#admin-scope-calls)). It runs the CLI once per call (`GatewayRPC.perform` in `Harness.swift`):

```sh
/usr/bin/env openclaw gateway call <method> --json --expect-url <target> --timeout 260000 --params '<json>' [--expect-final]
```

- `<target>` is `[harness] gateway_url` (default `ws://127.0.0.1:18789`), fixed at launch; anything but a plain `ws`/`wss` URL on `127.0.0.1`, `::1` or `localhost` is refused. `--expect-url` pins the destination while the CLI keeps its own configured credentials.
- The child inherits the app's environment, with `/opt/homebrew/bin:/usr/local/bin` appended to `PATH` (a Finder launch's `PATH` lacks Homebrew).
- `--timeout` is 260000 ms, or the call's own (a thinking step: 4,230,000 ms, [Sessions and runs](#sessions-and-runs)); the process is killed 10 s after it. Stdout is capped at 2 MB, or 16 MB for `chat.history` and `chat.message.get`; a bigger response fails the call as uncertain.
- Stderr is kept in memory (≤ 32 KB) to pick a diagnostic category. A non-zero exit becomes `Gateway CLI failed [exit=<n>, category=<category>]: <code> <message>` (`gateway-target-mismatch` adds `, target=<gateway_url>` inside the brackets), where code and message come from the JSON error envelope on stdout, or, with no envelope, the first 300 bytes of stderr, which keeps OpenClaw's own hint such as "Start it with `openclaw gateway run`" (either is dropped if it looks like a secret). Categories: `model-override-not-authorized`, `caller-attribution-restriction`, `scope-denied`, `device-pairing-required`, `authentication-refused`, `request-schema`, `gateway-unreachable`, `gateway-target-mismatch`, `deadline-or-timeout`, `executable-or-runtime`, `unclassified-refusal-or-disconnect`. A CLI that cannot start reports `executable-unavailable`.
- Nothing streams over this transport: results and sub-chat progress arrive when a call returns.

The transport is chosen once per launch: a launch that fell back to the CLI keeps it until the next launch, even after a later enrollment.

### Plain-language errors

`PlainError.describe` (`PlainError.swift`) maps known setup failures to a cause id and a short sentence; the raw text stays under Details (a failure row's `error` param, the status line's tooltip). Failure notices (`routing_failed`, `task_failed`, `task_control_failed`) carry the cause as `cause` (and `subject`) params, and `NoticeText.plain` leads the row with the localized sentence. A startup or send error in the status line shows the same sentence.

| Matched in the raw text | Cause | Sentence |
|---|---|---|
| `caller-attribution` (the exec-marker refusal, or that category) | `exec_markers` | "Yorozu was started from an agent's shell; open it from Finder." |
| `data directory is already open` (`Store`'s `app.lock`) | `already_running` | "Yorozu is already running." |
| The personal-agent refusal (`OpenClawSetup.personalAgent`) | `personal_agent` | "Yorozu needs its own OpenClaw agent, not your main one. Set [harness] agent to a dedicated id." |
| `GatewayRPC`'s own shapes only, never a loose substring a worker error could quote: `Gateway CLI failed [exit=127,`, `category=executable-or-runtime]` (which "no such file" yields) or `[category=executable-unavailable]` | `openclaw_missing` | "OpenClaw or Node.js isn't installed." |
| `category=gateway-unreachable]` | `gateway_down` | "The OpenClaw Gateway isn't running. Start it with `openclaw gateway run`." |
| `category=gateway-target-mismatch, target=<url>]`: the CLI refuses an `--expect-url` other than its own configured Gateway, whether or not anything listens there | `gateway_target` | "Nothing answers at <url>; check [harness] gateway_url" |
| `Unknown agent id` | `agent_missing` | "Yorozu's agent isn't set up in OpenClaw." |
| `model not allowed: <key>` | `model_not_allowed` | "OpenClaw doesn't allow <key> for Yorozu." |
| `MemoryFileError` (a symlinked root or note, a duplicate note id) | `memory_file` | "Yorozu's memory can't load <file>." |

### Launch environment

`GatewayRPC.enforceAttribution` refuses every Gateway call, and live startup, when `OPENCLAW_SHELL=exec` or `OPENCLAW_SUBAGENT_EXEC` is set: the Gateway would lose inter-session attribution for a call made from an agent's exec shell. A dev app launched directly from a worker shell therefore cannot reach the Gateway. `build_native.sh` relaunches with `open -n`, which uses the login session's environment, so a restart run by a coding worker works. Keep the markers as they are; removing them or launching another way around them is not a fix.

## Sessions and runs

All sessions belong to the configured agent, `[harness] agent` (default `yorozu`; the owner's `config.toml` sets `projectx`). Keys put the app namespace `projectx` after the agent, so only the agent segment changes with it: agent `projectx` keeps `agent:projectx:projectx:<topicID>`, agent `yorozu` gets `agent:yorozu:projectx:<topicID>`, and idempotency keys keep their `projectx-` prefixes for every agent. The harness refuses a worker session key outside `agent:<agent>:projectx:`, so a topic made under another agent id starts no worker. The models below are the role models from [setup.md](setup.md#models).

| Session | Key | `sessions.create` params | Runs in it |
|---|---|---|---|
| Role session (secretary, extractor, stronger review) | `agent:<agent>:projectx-model:<sha256(<data root>/harness-workspaces\|<model>)>` | `model`, `permissionMode: "read-only"` | Raw runs: `modelRun: true`, `promptMode: "none"`, `deliver: false`, `timeout: 90`, `idempotencyKey: "projectx-<uuid>"`, `--expect-final`. Prompt ≤ 20000 bytes (`OpenClawHarness.rawPromptCap`, the protocol default: the shared `rawPromptCap` in `Models.swift`). |
| Topic session | `agent:<agent>:projectx:<topicID>` | worker model, `permissionMode: "full"`, `cwd: <task folder>` (#351) | Thinking steps: `bootstrapContextMode: "lightweight"`, `promptMode: "minimal"`, `deliver: false`, `disableMessageTool: true`, `timeout: 4200` (`OpenClawHarness.stepTimeout`: a coding agent's default hour plus 10 minutes, since the worker waits for the agents it runs; the call waits 30 s longer), `idempotencyKey: "projectx-run-<uuid>"`, `--expect-final`. Message ≤ 32000 bytes (`workerGuard`, the protocol default), checked before the run ID is stamped, so an oversized message fails the work instead of leaving it uncertain. Before each task: `sessions.describe`, then `sessions.compact` when the session is at half its window ([Compaction](#compaction)). |
| Controller | `agent:<agent>:projectx-control:<topicID>` | worker model, `permissionMode: "guarded"` | Only the `tools.invoke` steer call |

- Topic and controller sessions are prepared before each use (`OpenClawHarness.prepare`): `sessions.describe`, a `sessions.patch` when the session exists with another model ([Model changes](#model-changes)), `sessions.create` once per key per app run (concurrent first uses share the call; a failure retries next time), then, for topic sessions, `sessions.patch` with the MCP overlay ([MCP servers](#mcp-servers)). Once a key has been brought to a model, runtime and overlay in this app run, preparing it again for the same ones makes no Gateway call.
- A role session's key carries its model, so a changed role model simply uses another role session. An empty model (no explicit choice and no metadata) fails before any call: "No model is set for this role; choose one in Settings › Harness."
- The directory `<data root>/harness-workspaces` only feeds the hash and is never created.
- Working directory (#351): `sessions.create` takes `cwd`, an absolute Gateway path; outside the agent's configured workspace it needs `operator.admin`, which the topic session's create already goes through the CLI for (`permissionMode: "full"`). OpenClaw stores it as the session's `spawnedCwd` even for a key that exists ("creation owns cwd adoption", `src/gateway/session-lifecycle-preparation.ts`), and a run's `cwd` is the request's, else `spawnedCwd`, else the agent's (`src/agents/command/prepare.ts`). Yorozu creates each topic session once per app run, so existing topics get their folder at their next task. The `agent` method's own `cwd` parameter is not read by the Gateway's handler, so it is not used. The worker contract names the folder too ("cd there first"), which covers a Gateway that ignores `cwd`; whether runs start there has not been checked live.
- No coding executors (#351): Claude Code and Codex no longer run as OpenClaw sessions; workers run them through Yorozu ([architecture.md](architecture.md#workspace-and-coding-agents)). A coding run from before #351 lives in `<topic key>-claude` or `-codex`: stop aborts it there, and reconcile reports it running while `agent.wait` says pending, else stopped.
- Before every thinking step the work's run ID is stamped in the Store; that write fails once the work is suppressed, which is how a stop reaches a running loop.

## Methods used

| Method | Used for | Notes |
|---|---|---|
| `sessions.create` | Every session above | Omit `idempotencyKey`: the Gateway accepts it only from a caller with a device identity or principal, and the CLI's shared-token connection has neither. Re-creating an existing key is already idempotent. |
| `agent` | Raw runs, thinking steps | Images may ride as `attachments` on a thinking step ([Attachments and media](#attachments-and-media)). No per-turn `model`: a model override needs admin scope, so the model is chosen by creating the session with it. Text comes from `result.payloads` (the last non-reasoning payload, any length); `terminalReply` (under `result` for session turns, `result.meta` for raw runs) is a 4096-character preview that only decides visibility. A raw run whose `result.meta.agentMeta` names another model gets its session re-created once, then fails with notice `model_mismatch`. `result.meta.error.kind` `context_overflow` or `compaction_failure`, present on a failed run too, becomes an overflow error ([Compaction](#compaction)). |
| `agent.wait` | Reconcile (`timeoutMs: 1`) | Forgets runs about 10 minutes after they end and on Gateway restart; unknown, rejected and evicted runs all look like a bare timeout. So reconcile also reads the transcript. |
| `sessions.describe` | Compaction checks, session preparation | `{key, agentId}`, operator.read. Reads `session.sessionId`, `totalTokens` (used only when `totalTokensFresh` is true) and `contextTokens`; for preparation `modelProvider`, `model`, `agentRuntime.id` and `toolOverrides`. `session` is null for a key that does not exist yet. |
| `models.list` | Model metadata, setup checks | `{agentId, view: "configured", includeDetails: true}`, operator.read ([Model metadata](#model-metadata)); setup also asks `view: "all"` when a role model is missing ([Assisted setup](#assisted-setup)). |
| `models.authStatus` | Setup checks | `{agentId}`, operator.read. Per provider `provider`, `displayName` and `status`; only the provider and its state are shown ([Assisted setup](#assisted-setup)). |
| `health` | Setup and readiness | `{}`, operator.read. Whether the Gateway answers; 30 s on the CLI transport ([Assisted setup](#assisted-setup)). |
| `sessions.compact` | Topic session compaction | `{key, agentId}`, operator.admin, which the CLI requests. Refused while the session has an active or queued run ("retry after it finishes"); answers `compacted: false` with a `reason` when there is nothing to compact, and `result.tokensBefore` / `tokensAfter` when it compacted. |
| `chat.history` | Sub-chat progress, reconcile | `maxChars` 1–500,000, default 8000 (UTF-16 units per text field); a longer text ends in `\n...(truncated)...` and the message gets `__openclaw.truncated`. The response keeps the newest messages within 512 KiB, and a single message over 128 KiB is replaced by `[chat.history omitted: message too large]` (also marked truncated) at any `maxChars`. The app reads previews only: 2000 for the reconcile and 64000 for a step's progress. A run's reply carries `__openclaw.runId`; the admitted user turn has `idempotencyKey: "<run>:user"`. |
| `chat.message.get` | Whole final replies | `{sessionKey, agentId, messageId, maxChars: 1000000}`, operator.read, with `messageId` from the preview's `__openclaw.id`. Called only when the preview is marked `__openclaw.truncated`. Returns `message` with each text field up to 1,000,000 characters; a projected message over the 25 MiB payload limit answers `ok: false, unavailableReason: "oversized"`, and the app then keeps the preview. |
| `chat.abort` | Stop | `{sessionKey, agentId, runId, preserveSideRuns: true}`, with the old coding key for a coding run from before #351. Confirmed when `runIds` contains the run, or `aborted: false` (nothing with that ID is active, queued or pending). |
| `tools.invoke` | Live steer of a thinking step | `sessions_send` with `mode: "steer"` through the controller session, `idempotencyKey: "<work>-revision-<n>"`. Admitted only on `status: "accepted"` and `targetDisposition: "steered"` for the topic key. OpenClaw lists `sessions_send` in `DEFAULT_GATEWAY_HTTP_TOOL_DENY` (`src/security/dangerous-tools.ts`), so today it is refused and the change runs as a follow-up turn. |
| `config.get` | MCP mirror, model metadata, setup | operator.read. Read for `hash` and the names under `config.mcp.servers` whenever the MCP list is mirrored, for prices and output caps under `config.models.providers` whenever metadata is read, and by setup for Yorozu's own entry ([Assisted setup](#assisted-setup)). |
| `config.patch` | MCP mirror, assisted setup | `{raw: "{\"mcp\":{\"servers\":{…}}}", baseHash, replacePaths}`, a JSON merge patch (`null` deletes), never with `note` ([MCP servers](#mcp-servers)). Needs operator.admin, which the CLI requests. `baseHash` must match `config.get`; `replacePaths` lets an array shrink. The mirror sends it only when a `yorozu-*` entry differs; setup only on the user's click ([Assisted setup](#assisted-setup)). |
| `sessions.patch` | MCP overlay, model changes | Overlay: `{key, agentId, toolOverrides, expectedToolOverrides}`. `toolOverrides` replaces the session's whole overlay, so the app sends the current one (from `sessions.describe`) with only `mcpServers` changed, and `expectedToolOverrides` fails the call if it changed meanwhile. Skipped when `mcpServers` already matches. Needs operator.admin. Model: `{key, agentId, model}`, operator.write ([Model changes](#model-changes)). |

## Reading final replies

Yorozu sets no size limit on worker answers (owner decision, 2026-10-09). A thinking step's answer comes whole from the `agent` result. Where an answer is read from the transcript (reconcile), `chat.history` gives a preview and `OpenClawHarness.whole` fetches the message again with `chat.message.get` when the preview is marked truncated. Past that method's own limits the Gateway's marker shows as is. Any other failure of that fetch never passes the preview off as the answer: reconcile reports the run as unknown, so a later reconcile delivers it.

The reads do not use `chat.history` at its 500,000 maximum: a message over 128 KiB is dropped from `chat.history` whatever `maxChars` is, and with large texts the 512 KiB response budget keeps fewer of the newest messages, so a reconcile could miss the run's own turn. Small previews keep the response small and `chat.message.get` returns the one message needed.

Limits that remain: an `agent` response is bounded by the 2 MB stdout cap (8 MB frames on the native transport), a sub-chat event over 16,000 bytes keeps its last 8,000 characters, and phone frames follow [ios-relay-contract.md](ios-relay-contract.md).

## Attachments and media

Files users attach reach workers as `Attached document: <path>` lines in the message, and images also as `agent` `attachments`; files workers return come back as `MEDIA:` lines or payload media ([architecture.md](architecture.md#attachments)). Gateway source: `src/gateway/chat-attachments.ts` and the rich output protocol (`docs/reference/rich-output-protocol.md`).

- `agent` `attachments`: an array of `{type: "image", mimeType, fileName, content}`, `content` base64. The Gateway takes images only and refuses other files, only when the session's model is image-capable in the model catalog, and caps each image at 6 MiB (`MAX_IMAGE_BYTES`). `OpenClawHarness.inlineImages` sends a work's PNG, JPEG, GIF and WebP files of at most 6 MiB, only when `models.list {agentId, view: "configured", includeDetails: true}`, called each time, lists `image` in the `input` of the worker's `<provider>/<id>`; a failed call sends none. They go on the first step of each run, a follow-up turn included (memory steps send none). Every file also goes by path, so an image that is not sent inline still reaches the worker.
- Transport limits: the CLI transport passes all params as one `--params` argv string, so base64 images fail above roughly 750 KB in all; Yorozu keeps the encoded params under 600,000 bytes there (`cliParamsBudget`). The native transport caps a frame at 8,000,000 bytes (`NativeGateway`); Yorozu keeps them under 7,600,000 (`nativeParamsBudget`). From either budget it takes twice the message's bytes and 4,096 for escaping and the other params, and each image costs its base64 plus twice its name plus 128; images that do not fit, in work order, go by path only.
- `MEDIA:` lines: under OpenClaw's rich output protocol an agent returns a file as a standalone `MEDIA:<path>` line (outside fenced or indented code, at most three leading spaces), and the Gateway lifts a reply's lines into the payload's `mediaUrl`/`mediaUrls`. Yorozu reads both: the `mediaUrl`/`mediaUrls` of the `agent` result's non-reasoning payloads (`payloadMedia`; remote URLs left out) and `MEDIA:` lines still in the text (thinking JSON, reconcile), with `file:` URLs and `~/` resolved. In a progress message (a step's committed messages from `chat.history`) a `MEDIA:` line naming an image becomes a sub-chat image.
- `view_image` reads local paths only under OpenClaw's allowed media roots, which stay as they are: `~/Yorozu/files` is not added (open question 5 default; that would be an owner config change). Workers get images inline plus the path, and a thinking worker's shell reads any path.
- OpenClaw's own media copies of inbound attachments are left alone: Yorozu sets no `attachments.ttlHours`.
- Workers write files they make in their task folder ([architecture.md](architecture.md#workspace-and-coding-agents)).

## Compaction

OpenClaw's own compaction, memory flush and `contextPruning` are off in the Gateway config, so topic sessions grow until Yorozu compacts them (`compactTopic` in `Harness.swift`).

- Thinking: before each task, `sessions.describe` on the topic session. The window is `contextTokens`, capped at 258,400 (the usable part of the 272,000-token window, [setup.md](setup.md#yorozus-agent)). When `totalTokens` is fresh and at least half that window, `sessions.compact` runs as its own call, outside the 240 s task. Success posts a `compaction` event in the sub-chat ("Compacted this topic's session: N → M tokens"). A failed check or compaction (a refusal or `compacted: false` included) posts a short `failure` message in the main timeline, and the task runs anyway.
- Thinking overflow: a step whose `agent` result has error kind `context_overflow` or `compaction_failure` triggers one forced compaction. The task fails with "…Yorozu compacted it, so asking again should now work." or, when that compaction fails too, "…Start a new topic for this request." Neither offers a retry.

## Model metadata

`OpenClawHarness.models()` feeds the automatic role models ([setup.md](setup.md#models)). Both calls are operator.read.

- `models.list {agentId, view: "configured", includeDetails: true}` gives the agent's allowed models. Each row has `provider` and `id` (Yorozu uses `<provider>/<id>`), `contextTokens` (else `contextWindow`), `input`, `agentRuntime`, `runtimeChoices` and `tags`. The row tagged `default` is the agent's primary model. Rows with `available: false` are left out.
- `models.list` strips cost and route details from its rows, and bundled provider catalogs are not exposed over the Gateway. Price and output cap therefore come only from `config.get`, in `config.models.providers.<provider>.models[]`: `cost.input` + `cost.output` per million tokens, and `maxTokens` (else the provider's `maxTokens`). A model missing from there has no price and no cap. A cost of 0/0, as a local proxy may declare, counts as unknown price, not free.
- Runtimes a model can run on: its own `agentRuntime` (default `openclaw`), each available `runtimeChoices` entry, plus `codex` for providers `openai` and `codex` and `claude-cli` for `anthropic` and `claude-cli` (OpenClaw's session-runtime compatibility). Since #351 no role picks a model by runtime.
- The read runs at launch, after every `config.toml` reload, and, while no read has succeeded, before a message at most every 30 s; the launch waits up to 10 s for the first read before resuming queued work. A failed read keeps the last good result; offline and fixture harnesses report none.

## Model changes

A changed role model reaches existing topic and controller sessions at their next use with `sessions.patch {key, agentId, model}`, never by re-creating them: `sessions.create` with another model on an existing key needs operator.admin, while a patch of `model` and `agentRuntime` stays within operator.write (`src/shared/session-method-scopes-base.ts`), which the native client holds.

- `prepare` compares `sessions.describe`'s `modelProvider/model` with the wanted one and patches only on a difference.
- The patch counts only when the returned `entry` has `providerOverride/modelOverride` equal to the model; otherwise the work fails with "Gateway did not confirm switching this session to <model>; nothing was run."
- Not yet checked live on the owner's Gateway for a controller (`guarded`) session.

## MCP servers

Yorozu owns the list of MCP servers its workers may use (`Config.effectiveMCPServers`: `[mcp_servers]` in `config.toml` plus the servers of enabled integrations, [setup.md](setup.md#mcp-servers)); OpenClaw only holds a mirror of it. OpenClaw cannot take a server definition per session (`toolOverrides.mcpServers` only switches configured servers on or off), so the mirror has two parts (`OpenClawHarness.mcpOverlay` and `prepare` in `Harness.swift`):

1. Once per distinct list, before the next topic session is prepared: `config.get`, then a `config.patch` that writes each listed server as `mcp.servers.yorozu-<name>` with `enabled: false` and deletes `yorozu-*` entries no longer listed. Nothing is written when the entries already match. The patch lists every array inside a changed or deleted entry in `replacePaths` and carries no `note`: a note leaves a restart sentinel that wakes the owner's main agent on the next Gateway start. `enabled: false` keeps them away from every other agent and session. The Gateway hot-reloads `mcp.*` with no restart (`src/gateway/config-reload-plan.ts`); the reload restarts live MCP runtimes in every session, which is why unchanged entries are not rewritten.
2. For every topic session, once per app run and again after the list changes: `sessions.patch` with `toolOverrides.mcpServers` set to `true` for each `yorozu-*` server and `false` for every other server configured when step 1 ran. A server the owner adds to OpenClaw while the app runs reaches Yorozu sessions until Yorozu's list changes or the app relaunches.

A `config.toml` reload that changes `[mcp_servers]` or switches an integration makes the next prepared session run step 1 again, which also deletes the `yorozu-*` entries of removed servers; concurrent uses of one list share the call, and a failure retries on the next use. A session override wins over `enabled` in both directions (`src/agents/bundle-mcp-config.ts`). Role sessions run raw (no tools) and the controller session runs no turns, so they get no overlay.

What each runtime sees:

- Embedded runs (workers) read the overlay on every turn. Tools are deferred behind `tool_search`, named `<server>__<tool>` (for example `yorozu-cua-driver__type_text`) with catalog id `mcp:<server>:<name>`. Search queries must be English, and one batch may request at most 50 results.
- Coding agents (#351) run outside OpenClaw, spawned by Yorozu, and see only the MCP servers of their own configuration, never Yorozu's list.
- MCP calls on the embedded runtime have no approval step; `before_tool_call` plugin hooks still run.
- Plugin-bundled MCP servers that are not in `mcp.servers` are not covered by the overlay.
- Each session keeps its own stdio child per server (`cua-driver mcp` is a small proxy to the shared daemon) until the session is reset or deleted; `mcp.sessionIdleTtlMs` is unset.
- `openclaw mcp probe` refuses disabled servers, so it cannot health-check `yorozu-*` entries.

## Assisted setup

The setup steps ([setup.md](setup.md#first-setup)) check OpenClaw read-only and can write Yorozu's own entries once the user clicks (`OpenClawSetup.swift`). Every call goes through `GatewayRPC`, so the loopback pin and the exec-marker refusal hold ([Launch environment](#launch-environment)); in a process with the markers set, setup makes no Gateway call and leaves those steps to the app. Setup and readiness calls wait at most 30 s on the CLI transport, which the setup CLI always uses.

Detection, local: `openclaw` and `node` resolve on the launch `PATH` plus `/opt/homebrew/bin` and `/usr/local/bin`, the rule `GatewayRPC` launches the CLI by; the version comes from `node <openclaw> --version`, run without a shell with a 15 s timeout. Missing either blocks, unless another harness is installed or the Gateway answers `health` anyway (the native client): then it is a warning that the command line, and with it setup writes and the other admin calls, is unavailable. Then `health`: a failure is a warning, "The OpenClaw Gateway isn't running…", with `openclaw gateway run` to copy. Once the Gateway answers, a `config.get` checks that `[harness] agent` is not OpenClaw's default agent (id `main`, or an entry with `default: true`); if it is, readiness is blocked with "Yorozu needs its own OpenClaw agent, not your main one. Set [harness] agent to a dedicated id." and setup inspects and writes nothing. The app also refuses to start the OpenClaw harness on agent id `main`. The app runs this detection at launch and again after a Gateway call fails.

Read-only checks, once the Gateway answers:

- `config.get`: Yorozu's entry `agents.entries.<agent>` is present and in the expected shape ([setup.md](setup.md#yorozus-agent)): `workspace`, `model.primary`, `contextInjection: "never"`, `skills: []`, `subagents.allowAgents: []`, no `tools` key. Nothing else in the entry is inspected. Beyond it setup reads only `agents.defaults.model` and `agents.defaults.modelPolicy.allow` (for the values it would seed), whether the agent list is explicit (below), `config.models.providers` (prices, as for [Model metadata](#model-metadata)) and the names under `mcp.servers`.
- `models.list {agentId, view: "configured", includeDetails: true}`, once Yorozu's entry exists: each role model (secretary, extraction, worker, review) is usable when its row is listed and not `available: false`. A row marked unavailable is a warning with its `unavailableReason` and, unless the reason is `cooldown`, `openclaw models auth login --agent <agent> --provider <provider>` to copy. A role model not listed at all is "OpenClaw doesn't allow <model> for Yorozu"; setup then asks `models.list {agentId, view: "all"}` to see whether OpenClaw knows it.
- `models.authStatus {agentId}`: for each provider the role models use, the provider and its state only (`ok` and `static` count as signed in; `expiring`, `expired` and anything else are warnings with the sign-in command).

The write, `OpenClawSetup.apply`, is one `config.patch` and nothing else:

- `agents.entries.<agent>`: the missing or differing shape keys above (`model.primary` only when the entry has none; `tools` deleted with `null`). A missing entry gets all of them. Every change is shown as a list (path, old value, new value); any change under an existing entry, its allow list included, needs the user's confirmation.
- `agents.entries.<agent>.modelPolicy.allow`: role models OpenClaw knows (listed in `view: "all"`) but the policy in force does not allow. Since an entry's own list replaces the defaults' for that agent, the new list is the policy in force (the entry's own, else `agents.defaults.modelPolicy.allow`) plus those models. An empty policy allows every model, so then nothing is added; `agents.defaults` is never written.
- `mcp.servers.yorozu-*`: the mirror's own patch for the current effective list ([MCP servers](#mcp-servers)).

It carries `baseHash` from a fresh `config.get`, lists every changed array in `replacePaths`, and has no `note`. Before sending, `apply` inspects again and refuses when the changes differ from what the user saw ("OpenClaw's config changed since it was checked…"). The setup CLI binds the answer to the plan it printed: `answer openclaw_setup apply:<plan_digest>` ([setup.md](setup.md#yorozu-setup)), refused when the current plan has another digest. When the workspace is Yorozu's own folder, it is created first (mode 0700). With nothing to change, nothing is sent, so a second click writes nothing.

Roster ownership: OpenClaw accepts a second agent entry only in an explicit agent list. When Yorozu's entry is missing and the list is not explicit (`agents.ownership` is not `"explicit"` and no entry has `default: true`), or there are no entries at all, Yorozu writes nothing: it never writes `agents.ownership`, and offers `openclaw agents add <agent> --non-interactive --workspace <folder>` to copy instead. After that the shape check and the write proceed as for an existing entry.

## Request receipts

Every `agent` call writes a `request` receipt with `harness: "openclaw"` (`RequestReceipt`, [architecture.md](architecture.md#harness-seam)) before dispatch; if that write fails, nothing is sent. Rows from before #318 have kind `gateway-request` and no `harness`. It holds correlation data only (request ID, harness, session key, source message ID, raw-run flag, state), never prompts, output or credentials. States: `submitted`, then `terminal`, `admitted` or `uncertain`; `not-sent` when blocked locally; `rejected` for a refused model override. A failed call is reported with its request ID and never replayed automatically.

## What the agent sees

- `contextInjection: "never"` means OpenClaw injects no workspace bootstrap files (AGENTS.md and the like) into the agent's runs.
- OpenClaw creates `AGENTS.md`, and can create `SOUL.md`, `IDENTITY.md`, `USER.md` or `BOOTSTRAP.md`, in an agent workspace when they are missing, and never overwrites existing files. The agent workspace is Yorozu's own `<data root>/openclaw-workspace` folder, where those files land and nothing else uses them; workers run in their task folders instead (#351). Before #351 it was `dev_repo` when set; setup now shows moving an entry that still points at a checkout as a change to confirm.
- Workers inherit the global tool profile (full: shell, files, web). `subagents.allowAgents` is empty and `tools.agentToAgent.allow` does not list Yorozu's agent.
- A global plugin on the host replaces the system prompt of non-raw runs with the owner's PAIOS bridge (a `before_prompt_build` hook). Raw runs (`modelRun: true`) have no tools and skip prompt-build hooks, so the secretary and extractor can read no files, calendars or PAIOS and must delegate questions about them. Workers get the bridge.
- Coding agents that workers run through Yorozu load the owner's own Claude Code and Codex configuration and logins.
- Worker sessions see exactly Yorozu's MCP servers, behind OpenClaw's `tool_search` / `tool_call` ([MCP servers](#mcp-servers)). OpenClaw never passes an MCP server's own instructions to the model, so worker prompts carry the cua rules.
- The OpenClaw config still enables v1's `yorozu` channel plugin, which v2 does not use.

## Native transport

The default in live mode (`[harness] transport = "native"`, the default; `AppModel.connectNative` in `ProjectX.swift`). It dials `[harness] gateway_url`. Admin-scope calls still go through the CLI ([Admin-scope calls](#admin-scope-calls)), so the CLI must work on a native launch too.

- At launch: with no stored device token (`NativeGatewayClient.isEnrolled`, a Keychain read), the client does not dial, since a connect would store a fresh key and fail. With a token it connects with a 3 s handshake deadline instead of the usual 15 s. Either failure makes that launch use the CLI, and the popover shows "Native Gateway not connected · using the CLI this launch" with the error as its tooltip and a "Connect…" link that opens Settings at Advanced, turning Advanced on if needed. The composer is never blocked for it.
- Enrollment is the Gateway tab of the Settings window, shown in live mode while the native transport is selected. After a fallback launch a successful enrollment says "Yorozu uses it from the next launch".
- Redial: after a drop, or a failed connect other than a refusal (`ProjectError.blocked`), the client redials in the background, 1 s doubling to 60 s, until it connects, is refused or `close()` stops it. A call made while disconnected connects first. The fallback path closes the client, so a CLI launch does not redial.
- Protocol-4 WebSocket client registered as client id `webchat`, mode `ui`, role `operator`, scopes `operator.read` and `operator.write`, with its own Ed25519 key and a v3 signed device proof over the Gateway's challenge.
- Bootstrap: the Gateway's shared token or password is typed into a `SecureField`, used once and never stored. The Gateway may answer `PAIRING_REQUIRED`; approve that exact request on the host (`openclaw devices list`), then connect again. Only the app's key and the issued device token are kept ([Keychain items](setup.md#keychain-items)).
- It calls only methods the Gateway advertises, with a 270 s deadline per call (a thinking step: its own timeout plus 40 s). A disconnect fails pending calls as uncertain; nothing is replayed.
- Only this transport delivers live `agent` lifecycle and tool events, which the thinking worker projects into the sub-chat as they happen ([Tool rows](#tool-rows); never arguments or text deltas).

### Admin-scope calls

The native client holds only `operator.read` and `operator.write`, so a native launch sends each call that needs `operator.admin` through the CLI, which requests admin, and keeps everything else native so live events still stream (`GatewayRPC.needsAdmin` in `Harness.swift`). Before phase B of #311 these calls went native too and failed for lack of the scope (a topic session is created with `permissionMode: "full"`); with them routed through the CLI, native is the default again. The list mirrors OpenClaw's own scope tables (`core-descriptors.ts` for static scopes, `method-scopes.ts` for `agent` reset commands, `shared/session-method-scopes-base.ts` for the param-dependent session methods):

- `config.patch` and `sessions.compact`, always.
- `sessions.create` with `permissionMode: "full"` (which also covers the topic session's `cwd` outside the agent workspace), any `toolOverrides`, or `worktree: true` (OpenClaw runs the worktree setup script only for an admin caller, `sessions-create.ts`).
- `sessions.patch` with `permissionMode: "full"` or any key outside the write set (`key`, `agentId`, the `expected*` guards, label and board fields, `model`, `agentRuntime`, `thinkingLevel`, `fastMode`, `permissionMode`); the MCP overlay's `toolOverrides` is one.
- `agent` whose message starts with `/new` or `/reset`.

A model change (`sessions.patch {key, agentId, model}`, plus `agentRuntime`) stays native. When OpenClaw changes a method's scope, update the list.

## Tool rows

A sub-chat tool row reads `<server>: <tool>[ in <app>]` and never carries arguments (`toolRow` in `NativeGateway.swift`). It is built from live `tool` events, from `toolCall` / `tool_use` blocks in a thinking step's transcript (`visibleEvents`), and never from coding agents, whose rows (`CodingAgentHost`) are the tool name plus its file path.

- Live events: only `phase: "start"` makes a row, since only the start carries `args`; `update` and `result` make none.
- `tool_call`, Tool Search's call tool, is named by its target: `args.id` (or `toolId`, `name`), with that call's own `args` (or `input`) for the target. The id is a catalog id `<source>:<server>:<name>` (`src/agents/tool-search-catalog.ts`) or a bare name.
- MCP tool names are `<server>__<tool>` (`src/agents/agent-bundle-mcp-names.ts`); in an `mcp:` catalog id the `<server>__` prefix of the name is dropped. The server loses a `yorozu-` prefix and a `-driver` suffix, so `yorozu-cua-driver` reads `cua`.
- The app comes only from a `pid` (or `target.pid`) argument: the display name of the outermost `.app` bundle of that process. No other argument is read.
- A nested call carries `parentToolCallId` and is skipped, in events and in transcript blocks: the `tool_call` row already names it.
- A row is cut to 200 characters (the app name to 60), and one that looks like a secret is dropped.

## Probing the Gateway by hand

- Use `openclaw gateway call <method> --json --expect-url ws://127.0.0.1:18789 --params '<json>'` from a shell without the OpenClaw exec markers ([Launch environment](#launch-environment)).
- Use only the configured agent id (`agentId: "projectx"` on the owner's Mac) and throwaway session keys, and delete them afterwards with `sessions.delete {key, agentId, deleteTranscript: true}`.
- Leave other agents' sessions and the OpenClaw config alone: no reading, messaging or editing. The app writes only Yorozu's own keys: `mcp.servers.yorozu-*` through the mirror, and, on the user's click in setup, its own agent entry `agents.entries.<agent>` with its `modelPolicy.allow` ([Assisted setup](#assisted-setup)). It never writes other agents' entries, `agents.defaults`, providers or logins.
