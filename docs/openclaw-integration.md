# OpenClaw integration

How the Mac app calls the local OpenClaw Gateway, and the Gateway behaviours the code depends on. The agent entry and models are in [setup.md](setup.md); what each worker does is in [architecture.md](architecture.md#workers). The Gateway's source is `~/openclaw`: method handlers in `src/gateway/server-methods/`, parameter schemas in `packages/gateway-protocol/src/schema/`. Read them rather than guessing the contract.

## Transport

The default transport runs the CLI once per call (`GatewayRPC.perform` in `Harness.swift`):

```sh
/usr/bin/env openclaw gateway call <method> --json --expect-url <target> --timeout 260000 --params '<json>' [--expect-final]
```

- `<target>` is `PROJECTX_GATEWAY_URL` or `ws://127.0.0.1:18789`; anything but a plain `ws`/`wss` URL on `127.0.0.1`, `::1` or `localhost` is refused. `--expect-url` pins the destination while the CLI keeps its own configured credentials.
- The child inherits the app's environment, with `/opt/homebrew/bin:/usr/local/bin` appended to `PATH` (a Finder launch's `PATH` lacks Homebrew).
- The process is killed after 270 s. Stdout is capped at 2 MB, or 16 MB for `chat.history` and `chat.message.get`; a bigger response fails the call as uncertain.
- Stderr is kept in memory (≤ 32 KB) only to pick a diagnostic category. A non-zero exit becomes `Gateway CLI failed [exit=<n>, category=<category>]: <code> <message>`, where code and message come from the JSON error envelope on stdout (the message is dropped if it looks like a secret). Categories: `model-override-not-authorized`, `caller-attribution-restriction`, `scope-denied`, `device-pairing-required`, `authentication-refused`, `request-schema`, `gateway-unreachable`, `gateway-target-mismatch`, `deadline-or-timeout`, `executable-or-runtime`, `unclassified-refusal-or-disconnect`. A CLI that cannot start reports `executable-unavailable`.
- Nothing streams over this transport: results and sub-chat progress arrive when a call returns.

`PROJECTX_TRANSPORT=native` switches to the WebSocket client in `NativeGateway.swift`; see [Native transport](#native-transport).

### Launch environment

`GatewayRPC.enforceAttribution` refuses every Gateway call, and live startup, when `OPENCLAW_SHELL=exec` or `OPENCLAW_SUBAGENT_EXEC` is set: the Gateway would lose inter-session attribution for a call made from an agent's exec shell. A dev app launched directly from a worker shell therefore cannot reach the Gateway. `build_native.sh` relaunches with `open -n`, which uses the login session's environment, so a restart run by a coding worker works. Keep the markers as they are; removing them or launching another way around them is not a fix.

## Sessions and runs

All sessions belong to agent `projectx`; the harness refuses any other agent and any worker session key outside `agent:projectx:projectx:`.

| Session | Key | `sessions.create` params | Runs in it |
|---|---|---|---|
| Role session (secretary, extractor, stronger review) | `agent:projectx:projectx-model:<sha256(<data root>/harness-workspaces\|<model>)>` | `model`, `permissionMode: "read-only"` | Raw runs: `modelRun: true`, `promptMode: "none"`, `deliver: false`, `timeout: 90`, `idempotencyKey: "projectx-<uuid>"`, `--expect-final`. Prompt ≤ 20000 bytes (`rawPromptCap` in `Models.swift`, the one cap every raw-run budget measures against). |
| Topic session | `agent:projectx:projectx:<topicID>` | worker model, `permissionMode: "full"` | Thinking steps: `bootstrapContextMode: "lightweight"`, `promptMode: "minimal"`, `deliver: false`, `disableMessageTool: true`, `timeout: 240`, `idempotencyKey: "projectx-run-<uuid>"`, `--expect-final`. Message ≤ 32000 bytes, checked before the run ID is stamped, so an oversized message fails the work instead of leaving it uncertain. Before each task: `sessions.describe`, then `sessions.compact` when the session is at half its window ([Compaction](#compaction)). |
| Controller | `agent:projectx:projectx-control:<topicID>` | worker model, `permissionMode: "guarded"` | Only the `tools.invoke` steer call |
| Coding session | `<topic key>-claude` or `<topic key>-codex` | `agentRuntime: "claude-cli"` + `permissionMode: "full"`, or `"codex"` + `"workspace"`; `worktree: true`, `worktreeBaseRef: "projectx"`, `worktreeName: "<label slug ≤ 32>-<topicID first 6>-<executor>"` | One async run: `deliver: false`, `timeout: 7200`, `idempotencyKey: "projectx-code-<uuid>"`, no `--expect-final` |

- Each key gets `sessions.create` once per app run (concurrent first uses share the call; a failure retries next time). Topic and coding sessions then get `sessions.patch` with the MCP overlay in the same step ([MCP servers](#mcp-servers)). The directory `<data root>/harness-workspaces` only feeds the hash and is never created.
- OpenClaw names a coding worktree's branch `openclaw/<worktreeName>`. Claude Code needs `full` because its guarded modes need an approval client the app does not have; Codex `workspace` is sandboxed to the worktree.
- Before every thinking step and every coding poll the work's run ID is stamped in the Store; that write fails once the work is suppressed, which is how a stop reaches a running loop.

## Methods used

| Method | Used for | Notes |
|---|---|---|
| `sessions.create` | Every session above | Omit `idempotencyKey`: the Gateway accepts it only from a caller with a device identity or principal, and the CLI's shared-token connection has neither. Re-creating an existing key is already idempotent. |
| `agent` | Raw runs, thinking steps, coding runs | No per-turn `model`: a model override needs admin scope, so the model is chosen by creating the session with it. Text comes from `result.payloads` (the last non-reasoning payload, any length); `terminalReply` (under `result` for session turns, `result.meta` for raw runs) is a 4096-character preview that only decides visibility. A raw run whose `result.meta.agentMeta` names another model gets its session re-created once, then fails. A coding start counts only when the response's `runId` matches. `result.meta.error.kind` `context_overflow` or `compaction_failure`, present on a failed run too, becomes an overflow error ([Compaction](#compaction)). |
| `agent.wait` | Reconcile (`timeoutMs: 1`), coding poll (`timeoutMs: 20000`) | Forgets runs about 10 minutes after they end and on Gateway restart; unknown, rejected and evicted runs all look like a bare timeout. So reconcile also reads the transcript. Carries only the error text, no kind: a coding run that ends with an error matching OpenClaw's overflow wording (`packages/ai/src/utils/overflow.ts`) becomes an overflow error. |
| `sessions.describe` | Compaction checks | `{key, agentId}`, operator.read. Reads `session.sessionId`, `totalTokens` (used only when `totalTokensFresh` is true) and `contextTokens`. |
| `sessions.compact` | Topic session compaction | `{key, agentId}`, operator.admin, which the CLI requests. Refused while the session has an active or queued run ("retry after it finishes"); answers `compacted: false` with a `reason` when there is nothing to compact, and `result.tokensBefore` / `tokensAfter` when it compacted. |
| `chat.history` | Sub-chat progress, reconcile, coding results | `maxChars` 1–500,000, default 8000 (UTF-16 units per text field); a longer text ends in `\n...(truncated)...` and the message gets `__openclaw.truncated`. The response keeps the newest messages within 512 KiB, and a single message over 128 KiB is replaced by `[chat.history omitted: message too large]` (also marked truncated) at any `maxChars`. The app reads previews only: 2000 for the thinking reconcile, the coding poll and the coding result, 8000 for the coding reconcile (enough to keep the `[run …]` marker after the ~5 KB contract), and 200 for the message IDs before a coding run. A run's reply carries `__openclaw.runId`; the admitted user turn has `idempotencyKey: "<run>:user"`. `sessionInfo.activeRunIds` / `hasActiveRun` show live runs. Claude Code session history ignores `limit` and can reach several MB. |
| `chat.message.get` | Whole final replies | `{sessionKey, agentId, messageId, maxChars: 1000000}`, operator.read, with `messageId` from the preview's `__openclaw.id`. Called only when the preview is marked `__openclaw.truncated`. Returns `message` with each text field up to 1,000,000 characters; a projected message over the 25 MiB payload limit answers `ok: false, unavailableReason: "oversized"`, and the app then keeps the preview. |
| `chat.abort` | Stop | `{sessionKey, agentId, runId, preserveSideRuns: true}`, with the coding key for coding work. Confirmed when `runIds` contains the run, or `aborted: false` (nothing with that ID is active, queued or pending). |
| `tools.invoke` | Live steer of a thinking step | `sessions_send` with `mode: "steer"` through the controller session, `idempotencyKey: "<work>-revision-<n>"`. Admitted only on `status: "accepted"` and `targetDisposition: "steered"` for the topic key. OpenClaw lists `sessions_send` in `DEFAULT_GATEWAY_HTTP_TOOL_DENY` (`src/security/dangerous-tools.ts`), so today it is refused and the change runs as a follow-up turn. |
| `sessions.diff` | Coding result | `scope: "uncommitted"` (the default compares to `origin/main`). Counts only what the worker left uncommitted, so it reads 0 files after the worker commits. |
| `config.get` | MCP mirror | Read once per app run for `hash` and the names under `config.mcp.servers`. |
| `config.patch` | MCP mirror | `{raw: "{\"mcp\":{\"servers\":{…}}}", baseHash, replacePaths, note}`, a JSON merge patch (`null` deletes). Needs operator.admin, which the CLI requests. `baseHash` must match `config.get`; `replacePaths` lets an `args` array shrink. Sent only when a `yorozu-*` entry differs. |
| `sessions.patch` | MCP overlay | `{key, agentId, toolOverrides, expectedToolOverrides}`. `toolOverrides` replaces the session's whole overlay, so the app sends the current one (from the `sessions.create` entry) with only `mcpServers` changed, and `expectedToolOverrides` fails the call if it changed meanwhile. Skipped when `mcpServers` already matches. Needs operator.admin. |

## Reading final replies

Yorozu sets no size limit on worker answers (owner decision, 2026-10-09). A thinking step's answer comes whole from the `agent` result. Where an answer is read from the transcript (thinking reconcile, coding result, coding reconcile), `chat.history` gives a preview and `OpenClawHarness.whole` fetches the message again with `chat.message.get` when the preview is marked truncated. Past that method's own limits the Gateway's marker shows as is. Any other failure of that fetch never passes the preview off as the answer: reconcile reports the run as unknown, and a coding result fails as uncertain so a later reconcile delivers it.

The reads do not use `chat.history` at its 500,000 maximum: a message over 128 KiB is dropped from `chat.history` whatever `maxChars` is, and with large texts the 512 KiB response budget keeps fewer of the newest messages, so a reconcile could miss the run's own turn. Small previews keep the response small and `chat.message.get` returns the one message needed.

Limits that remain: an `agent` response is bounded by the 2 MB stdout cap (8 MB frames on the native transport), a sub-chat event over 16,000 bytes keeps its last 8,000 characters, and phone frames follow [ios-relay-contract.md](ios-relay-contract.md).

## Compaction

OpenClaw's own compaction, memory flush and `contextPruning` are off in the Gateway config, so topic sessions grow until Yorozu compacts them (`compactTopic` in `Harness.swift`).

- Thinking: before each task, `sessions.describe` on the topic session. The window is `contextTokens`, capped at 258,400 (the usable part of the 272,000-token window, [setup.md](setup.md#the-projectx-agent)). When `totalTokens` is fresh and at least half that window, `sessions.compact` runs as its own call, outside the 240 s task. Success posts a `compaction` event in the sub-chat ("Compacted this topic's session: N → M tokens"). A failed check or compaction (a refusal or `compacted: false` included) posts a short `failure` message in the main timeline, and the task runs anyway.
- Thinking overflow: a step whose `agent` result has error kind `context_overflow` or `compaction_failure` triggers one forced compaction. The task fails with "…Yorozu compacted it, so asking again should now work." or, when that compaction fails too, "…Start a new topic for this request." Neither offers a retry.
- Coding: Claude Code and Codex compact their own sessions. OpenClaw exposes no compaction count, so `sessions.describe` runs on the coding session before and after the run; a changed `sessionId`, or a fresh `totalTokens` lower than before, posts a `compaction` event ("Claude Code compacted its session: N → M tokens"). An overflow, matched from the `agent.wait` error text, fails the task with "<tool>'s session ran out of context… start a new topic for this work."

## MCP servers

Yorozu owns the list of MCP servers its workers may use (`mcp-servers.json`, [setup.md](setup.md#mcp-servers)); OpenClaw only holds a mirror of it. OpenClaw cannot take a server definition per session (`toolOverrides.mcpServers` only switches configured servers on or off), so the mirror has two parts (`OpenClawHarness.mcpOverlay` and `applyMCP` in `Harness.swift`):

1. Once per app run, before the first topic or coding session is set up: `config.get`, then a `config.patch` that writes each listed server as `mcp.servers.yorozu-<name>` with `enabled: false` and deletes `yorozu-*` entries no longer listed. Nothing is written when the entries already match. The patch lists every array inside a changed or deleted entry in `replacePaths` and carries no `note`: a note leaves a restart sentinel that wakes the owner's main agent on the next Gateway start. `enabled: false` keeps them away from every other agent and session. The Gateway hot-reloads `mcp.*` with no restart (`src/gateway/config-reload-plan.ts`); the reload restarts live MCP runtimes in every session, which is why unchanged entries are not rewritten.
2. For every topic and coding session, once per app run: `sessions.patch` with `toolOverrides.mcpServers` set to `true` for each `yorozu-*` server and `false` for every other server configured when step 1 ran. A server the owner adds to OpenClaw while the app runs reaches Yorozu sessions until the next launch. A session override wins over `enabled` in both directions (`src/agents/bundle-mcp-config.ts`). Role sessions run raw (no tools) and the controller session runs no turns, so they get no overlay.

What each runtime sees:

- Embedded runs (thinking workers) and Codex read the overlay on every turn. Tools are deferred behind `tool_search`, named `<server>__<tool>` (for example `yorozu-cua-driver__type_text`) with catalog id `mcp:<server>:<name>`. Search queries must be English, and one batch may request at most 50 results.
- Claude Code (`claude-cli`) ignores the overlay: OpenClaw 2026.9.6 does not pass session `toolOverrides` to its CLI runner (`src/agents/command/attempt-execution.ts`, the `runCliAgent` call), so Claude Code sees only globally enabled servers and never Yorozu's.
- MCP calls on the embedded runtime have no approval step; `before_tool_call` plugin hooks still run.
- Plugin-bundled MCP servers that are not in `mcp.servers` are not covered by the overlay.
- A Codex session whose server set changes starts a new Codex thread ("MCP config changed; starting a new thread"). Re-sending an identical overlay changes nothing, so this happens once for sessions that existed before the mirror, then only when the list or OpenClaw's other servers change.
- Each session keeps its own stdio child per server (`cua-driver mcp` is a small proxy to the shared daemon) until the session is reset or deleted; `mcp.sessionIdleTtlMs` is unset.
- `openclaw mcp probe` refuses disabled servers, so it cannot health-check `yorozu-*` entries.

## Request receipts

Every `agent` call writes a `gateway-request` receipt before dispatch; if that write fails, nothing is sent. It holds correlation data only (request ID, session key, source message ID, raw-run flag, state), never prompts, output or credentials. States: `submitted`, then `terminal`, `admitted` or `uncertain`; `not-sent` when blocked locally; `rejected` for a refused model override. A failed call is reported with its request ID and never replayed automatically.

## What the agent sees

- `contextInjection: "never"` means OpenClaw injects no workspace bootstrap files (AGENTS.md and the like) into `projectx` runs.
- Claude Code and Codex read the CLAUDE.md or AGENTS.md on their own worktree branch. That branch is cut from `projectx` when the worktree is first created and is reused for later tasks in the topic without a rebase (`~/openclaw/src/gateway/session-worktree-preparation.ts`), and the coding contract forbids fetch and pull, so later `projectx` commits, docs included, reach it only when `projectx` is merged into the branch or the worktree is recreated.
- OpenClaw creates `AGENTS.md`, and can create `SOUL.md`, `IDENTITY.md`, `USER.md` or `BOOTSTRAP.md`, in an agent workspace when they are missing, and never overwrites existing files. The workspace is this checkout, so `AGENTS.md` stays tracked and present. The other template files, plus `TOOLS.md`, `MEMORY.md` and `memory/` (where OpenClaw's memory conventions write personal directives and facts), are gitignored.
- Workers inherit the global tool profile (full: shell, files, web). `subagents.allowAgents` is empty and `tools.agentToAgent.allow` does not list `projectx`.
- A global plugin on the host replaces the system prompt of non-raw runs with the owner's PAIOS bridge (a `before_prompt_build` hook). Raw runs (`modelRun: true`) have no tools and skip prompt-build hooks, so the secretary and extractor can read no files, calendars or PAIOS and must delegate questions about them. Thinking workers get the bridge. Whether coding runs (`claude-cli`, `codex`) get it depends on patched OpenClaw runtime modules that an OpenClaw update can overwrite; re-check after upgrading OpenClaw.
- Coding sessions load the owner's own Claude Code and Codex configuration; whether that stays is an [open item](status.md#open-items).
- Thinking and Codex sessions see exactly Yorozu's MCP servers, behind OpenClaw's `tool_search` / `tool_call` ([MCP servers](#mcp-servers)). OpenClaw never passes an MCP server's own instructions to the model, so worker prompts carry the cua rules.
- The OpenClaw config still enables v1's `yorozu` channel plugin, which v2 does not use.

## Native transport

Opt-in with `PROJECTX_TRANSPORT=native`. The toolbar gains "Connect native device", which opens an enrollment sheet.

- Protocol-4 WebSocket client registered as client id `webchat`, mode `ui`, role `operator`, scopes `operator.read` and `operator.write`, with its own Ed25519 key and a v3 signed device proof over the Gateway's challenge.
- Bootstrap: the Gateway's shared token or password is typed into a `SecureField`, used once and never stored. The Gateway may answer `PAIRING_REQUIRED`; approve that exact request on the host (`openclaw devices list`), then connect again. Only the app's key and the issued device token are kept ([Keychain items](setup.md#keychain-items)).
- It calls only methods the Gateway advertises, with a 270 s deadline per call. A disconnect fails pending calls as uncertain; nothing is replayed.
- Only this transport delivers live `agent` lifecycle and tool events, which the thinking worker projects into the sub-chat as they happen (tool names only, never arguments or text deltas).

## Probing the Gateway by hand

- Use `openclaw gateway call <method> --json --expect-url ws://127.0.0.1:18789 --params '<json>'` from a shell without the OpenClaw exec markers ([Launch environment](#launch-environment)).
- Use only `agentId: "projectx"` and throwaway session keys, and delete them afterwards with `sessions.delete {key, agentId, deleteTranscript: true}`.
- Leave other agents' sessions and the OpenClaw config alone: no reading, messaging or editing. The app itself writes only `mcp.servers.yorozu-*`.
