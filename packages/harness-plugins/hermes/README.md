# Hermes whole-harness adapter

This Node ESM adapter supervises the native Hermes JSON-RPC gateway. Hermes owns
secretary reasoning, delegation and child-result continuation; Yorozu only
translates typed events and exact controls. No chat-completions server, second
planner or Codex App Server sits above Hermes.

Pinned source: Hermes **0.21.5**, commit
`f97608f178d1ffeca59860195ab7da295f7c8e5f`. Initialization verifies the release
metadata, commit and tracked source cleanliness before launching
`python -m tui_gateway.entry`. Source checkout and a prepared Python environment
must be explicitly supplied; this adapter never installs or updates them.

## Host protocol v1

Run `node adapter.mjs`. stdin/stdout carry bounded NDJSON JSON-RPC 2.0; diagnostics
go to stderr (16 KiB maximum). Maximum frame: 256 KiB; 32 pending calls; upstream
write queue: 8 MiB. Gateway acknowledgements time out after 30 seconds and remain
uncertain. A timed-out action is never replayed.

`initialize` accepts `{protocolVersion:1, upstreamVersion:'0.21.5', profileRoot,
workspace, python, sourcePath, providerConfigPath?, provider?, model?}`. Paths are
absolute. The result declares plugin/version/capabilities and explicit auth status.
The first candidate supports only an explicitly supplied **synthetic loopback
proof provider**. Real subscription onboarding is unsupported and blocks session
creation before any installed auth/profile probe. There is no billed fallback.

For the local proof, place a JSON file inside `profileRoot`:

```json
{"baseUrl":"http://127.0.0.1:PORT/v1","model":"proof-model","apiMode":"codex_responses"}
```

Pass its absolute path as `providerConfigPath`. No token/key/environment fields
are accepted. A fixed dummy key is used for the synthetic provider. The inference
transport belongs to Hermes, including function calls and continuation.

Fresh native Hermes account onboarding (for example its supported `openai-codex`
provider) or an official app-token Responses bridge that preserves the Hermes loop
needs separate validation and authorization. Neither is implemented here. This
pin has no verified SIWC integration; Codex App Server would transfer ownership of
the loop and therefore does not validate this plugin. Installed auth is never imported.

The remaining methods are:

| Method | Important semantics |
| --- | --- |
| `session.open` | Host conversation/binding IDs; create or lazy resume of an opaque durable ID. Hidden preference/context seed on new sessions; no automatic crash replay. |
| `turn.submit` | Host run/attempt and text. Only native `streaming` acknowledges a fresh admission. Duplicate attempts reject; host must persist its admission journal before sending. |
| `task.steer` | Exact conversation/task/origin run/attempt/operation ID. `queued` means queued, never consumed. |
| `task.stop` | Exact native child interrupt. `requested` waits for native terminal evidence. |
| `run.stop` | Matching current turn or active children origin only. If other origin tasks would be interrupted, returns `unsupported`; exact child Stop remains available. |
| `request.answer` | Current server request only. Approval choices restricted to `once` or `deny`; no session/permanent grants. Single clarification supported. Secret/sudo/vault/native desktop and batch questions explicitly refuse. |
| `session.snapshot` | Current projection, task currency, event cursor and runtime status. Read only; no continuation. |
| `shutdown` | Ends the gateway; remaining execution without terminal evidence stays unknown. |

Notifications are `harness.event` with protocol version, conversation, optional
run/attempt, unique event ID, kind and data. Kinds: `assistant.update` (whole reply),
`turn.terminal`, `task.changed`, `request.open`, `request.cancel`, `runtime.closed`
and `capability.unavailable`. Hermes-owned continuation adds `turn.started` with
`{continuation:true,originRunId,resultTaskIds}` and a new opaque plugin attempt ID, followed by
normal assistant and terminal events. Child origins remain immutable after the
foreground completes. Internal native IDs never become Codex turn IDs.

`resultTaskIds` lists only the proven native delegation unit's top-level members;
the host retains pending results until the correlated continuation has terminal
evidence. A child becoming complete does not prove its result was delivered.

Continuation identity is verified against native inflight display metadata (or the
last durable native user row if already ended), keyed by `delegation_id`, once per
delegation unit. Child completion order does not authorize a turn. Main Stop fences
late child-result wakeups; unknown/unrelated native turns are interrupted and their
outcome remains explicit. Task Stop may still produce a cancellation summary.

New-session context uses upstream-supported hidden user scaffolding with an
explicit reference-only envelope and current-prompt requirement. Hidden system
history is omitted by the native Responses transport, so it cannot carry language
preferences. Opening a session never submits that scaffold for execution.

## Isolation and recovery

Runtime state is in a fresh marker-owned `profileRoot/hermes-runtime`, with fresh
`isolated-home` and `isolated-codex` directories. Environment inheritance is an
explicit allowlist. No old Hermes/Codex authentication, global `.env`, user profile,
external connection, persistent grant or scheduler is adopted. Configuration pins
standard tier, disables provider fallbacks and `desktop.auto_continue`, and enables
bounded nested delegation. Global disabled toolsets exclude `cronjob` and native
Hermes `computer_use`; no scheduler process is launched. Profile/config symlinks
are rejected.

Disabling `auto_continue` alone is insufficient: native restored delegation
completion polling can wake a parent. Therefore automatic recovery uses
`session.resume(lazy:true,omit_messages:true)` only. An explicit later user turn
may build the loop; the host must preserve and gate uncertain prior actions first.
Unknown outcomes never become successful/stopped simply because a process exited.
Native child timeouts also stay unknown: the upstream timeout path can defer
cleanup while its worker future remains alive, so `timeout` is not cessation proof.

The subprocess/environment boundary is **not an OS sandbox**. Before admitting
real remote providers, production must add and verify supported policy hooks and
native sandbox/permission isolation. Native `tool.start` events are observation,
not authorization. This candidate does not claim arbitrary model tools are confined
to `workspace`; real subscription/tool access remains blocked. The manifest marks
this candidate `productionReady:false`. Its JSON-RPC approval handshake supports
Hermes's native heuristic approvals, not universal host tool authorization.

Fresh main input has a native readiness preflight and forces queue behavior;
it can never silently become live steering of another turn. This pin has no
public atomic idle-only admission API. A native busy race can still produce a
queued acknowledgement after preflight: that outcome remains unknown and held,
without replay. Complete ownership of that race is an unresolved release gate;
the host also waits for observed autonomous attempts before dispatching its queue.

Hermes `session.interrupt` clears its prompt queues and origin-owned async children,
so it cannot serve as a selective per-turn cancellation when other origins coexist.
The current adapter fails that request explicitly rather than affecting unrelated
tasks. A later explicit conversation-wide Stop contract may authorize that scope.

## Validation

`node --test packages/harness-plugins/hermes/adapter.test.mjs` exercises native
framing and exact control/approval/recovery behavior using pinned upstream shapes.
Set `YOROZU_HERMES_TEST_SOURCE` to a pristine pinned source checkout to also verify
profile isolation and configuration. These tests do not prove a live model, OS
sandbox or production packaging; parent integration acceptance must run the real
gateway against a harmless synthetic provider and inspect the produced artifact.

Upstream reference: [`programmatic-integration`](https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration).
Exact implementation references at the pin: `tui_gateway/contracts/sessions.py`,
`contracts/events.py`, `server_requests.py`, `methods_subagents.py`,
`session_lifecycle.py`, `session_auto_continue.py`, `session_notifications.py`,
`tools/async_delegation.py` and `tools/delegate_tool.py`.
