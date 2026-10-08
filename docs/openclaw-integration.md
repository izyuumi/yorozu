# OpenClaw integration

How the Mac app calls the local OpenClaw Gateway, and the Gateway behaviours the code depends on. The agent entry and models are in [setup.md](setup.md); what each worker does is in [architecture.md](architecture.md#workers). The Gateway's source is `~/openclaw`: method handlers in `src/gateway/server-methods/`, parameter schemas in `packages/gateway-protocol/src/schema/`. Read them rather than guessing the contract.

## Transport

The default transport runs the CLI once per call (`GatewayRPC.perform` in `Harness.swift`):

```sh
/usr/bin/env openclaw gateway call <method> --json --expect-url <target> --timeout 260000 --params '<json>' [--expect-final]
```

- `<target>` is `PROJECTX_GATEWAY_URL` or `ws://127.0.0.1:18789`; anything but a plain `ws`/`wss` URL on `127.0.0.1`, `::1` or `localhost` is refused. `--expect-url` pins the destination while the CLI keeps its own configured credentials.
- The child inherits the app's environment, with `/opt/homebrew/bin:/usr/local/bin` appended to `PATH` (a Finder launch's `PATH` lacks Homebrew).
- The process is killed after 270 s. Stdout is capped at 2 MB, or 16 MB for `chat.history`.
- Stderr is kept in memory (≤ 32 KB) only to pick a diagnostic category. A non-zero exit becomes `Gateway CLI failed [exit=<n>, category=<category>]: <code> <message>`, where code and message come from the JSON error envelope on stdout (the message is dropped if it looks like a secret). Categories: `model-override-not-authorized`, `caller-attribution-restriction`, `scope-denied`, `device-pairing-required`, `authentication-refused`, `request-schema`, `gateway-unreachable`, `gateway-target-mismatch`, `deadline-or-timeout`, `executable-or-runtime`, `unclassified-refusal-or-disconnect`. A CLI that cannot start reports `executable-unavailable`.
- Nothing streams over this transport: results and sub-chat progress arrive when a call returns.

`PROJECTX_TRANSPORT=native` switches to the WebSocket client in `NativeGateway.swift`; see [Native transport](#native-transport).

### Launch environment

`GatewayRPC.enforceAttribution` refuses every Gateway call, and live startup, when `OPENCLAW_SHELL=exec` or `OPENCLAW_SUBAGENT_EXEC` is set: the Gateway would lose inter-session attribution for a call made from an agent's exec shell. A dev app launched directly from a worker shell therefore cannot reach the Gateway. `build_native.sh` relaunches with `open -n`, which uses the login session's environment, so a restart run by a coding worker works. Keep the markers as they are; removing them or launching another way around them is not a fix.

## Sessions and runs

All sessions belong to agent `projectx`; the harness refuses any other agent and any worker session key outside `agent:projectx:projectx:`.

| Session | Key | `sessions.create` params | Runs in it |
|---|---|---|---|
| Role session (secretary, extractor, stronger review) | `agent:projectx:projectx-model:<sha256(<data root>/harness-workspaces\|<model>)>` | `model`, `permissionMode: "read-only"` | Raw runs: `modelRun: true`, `promptMode: "none"`, `deliver: false`, `timeout: 90`, `idempotencyKey: "projectx-<uuid>"`, `--expect-final`. Prompt ≤ 20000 bytes. |
| Topic session | `agent:projectx:projectx:<topicID>` | worker model, `permissionMode: "full"` | Thinking steps: `bootstrapContextMode: "lightweight"`, `promptMode: "minimal"`, `deliver: false`, `disableMessageTool: true`, `timeout: 240`, `idempotencyKey: "projectx-run-<uuid>"`, `--expect-final`. Message ≤ 32000 bytes. |
| Controller | `agent:projectx:projectx-control:<topicID>` | worker model, `permissionMode: "guarded"` | Only the `tools.invoke` steer call |
| Coding session | `<topic key>-claude` or `<topic key>-codex` | `agentRuntime: "claude-cli"` + `permissionMode: "full"`, or `"codex"` + `"workspace"`; `worktree: true`, `worktreeBaseRef: "projectx"`, `worktreeName: "<label slug ≤ 32>-<topicID first 6>-<executor>"` | One async run: `deliver: false`, `timeout: 7200`, `idempotencyKey: "projectx-code-<uuid>"`, no `--expect-final` |

- Each key gets `sessions.create` once per app run (concurrent first uses share the call; a failure retries next time). The directory `<data root>/harness-workspaces` only feeds the hash and is never created.
- OpenClaw names a coding worktree's branch `openclaw/<worktreeName>`. Claude Code needs `full` because its guarded modes need an approval client the app does not have; Codex `workspace` is sandboxed to the worktree.
- Before every thinking step and every coding poll the work's run ID is stamped in the Store; that write fails once the work is suppressed, which is how a stop reaches a running loop.

## Methods used

| Method | Used for | Notes |
|---|---|---|
| `sessions.create` | Every session above | Omit `idempotencyKey`: the Gateway accepts it only from a caller with a device identity or principal, and the CLI's shared-token connection has neither. Re-creating an existing key is already idempotent. |
| `agent` | Raw runs, thinking steps, coding runs | No per-turn `model`: a model override needs admin scope, so the model is chosen by creating the session with it. Text comes from `result.payloads` (the last non-reasoning payload, ≤ 64000 bytes); `terminalReply` (under `result` for session turns, `result.meta` for raw runs) is a 4096-character preview that only decides visibility. A raw run whose `result.meta.agentMeta` names another model gets its session re-created once, then fails. A coding start counts only when the response's `runId` matches. |
| `agent.wait` | Reconcile (`timeoutMs: 1`), coding poll (`timeoutMs: 20000`) | Forgets runs about 10 minutes after they end and on Gateway restart; unknown, rejected and evicted runs all look like a bare timeout. So reconcile also reads the transcript. |
| `chat.history` | Sub-chat progress, reconcile, coding results | Text blocks are cut at 8000 characters unless `maxChars` is raised (the app uses 64000 to read answers). A run's reply carries `__openclaw.runId`; the admitted user turn has `idempotencyKey: "<run>:user"`. `sessionInfo.activeRunIds` / `hasActiveRun` show live runs. Claude Code session history ignores `limit` and can reach several MB. |
| `chat.abort` | Stop | `{sessionKey, agentId, runId, preserveSideRuns: true}`, with the coding key for coding work. Confirmed when `runIds` contains the run, or `aborted: false` (nothing with that ID is active, queued or pending). |
| `tools.invoke` | Live steer of a thinking step | `sessions_send` with `mode: "steer"` through the controller session, `idempotencyKey: "<work>-revision-<n>"`. Admitted only on `status: "accepted"` and `targetDisposition: "steered"` for the topic key. OpenClaw lists `sessions_send` in `DEFAULT_GATEWAY_HTTP_TOOL_DENY` (`src/security/dangerous-tools.ts`), so today it is refused and the change runs as a follow-up turn. |
| `sessions.diff` | Coding result | `scope: "uncommitted"` (the default compares to `origin/main`). Counts only what the worker left uncommitted, so it reads 0 files after the worker commits. |

## Request receipts

Every `agent` call writes a `gateway-request` receipt before dispatch; if that write fails, nothing is sent. It holds correlation data only (request ID, session key, source message ID, raw-run flag, state), never prompts, output or credentials. States: `submitted`, then `terminal`, `admitted` or `uncertain`; `not-sent` when blocked locally; `rejected` for a refused model override. A failed call is reported with its request ID and never replayed automatically.

## What the agent sees

- `contextInjection: "never"` means OpenClaw injects no workspace bootstrap files (AGENTS.md and the like) into `projectx` runs.
- Claude Code and Codex read the CLAUDE.md or AGENTS.md on their own worktree branch. That branch is cut from `projectx` when the worktree is first created and is reused for later tasks in the topic without a rebase (`~/openclaw/src/gateway/session-worktree-preparation.ts`), and the coding contract forbids fetch and pull, so later `projectx` commits, docs included, reach it only when `projectx` is merged into the branch or the worktree is recreated.
- OpenClaw creates `AGENTS.md`, and can create `SOUL.md`, `IDENTITY.md`, `USER.md` or `BOOTSTRAP.md`, in an agent workspace when they are missing, and never overwrites existing files. The workspace is this checkout, so `AGENTS.md` stays tracked and present. The other template files, plus `TOOLS.md`, `MEMORY.md` and `memory/` (where OpenClaw's memory conventions write personal directives and facts), are gitignored.
- Workers inherit the global tool profile (full: shell, files, web). `subagents.allowAgents` is empty and `tools.agentToAgent.allow` does not list `projectx`.
- A global plugin on the host replaces the system prompt of non-raw runs with the owner's PAIOS bridge (a `before_prompt_build` hook). Raw runs (`modelRun: true`) have no tools and skip prompt-build hooks, so the secretary and extractor can read no files, calendars or PAIOS and must delegate questions about them. Thinking workers get the bridge. Whether coding runs (`claude-cli`, `codex`) get it depends on patched OpenClaw runtime modules that an OpenClaw update can overwrite; re-check after upgrading OpenClaw.
- Coding sessions load the owner's own Claude Code and Codex configuration; whether that stays is an [open item](status.md#open-items).
- The OpenClaw config also registers MCP servers used for R3 planning ([cua-integration.md](cua-integration.md)) and still enables v1's `yorozu` channel plugin, which v2 does not use.

## Native transport

Opt-in with `PROJECTX_TRANSPORT=native`. The toolbar gains "Connect native device", which opens an enrollment sheet.

- Protocol-4 WebSocket client registered as client id `webchat`, mode `ui`, role `operator`, scopes `operator.read` and `operator.write`, with its own Ed25519 key and a v3 signed device proof over the Gateway's challenge.
- Bootstrap: the Gateway's shared token or password is typed into a `SecureField`, used once and never stored. The Gateway may answer `PAIRING_REQUIRED`; approve that exact request on the host (`openclaw devices list`), then connect again. Only the app's key and the issued device token are kept ([Keychain items](setup.md#keychain-items)).
- It calls only methods the Gateway advertises, with a 270 s deadline per call. A disconnect fails pending calls as uncertain; nothing is replayed.
- Only this transport delivers live `agent` lifecycle and tool events, which the thinking worker projects into the sub-chat as they happen (tool names only, never arguments or text deltas).

## Probing the Gateway by hand

- Use `openclaw gateway call <method> --json --expect-url ws://127.0.0.1:18789 --params '<json>'` from a shell without the OpenClaw exec markers ([Launch environment](#launch-environment)).
- Use only `agentId: "projectx"` and throwaway session keys, and delete them afterwards with `sessions.delete {key, agentId, deleteTranscript: true}`.
- Leave other agents' sessions and the OpenClaw config alone: no reading, messaging or editing.
