# OpenClaw whole-harness prototype

This adapter maps the private Yorozu harness protocol v1 to the **OpenClaw Gateway**, not to a model API. OpenClaw owns its secretary conversation, native inference loop, transcript and runtime state. The host owns UI/history projections, admission currency, process supervision and explicit OS resource isolation. Native memory, autonomy and approval decisions belong to OpenClaw. No Yorozu planner is inserted above OpenClaw.

The official base is `openclaw/openclaw` tag `v2026.9.8`, commit `fc23bc864e4553c2d215e479eeec47b67a0bf943`. The explicitly derived, locally signed source is `9bbdbaec153dd28fb452e6652c3dcacd829cb00f`, with [the narrow inherited-listener patch](upstream-inherited-listener.patch) SHA-256 `07febe324718e72b238d465bd33f5196d9c49f3aa864405d6587ba3d9b24c908`. This is not an untouched official release. Gateway protocol v4 is separate from the outer harness protocol v1. `productionReady` is false. Fake Gateway contract tests do not prove native execution, live subscription access, native UI integration, or interchangeability.

## Connected lifecycle and platform ownership

A trusted host may select `lifecycle:{version:1,mode:"connected",connectionId}` and private `connection:{version:1,connectionId,endpoint,nativeAgentId,sessionKey,sessionId,token,uiTargetId?}`. This is an explicit descriptor, never a chat-supplied address or ambient credential discovery. The first Mac-hosted slice accepts only numeric-loopback `ws://127.0.0.1:PORT/`, verifies pinned Gateway protocol/version and exact read/write scopes, and observes the exact existing native agent/session with `chat.history` plus native subscription. It never creates/resumes another session, launches a service, adopts a profile, writes native config or builds the denied runtime. Endpoint authentication does not prove model sign-in.

Ready echoes the host agentId and selected lifecycle. `extensions.connectedLifecycle:true` describes this implemented path, not live acceptance. `detach` closes only Yorozu's socket and returns `nativeStopped:false`; even `shutdown` in connected mode follows that path. No native abort/delete/shutdown method or child kill is issued. Managed mode retains the exact curated source/build and inherited-listener requirements below.

Managed bootstrap no longer forces heartbeat off, memory-provider none, bootstrap/context suppression, empty skills or fast mode. Native settings survive restart while host resources and broker bindings are reapplied. The managed zero-tool prototype still denies unsupported resource tools and does not enable scheduler/computer/auxiliary listeners. Host preference/shared-memory text is not injected into turns. Schema 2 owner markers migrate to stable schema 3 agent/runtime identity after current scope validation, so changing an explicit resource grant does not select fresh native memory.

`conversationActions`, `autonomousEvents` and `agentMessaging` extensions remain false: this pin's generic chat-send lane cannot invent trusted peer provenance, and no approved native action mapping has been proved. Message/action methods return `unsupported/not-submitted`; they do not become ordinary user prompts. General two-harness exchange and connected live service acceptance remain outstanding.

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
  "gatewayListener": {
    "transport": "inherited-fd-v1",
    "fd": 3,
    "host": "127.0.0.1",
    "port": 32146
  },
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

These fields are trusted local configuration, never accepted from chat or events. The host assertion does not create an OS sandbox: the host must actually confine the process and all descendants. Unknown scope fields, mismatched agent/isolation identity, symlinks, broad roots, unauthorized user workspaces and denied-root overlaps are rejected. The runtime directory must be separate from the agent's user workspace and memory. A zero-tool agent uses fresh scratch inside the host-granted vendor runtime, without adding user directory grants. One process exclusively owns one profile; a leftover lock is a recovery gate, not automatically discarded. Scope/version/agent ownership cannot silently change on resume.

The trusted host acquires a minted `HostListenerLease` through `acquireHostListener(agentId)`, compiles isolation with that held lease in `inheritedListeners`, and obtains `prepareHostListenerTransfer([lease], agentId)`. It spawns this adapter with the returned native descriptor in stdio slot 3 and joins `afterSpawn(child)` to close its parent copy. Only wire metadata `{transport,fd,host,port}` crosses initialize; an ID, asserted FD or restored JSON object cannot create a lease. `gatewayPort` must equal its port. This adapter duplicates FD3 into its native child, then closes its own copy. The curated native entry verifies the actual socket address before using it. The kernel denies new binds; ordinary `listenerPorts` grants and the stock Gateway launcher remain gated. There is no ephemeral or broad-network fallback.

The prototype disables **all native tools** with `deny: ["*"]` at global and agent levels. It can therefore accept a broader host tool allowlist while operating strictly below it. Host broker tools are not implemented and cannot be granted by widening OpenClaw's native policy. Channels, cron, heartbeat, browser control, memory plugins, skill loading, automatic updates, delivery, uploads, ambient environment and login-shell snapshots are disabled. No account setup, installed profile adoption, device pairing, scheduled actions or billed fallback is performed.

The launcher requires a clean exact curated checkout, the original public base object, matching patch digest, `dist/entry.js`, `dist/yorozu-gateway-embedding.js`, exact `dist/build-info.json`, normal `node_modules` and a supported real Node runtime with `node:sqlite`. Stock or dirty sources and official-base build metadata are rejected. It never downloads dependencies, builds, repairs configuration or invokes `doctor`. Package preparation is a separate authorized task; embedding does not flatten the runtime package.

The Gateway receives an adapter-generated token in this private profile, listens on loopback and accepts the generic upstream `gateway-client`/`backend` lane. The client requests only `operator.read` and `operator.write`, verifies them in `hello-ok`, and rejects extra scopes, device tokens or a mismatched Gateway version. Source authority for this local token lane is `src/gateway/server/ws-connection/handshake-auth-helpers.ts` and `connect-auth.ts` at the pin. No first-party native app identity is impersonated.

Fresh managed subscription onboarding is unsupported. Without an explicit local proof provider, `initialize` reports `auth.status: "unsupported"` and turns are refused before native handoff. An optional `providerConfigPath` must reference a bounded regular JSON file in this profile with only `{ "baseUrl": "http://127.0.0.1:<port>/v1", "model": "synthetic", "api": "openai-responses", "bearer": "<optional host-provided broker bearer>" }`. The host must bind a unique authenticated broker at that literal numeric address and exact port (1024–65535), include it in the process's broker policy, and provide the bootstrap itself. IP aliases, IPv6, credentials in the URL, alternate paths and ambient credential references are rejected. A supplied bearer is a bounded literal token used only by the native provider's authorization header and private runtime config; bootstrap errors never echo its value. Without a bearer, synthetic inference keeps its fixed dummy key and disables the auth header. This support proves no live model or subscription behavior and does not change the reported local-proof authentication status.

## Contract mapping

| Outer method/event | Native Gateway seam | Behavior |
| --- | --- | --- |
| `initialize` | `connect.challenge` → `connect` → `hello-ok` | Version/scopes/readiness verified; no planner or model calls. |
| `session.open` | `sessions.create` (managed) or `chat.history` (connected), `sessions.messages.subscribe` | Deterministic agent-prefixed session key, native session ID; no initial task/message/title request. Only adapter-owned sessions resume. |
| `turn.submit` | `chat.history`, `chat.send` | Exact native session/run currency, idle preflight, transcript branch CAS, `followup` queue mode, native-selected fast mode, suppressed command interpretation and native idempotency key. |
| `assistant.update` | Native `chat` delta/final events | Full host text assembled from actual native text; strict agent/session/run/sequence ownership. |
| `turn.started` | Exact native `started` receipt | An ACK is admission, not completion. Pre-ACK events are buffered. |
| `turn.terminal` | Native `chat` final/error/aborted | Completion/failure/Stop only from that run's terminal event; yielded runs stay unknown. |
| `run.stop` | `chat.abort` with exact run ID | Preserves side runs and pending unrelated input; ACK must name exactly the origin. `requested` waits for terminal evidence. |
| `task.steer`, `task.stop`, `request.answer` | No verified mapping yet | Cached `unsupported`, without native RPC mutation. |
| `session.snapshot` | Adapter-owned projection | Recorded current currency/text and empty task list; not a native history hydration or crash-resume claim. |
| `runtime.closed` | Native socket/shutdown/process exit | Active work becomes unknown; no success, resend, auto-reconnect or replacement is invented. |

`backgroundTasks`, `targetedSteer`, `taskStop`, `approvals`, `reconnect` and `attachments` are false. OpenClaw itself supports more features, but these capabilities cannot be claimed for this prototype without native ownership, exact-control, permission and recovery proofs. Scheduling and computer use remain disabled. `run.stop` is an exact conversation turn control, distinct from unsupported child-task Stop.

Adapter-owned `adapter-journal-v1.json` contains session bindings, input fingerprints, receipts and projections. Its schema 2 binds both official base and curated source; stock, earlier-schema and foreign patch journals are refused without native RPC. It is separate from OpenClaw's private state. Unknown send/control outcomes are reserved durably before handoff and cached; duplicate currency cannot replay execution even after adapter restart. A proven native busy preflight returns `handoff:"not-submitted"` and may be retried with the same input. A race after preflight can become queued or uncertain; neither is automatically retried. This is not an atomic native reject-if-busy guarantee.

OpenClaw alone owns native sessions/transcripts/model state. The host must retain portable app history/preferences and schedules across plugin switches. This slice does not import old harness transcripts, hydrate native history, implement switch/migration UI, enable native children or implement host broker bindings. On switch, unresolved old work remains tied to its original binding/process; never send its controls or retries into the new plugin. Rollback can select the original plugin while preserving app history and its original private profile.

## Validation and remaining gates

```sh
/absolute/task/node --test packages/harness-plugins/openclaw/adapter.test.mjs
```

The synthetic contract tests exercise wire parsing/handshake with a fake socket and adapter methods with a fake Gateway: explicit connected descriptor/identity checks, socket-only detach, identity filtering, duplicate currency, lost/queued/malformed ACKs, unknown caches, restart without replay, Stop receipt versus terminal, event gaps/yielded runs, strict scope/environment policy, derived-source identity, shipped patch digest and exact FD3 metadata. They are synthetic tests. Native build and confined inference are separate gates. Live subscription onboarding, packaged Mac/iOS integration, background tasks, child steer/Stop, approvals, native history hydration and broker-tool execution remain unproven.

`native-proof.mjs` is a prepared, unexecuted acceptance fixture. It constructs fictional agents through the host's real `PersonAgentStore`, derives zero tools, acquires real host listener leases, calls `isolatedAgentLaunch`, transfers actual descriptors and requires physical kernel checks before launching OpenClaw. It then checks native Gateway readiness, conversation history across two inference turns, exact Stop/provider cancellation, accepted-input deduplication and clean-restart non-replay. Its provider is local synthetic Responses inference only. It persists `evidence.json`; unsupported policy, lease, build, startup or lifecycle failures cannot become acceptance evidence.

## Curated inherited-listener route

The source patch is implemented and signed; its build and native Gateway acceptance remain blocked. This is a curated extension, not a supported upstream embedding API. The public base already has an internal `HttpServer` seam: `src/gateway/server-runtime-state.ts:73` accepts `testListener`, lines 135–149 validate address `127.0.0.1` and configured port, `src/gateway/server-http.ts:200` attaches native HTTP handlers, and `server-runtime-state.ts:539` skips the ordinary listen call. Native WebSocket handlers and the complete Gateway loop remain upstream-owned. The public base's startup options do not forward a listener; its `test-helpers.listener.ts:68` injects one with a Vitest spy. The plugin SDK exports clients, not a prebound-server startup API.

The independent kernel owner proved numeric-loopback inherited HTTP under the actual sandbox: host `BoundSocket.fd()` captured before server adoption, stdio FD3 duplication, parent close, real child HTTP response, non-loopback refusal, new IPv4/IPv6/wildcard and inherited-child bind denial, and peer file/memory denial. The production minted-lease/compiler path has a separate raw HTTP proof. These establish the descriptor mechanism, not OpenClaw execution. [Node's documented descriptor adoption](https://nodejs.org/api/net.html#serverlistenhandle-backlog-callback) and [server-handle transfer](https://nodejs.org/api/child_process.html#subprocesssendmessage-sendhandle-options-callback) explain the mechanism; the kernel canaries supply physical evidence.

The patch adds process-local `yorozuListener` to `src/gateway/server-public.ts`, forwards it as `testListener` in `src/gateway/server-start.ts`, and adds `yorozu-gateway-embedding` to `buildCoreDistEntries()` in `tsdown.config.ts`. `src/gateway/yorozu-embedding.ts` adopts only FD3, checks its OS-reported address/port, rejects early connections, and calls the patched `startGatewayServer`. It requires immutable loopback config with reload, restart, TLS, Tailscale, portal ingress and MCP app ingress disabled. There is no loader interception, factory spy, alternate port or Gateway outside the sandbox.

The manifest and launcher distinguish the public base from the signed derived source and patch digest. `prepareRuntime()` verifies exact HEAD, a clean tracked tree, the base-to-HEAD patch digest and curated build metadata. A newly applied patch has a different commit identity unless the exact signed source revision is retained; any new derived revision requires explicit repinning/review. Each upstream update requires inspecting the forwarding seam, endpoint validation, auxiliary listeners and close behavior again.

Until native transport adoption, the embedding startup owner closes the descriptor on failure. After adoption, the existing Gateway `httpServers` collection owns it; `src/gateway/server-close.ts:175` closes idle connections and the server, then forces remaining connections after a bounded grace period. `server-start.ts:118` caches close, and `server.ts:25` retains the Gateway lock until native close succeeds. The new entry reuses `createGatewayStartupOperations()` for cancellation/join, owns SIGTERM/SIGINT, treats SIGUSR2 as stop with failure, bounds startup to 60 seconds and shutdown to 20 seconds, and exits unsuccessfully on failed or timed-out cleanup. It has no internal restart loop. Startup abort, repeated close, stuck connections and native descriptor/lock closure still require actual process tests; fake Gateway tests do not establish them.

## Build evidence and blocker

The authorized frozen-lock install completed with lifecycle scripts disabled in an isolated task HOME/cache/store. pnpm's version-manager bootstrap added first-document lock entries; their diff was retained and the official lock restored. The signed curated checkout is clean. No `dist` directory exists. The source entry passed syntax transformation and formatting, but no native compilation or runtime acceptance has completed.

The exact task-local build command is `/Users/yumi/Documents/Codex/2026-10-04/task-5/tools/mise/installs/node/26.10.0/bin/node tmp/dependency-command.mjs build`, working directory `/Users/yumi/Documents/Codex/2026-10-04/task-5/harness-openclaw-adapter`. Its inspected recipe invokes the source's `scripts/build-all.mts sourcePerformance` through the official tooling loader, with isolated HOME, npm config, caches, Git config and temporary directories. This normal runtime build keeps the package graph; it omits declaration/UI work and is not a release build.

The default build failed fetching public pnpm registry signatures before the first build script. Automatic approval review rejected the escalated exact command, then rejected the one renewed attempt because the visible user-authored instruction remained read-only and delegated renewal was not accepted as authorization. Both rejected calls started no process. That precise build/native Gateway action is stopped; no alternate wrapper, pin-check bypass or execution route was used. Local evidence remains in `tmp/dependency-build-1791117083365.log`, `tmp/dependency-install-1791115655564.log`, `tmp/dependency-manager-lock-additions.patch` and `tmp/build-review-blocker.json`. Build authorization, a successful exact curated build and confined native process evidence are required before acceptance.

Primary upstream references: [embedding](https://docs.openclaw.ai/gateway/embedding), [Gateway client](https://docs.openclaw.ai/gateway/clients), [session RPC](https://docs.openclaw.ai/gateway/protocol/rpc-session-control), [protocol](https://docs.openclaw.ai/gateway/protocol), and [pinned source](https://github.com/openclaw/openclaw/tree/fc23bc864e4553c2d215e479eeec47b67a0bf943). Exact schemas are `packages/gateway-protocol/src/schema/{frames,logs-chat,sessions-create,sessions}.ts`; native semantics are in `src/gateway/server-methods/{sessions-create,chat-history-handler,chat-send-admission,chat-send-handler,chat-abort-handler}.ts` and native tool filtering in `src/agents/tool-policy-match.ts`.
