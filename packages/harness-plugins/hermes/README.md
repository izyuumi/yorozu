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

Task and run controls return `unknown` when their acknowledgement is lost or
malformed. Repeating the same operation ID and currency returns that cached
receipt without another upstream call, even if the task has since settled.
`rejected` and `unsupported` require an explicit corresponding receipt or a
known refusal before handoff; neither means an uncertain Stop was declined.

`initialize` accepts `{protocolVersion:1, upstreamVersion:'0.21.5', profileRoot,
workspace, python, sourcePath, providerConfigPath?, provider?, model?}`. Paths are
absolute. The result declares plugin/version/capabilities and explicit auth status.
That legacy form is only for isolated synthetic fixtures. Product initialization
also requires the trusted host's `agentId`, immutable `scope`, and sandbox
attestation:

```json
{
  "agentId": "agent-a",
  "scope": {
    "allowedTools": ["file", "delegation", "team"],
    "directories": [{"path":"/owned/agent-a/workspace","access":"write"}, {"path":"/owned/agent-a/memory","access":"write"}],
    "workspace": "/owned/agent-a/workspace",
    "memoryDir": "/owned/agent-a/memory"
  },
  "isolation": {"backend":"macos-seatbelt-v1","agentId":"agent-a","policyDigest":"64-lowercase-hex-digits"},
  "platform": {"team":true,"computer":false}
}
```

The host constructs this configuration after applying its mandatory OS policy.
Supplying the attestation alone does not establish enforcement. Unknown tool
names, mismatched identity, unrepresented computer authority, broad filesystem
root grants and invalid directories refuse before process launch. Directory
paths are canonicalized; the workspace must match initialization. It must be in
an explicit directory grant or fresh scratch inside the owned profile root;
scratch is runtime plumbing and is never appended to effective tool grants.
Enabled private memory needs a canonical directory and write grant. With memory
disabled, its bounded absolute path is neither read nor granted. Initialize returns agent identity, scope
digest and the sandbox handshake. Turns, session opens and controls cannot
replace authority or runtime paths.

Supported native names are `file`, `terminal`, `delegation`, `memory`, `web` and
`browser`. They select their exact pinned native toolsets through
`HERMES_TUI_TOOLSETS`, with complementary disabled sets. The bootstrap verifies
actual registration and the gateway selection before entering the unchanged
native gateway. An explicitly registered empty set supports chat-only agents;
an empty list cannot fall through to native default/all tools. `team` enables
only the first-party platform tool. Computer-use and scheduler tools remain
disabled. Tool availability does not grant filesystem/network/exec access: the
host sandbox controls those, including read-only versus writable directory roots.

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
| `turn.submit` | Host run/attempt and text. Only native `streaming` acknowledges a fresh admission. Preflight `busy` with `handoff:'not-submitted'` consumes no attempt and permits bounded retry of that same host currency. An ambiguous handoff returns `unknown`; duplicate admitted attempts reject. Host must persist its admission journal before sending. |
| `task.steer` | Exact conversation/task/origin run/attempt/operation ID. `queued` means queued, never consumed. |
| `task.stop` | Exact native child interrupt. `requested` waits for native terminal evidence. |
| `run.stop` | Matching current turn or active children origin only. If other origin tasks would be interrupted, returns `unsupported`; exact child Stop remains available. |
| `request.answer` | Current server request only. Approval choices restricted to `once` or `deny`; no session/permanent grants. Team results additionally require exact originating conversation/binding/run/attempt. Single clarification supported. Secret/sudo/vault/native desktop and batch questions explicitly refuse. |
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

## Persistent agents and platform handoff

One native daemon and marker-owned profile belong to one persistent agent. The
ownership marker prevents adopting another agent's profile; configuration changes
for the same agent require host quiescence and a process restart with a new
sandbox policy. Scope is fixed for the process. A daemon multiplexes independent
conversation/binding/session records, including named threads managed by the host.
Serialize initial `session.open` calls per agent; subsequent native session
streams remain independently routed. Two live daemons must not write the same
profile. The host actor owns that lease and each conversation's durable journal.

Hermes memory, when enabled, stays inside that agent's own runtime profile. The
host `memoryDir` remains a separate private journal. Ephemeral Hermes children
inherit the origin's tool selection and OS authority, use fresh native sessions,
and the upstream blocks their memory tool. They never select another persistent
agent's profile.
When memory is disabled, native MEMORY/USER bootstrap flags are also false;
removing the tool alone would still inject retained profile memory. External
memory providers are excluded, and bootstrap verifies these flags before launch.

With `platform.team:true` and `allowedTools` containing `team`, the native plugin
registers `delegate_to_agent` in the single `yorozu_platform` toolset. Its strict
arguments are `{teammateId,context,expectedResult,scope:{allowedTools,directories,
sharedResourceIds?}}`. Context contains only the information needed for the task.
No command or attachment-path field exists. Requested tools and directory access
must narrow the origin scope; the host resolves canonical resources and further
intersects teammate authority before starting a fresh teammate conversation.
The model's scope is a proposal, never authority. The originating secretary owns
the final answer.

The pinned plugin API registers the native tool; the pinned gateway contract
registry declares `yorozu.team_delegate`, then `server_requests.send` waits for the
host. The adapter emits `request.open` with `kind:'team-delegate'`, typed input,
and originating run/attempt. Answer with the exact `conversationId`, `bindingId`,
`runId`, `attemptId`, `requestId`, and
`answer:{result:{status:'completed'|'failed'|'unknown'|'rejected',taskId?,text?}}`.
Only the still-current origin accepts that result. Native cancellation makes a
late answer stale. The wait is bounded at 120 seconds; timeout, cancellation or
lost acknowledgement yields `unknown` to Hermes with no automatic retry. The
native loop consumes the tool result and continues its own reply. This initial
bridge awaits a synchronous result; background persistent-agent result delivery
needs separate durable continuation ownership.

Ephemeral children cannot open this host handoff: their dispatch-injected durable
session identity differs from the current owning secretary. This avoids assigning
their requests to an unrelated foreground turn. A pinned native dispatch
ContextVar also carries the tool call ID; it must match an unclaimed native
`tool.start` recorded for that same current run. Completed, stopped or superseded
turns cannot lend their currency to a late request. This extra pinned internal
bridge needs revalidation when changing upstream versions. Recursive persistent-agent
handoff is owned by each recipient's separately scoped host runtime. Neither
the bridge nor the adapter reads teammate private history. A handoff that excludes
recipient memory must use a fresh task-local memory directory and profile; it
must not reuse that teammate's ordinary private journal.

Attachments remain unsupported. `turn.submit` rejects a nonempty attachment list
before any read or prompt handoff. The native staged-attachment APIs mutate a
session separately from prompt admission; scope validation alone cannot prove
atomic ownership through busy races. Capability metadata stays false until that
transport is verified.

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

Product agents require the host's mandatory macOS sandbox; legacy fixture mode
makes no OS confinement claim. Native `tool.start` events are observation, not
authorization. Host policy verification and real subscription onboarding remain
integration gates. The manifest marks
this candidate `productionReady:false`. Its JSON-RPC approval handshake supports
Hermes's native heuristic approvals, not universal host tool authorization.

Fresh main input has a native readiness preflight and forces queue behavior;
it can never silently become live steering of another turn. This pin has no
public atomic idle-only admission API. A native busy race can still produce a
queued acknowledgement after preflight: that outcome remains unknown and held,
without replay. Complete ownership of that race is an unresolved release gate;
the host also waits for observed autonomous attempts before dispatching its queue.
Only the typed preflight `busy`/`not-submitted` receipt permits a bounded host
readiness retry. Lost RPCs and queued/redirected native receipts never do.

Hermes `session.interrupt` clears its prompt queues and origin-owned async children,
so it cannot serve as a selective per-turn cancellation when other origins coexist.
The current adapter fails that request explicitly rather than affecting unrelated
tasks. A later explicit conversation-wide Stop contract may authorize that scope.

## Validation

`node --test packages/harness-plugins/hermes/adapter.test.mjs` exercises native
framing and exact control/approval/recovery behavior using pinned upstream shapes.
Set `YOROZU_HERMES_TEST_SOURCE` to a pristine pinned source checkout to also verify
profile isolation and configuration. Also set `YOROZU_HERMES_TEST_PYTHON` to its
prepared Python interpreter to exercise actual plugin discovery, exact scoped
schemas, empty chat scope, fail-closed registration and bounded tool dispatch.
These tests do not prove a live model, OS
sandbox or production packaging; parent integration acceptance must run the real
gateway against a harmless synthetic provider and inspect the produced artifact.

Upstream reference: [`programmatic-integration`](https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration).
Exact implementation references at the pin: `tui_gateway/contracts/sessions.py`,
`contracts/events.py`, `server_requests.py`, `methods_subagents.py`,
`session_lifecycle.py`, `session_auto_continue.py`, `session_notifications.py`,
`tools/async_delegation.py` and `tools/delegate_tool.py`.
Scope/tool/plugin references: `toolsets.py`, `model_tools.py`,
`hermes_cli/plugins.py`, `hermes_cli/plugins_discovery.py`,
`tui_gateway/contracts/registry.py`, `gateway/session_context.py` and
`tools/delegate_tool_toolsets.py`. Package `bootstrap.py` and `platform/` with
`adapter.mjs`, `manifest.json` and this README; no upstream source modification
or plugin install command is used.
