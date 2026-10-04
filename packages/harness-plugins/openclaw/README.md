# OpenClaw whole-harness prototype

This adapter maps the private Yorozu harness protocol v1 to the **OpenClaw Gateway**, not to a model API. OpenClaw owns its secretary conversation, native inference loop, transcript and runtime state. The host owns UI/history projections, admission currency, process supervision, permission scope and the macOS sandbox. No Yorozu planner is inserted above OpenClaw.

The curated source is official `openclaw/openclaw` tag `v2026.9.8`, commit `fc23bc864e4553c2d215e479eeec47b67a0bf943`. Gateway protocol v4 is a separate version from the outer harness protocol v1. `productionReady` is false. Fake Gateway contract tests do not prove native execution, live subscription access, native UI integration, or interchangeability.

## Trusted initialization

The host launches this adapter inside its already-created per-agent `macos-seatbelt-v1` wrapper and sends:

```json
{
  "protocolVersion": 1,
  "upstreamVersion": "2026.9.8",
  "source": "/absolute/curated/openclaw",
  "node": "/absolute/curated/node",
  "agentId": "secretary",
  "workspace": "/private/secretary/workspace",
  "profileDir": "/private/secretary/runtime",
  "gatewayPort": 32146,
  "scope": {
    "allowedTools": ["file", "terminal"],
    "directories": [{ "path": "/private/secretary", "access": "write" }],
    "workspace": "/private/secretary/workspace",
    "memoryDir": "/private/secretary/memory",
    "deniedRoots": ["/private/another-agent"]
  },
  "isolation": {
    "backend": "macos-seatbelt-v1",
    "agentId": "secretary",
    "policyDigest": "<64 lowercase hexadecimal characters from the actual host policy>"
  },
  "platform": { "team": false, "computer": false }
}
```

These fields are trusted local configuration, never accepted from chat or events. The host assertion does not create an OS sandbox: the host must actually confine the process and all descendants. Unknown scope fields, mismatched agent/isolation identity, symlinks, broad roots, unauthorized user workspaces and denied-root overlaps are rejected. The runtime directory must be separate from the agent's user workspace and memory. A zero-tool agent uses fresh scratch inside the host-granted vendor runtime, without adding user directory grants. One process exclusively owns one profile; a leftover lock is a recovery gate, not automatically discarded. Scope/version/agent ownership cannot silently change on resume. `gatewayPort` is an exact host-selected listener port that must already appear in the kernel policy; there is no ephemeral or broad-network fallback.

The prototype disables **all native tools** with `deny: ["*"]` at global and agent levels. It can therefore accept a broader host tool allowlist while operating strictly below it. Host broker tools are not implemented and cannot be granted by widening OpenClaw's native policy. Channels, cron, heartbeat, browser control, memory plugins, skill loading, automatic updates, delivery, uploads, ambient environment and login-shell snapshots are disabled. No account setup, installed profile adoption, device pairing, scheduled actions or billed fallback is performed.

The launcher requires a clean exact-pin public checkout, `dist/entry.js`, exact `dist/build-info.json`, a normal `node_modules` installation and a supported real Node runtime with `node:sqlite`. It never downloads dependencies, builds, repairs configuration or invokes `doctor`. Normal package preparation is a separate authorized task; embedding does not flatten the runtime package.

The Gateway receives an adapter-generated token in this private profile, listens on loopback and accepts the generic upstream `gateway-client`/`backend` lane. The client requests only `operator.read` and `operator.write`, verifies them in `hello-ok`, and rejects extra scopes, device tokens or a mismatched Gateway version. Source authority for this local token lane is `src/gateway/server/ws-connection/handshake-auth-helpers.ts` and `connect-auth.ts` at the pin. No first-party native app identity is impersonated.

Fresh subscription onboarding is unsupported. Without an explicit local proof provider, `initialize` reports `auth.status: "unsupported"` and turns are refused before native handoff. An optional `providerConfigPath` must reference a bounded regular JSON file in this profile with only `{ "baseUrl": "http://127.0.0.1:<port>/v1", "model": "synthetic", "api": "openai-responses" }`. This config selects native OpenClaw inference against a loopback synthetic provider with a fixed dummy key. It proves no live model or subscription behavior.

## Contract mapping

| Outer method/event | Native Gateway seam | Behavior |
| --- | --- | --- |
| `initialize` | `connect.challenge` → `connect` → `hello-ok` | Version/scopes/readiness verified; no planner or model calls. |
| `session.open` | `sessions.create`, `sessions.messages.subscribe` | Deterministic agent-prefixed session key, native session ID; no initial task/message/title request. Only adapter-owned sessions resume. |
| `turn.submit` | `chat.history`, `chat.send` | Exact native session/run currency, idle preflight, transcript branch CAS, `followup` queue mode, `fastMode:false`, suppressed command interpretation and native idempotency key. |
| `assistant.update` | Native `chat` delta/final events | Full host text assembled from actual native text; strict agent/session/run/sequence ownership. |
| `turn.started` | Exact native `started` receipt | An ACK is admission, not completion. Pre-ACK events are buffered. |
| `turn.terminal` | Native `chat` final/error/aborted | Completion/failure/Stop only from that run's terminal event; yielded runs stay unknown. |
| `run.stop` | `chat.abort` with exact run ID | Preserves side runs and pending unrelated input; ACK must name exactly the origin. `requested` waits for terminal evidence. |
| `task.steer`, `task.stop`, `request.answer` | No verified mapping yet | Cached `unsupported`, without native RPC mutation. |
| `session.snapshot` | Adapter-owned projection | Recorded current currency/text and empty task list; not a native history hydration or crash-resume claim. |
| `runtime.closed` | Native socket/shutdown/process exit | Active work becomes unknown; no success, resend, auto-reconnect or replacement is invented. |

`backgroundTasks`, `targetedSteer`, `taskStop`, `approvals`, `reconnect` and `attachments` are false. OpenClaw itself supports more features, but these capabilities cannot be claimed for this prototype without native ownership, exact-control, permission and recovery proofs. Scheduling and computer use remain disabled. `run.stop` is an exact conversation turn control, distinct from unsupported child-task Stop.

Adapter-owned `adapter-journal-v1.json` contains session bindings, input fingerprints, receipts and projections. It is separate from OpenClaw's private state. Unknown send/control outcomes are reserved durably before handoff and cached; duplicate currency cannot replay execution even after adapter restart. A proven native busy preflight returns `handoff:"not-submitted"` and may be retried with the same input. A race after preflight can become queued or uncertain; neither is automatically retried. This is not an atomic native reject-if-busy guarantee.

OpenClaw alone owns native sessions/transcripts/model state. The host must retain portable app history/preferences and schedules across plugin switches. This slice does not import old harness transcripts, hydrate native history, implement switch/migration UI, enable native children or implement host broker bindings. On switch, unresolved old work remains tied to its original binding/process; never send its controls or retries into the new plugin. Rollback can select the original plugin while preserving app history and its original private profile.

## Validation and remaining gates

```sh
/absolute/task/node --test packages/harness-plugins/openclaw/adapter.test.mjs
```

The contract tests exercise actual wire frame parsing/handshake with a fake socket and adapter methods with a fake Gateway: identity filtering, duplicate currency, lost/queued/malformed ACKs, unknown caches, restart without replay, Stop receipt versus terminal, event gaps/yielded runs, strict scope and environment policy. They are labeled synthetic tests. Native runtime preparation and a confined loopback inference run are separate gates. Live subscription onboarding, packaged Mac/iOS integration, meaningful background tasks, child steer/Stop, approvals, native history hydration and broker-tool execution remain unproven.

Primary upstream references: [embedding](https://docs.openclaw.ai/gateway/embedding), [Gateway client](https://docs.openclaw.ai/gateway/clients), [session RPC](https://docs.openclaw.ai/gateway/protocol/rpc-session-control), [protocol](https://docs.openclaw.ai/gateway/protocol), and [pinned source](https://github.com/openclaw/openclaw/tree/fc23bc864e4553c2d215e479eeec47b67a0bf943). Exact schemas are `packages/gateway-protocol/src/schema/{frames,logs-chat,sessions-create,sessions}.ts`; native semantics are in `src/gateway/server-methods/{sessions-create,chat-history-handler,chat-send-admission,chat-send-handler,chat-abort-handler}.ts` and native tool filtering in `src/agents/tool-policy-match.ts`.
