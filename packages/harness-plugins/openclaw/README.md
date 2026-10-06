# OpenClaw whole-harness prototype

This adapter maps the private Yorozu harness protocol v1 to the **OpenClaw Gateway**, not to a model API. OpenClaw owns its secretary conversation, native inference loop, transcript and runtime state. The host owns UI/history projections, admission currency, process supervision and explicit OS resource isolation. Native memory, autonomy and approval decisions belong to OpenClaw. No Yorozu planner is inserted above OpenClaw.

The official base is `openclaw/openclaw` tag `v2026.9.8`, commit `fc23bc864e4553c2d215e479eeec47b67a0bf943`. The explicitly derived, locally signed source is `f04797ef4d24f3da0f9df74acd58ab773ab5f11e`, with [the full official-upstream-to-candidate patch](upstream-inherited-listener.patch) SHA-256 `601c2eea193de989977a122a98bda8653910848092f7c4937195e40bf63ebc4e`. This is not an untouched official release. Gateway protocol v4 is separate from the outer harness protocol v1. `productionReady` is false. Fake Gateway contract tests do not prove native execution, live subscription access, native UI integration, or interchangeability.

## DEVELOPMENT literal adoption and fresh-only migration

The corrected native candidate passed independent DEVELOPMENT review. This adapter now
sends only `inputMode:"literal"`; `/stop`, `/new`, command-like text and Unicode
remain exact user bytes. Stopping uses separately requested `chat.abort`, never text.
The paired device still requests only `operator.read` / `operator.write`.

`literal-migration.mjs` and `manifest.json` pin source, full upstream diff, build-info,
embedding entry, protocol schema, exact Node 26.10.0 binary and lockfile together.
The launcher verifies these runtime files before profile creation. Archive/manifest
digests are provenance references, not a claim of sealed dependencies: reused
node_modules remain unsealed and the native development archive is non-standalone.
Production readiness stays false; no memory capability completion is claimed.

**Migration policy: fresh-only, no in-place adoption.** Preserve earlier profiles,
owner markers and journals unchanged, stopped and snapshot-only. Do not rewrite an
old schema/source/build/mode to pass validation. Provision a distinct empty private
profile with a new host binding only for explicitly new work. Never copy uncertain
operations, replay old text or use fresh attempt IDs to evade an unknown outcome.
Old work requires evidence-backed recovery under its original binding; that recovery
is not implemented here. Current schema-3 journal restarts retain stable operation
IDs and unknown receipts without dispatch. Schema-4 owner identity and journal
identity both bind `literal-v1` plus the entire development pin set. Resource grants
can change only through current host scope validation, not profile identity changes.

Paired-device, host-tool approval/memory/isolation and embedding-owned stop/restart/
lifetime acceptance of the integrated candidate remain separate shipping gates.
No account, provider, installation, release or production change is authorized by
these development pins.

## Uniform host-owned memory (DEVELOPMENT integration)

With trusted `workerMemory: true` the adapter runs the `worker-memory-v1` contract
implemented by the self-contained native plugin package `memory-plugin/`
(bridge module plus plugin entry; see [MEMORY-BRIDGE.md](MEMORY-BRIDGE.md)). Only managed owned profiles with an empty resource scope or exactly
`["memory"]` are accepted; any other native tool stays disabled. The grant decides
whether the native plugin/tool exists at all:

- `effectiveRuntimeConfig` applies `uniformMemoryConfig` **after** the retained
  configuration merge, so a historical profile edit cannot merge a native memory
  provider, plugin or hook back in (memory slot `none`, search off, compaction flush
  off, context injection `never`, hooks off, plugin allowlist = the memory plugin).
- A granted agent's Gateway is spawned with one private duplex pipe at **FD4** beside
  the unchanged inherited FD3 listener; `attachMemoryHost` binds it to the bridge.
- Before every literal `chat.send` the adapter binds the exact native run ID, native
  session ID and session key to the host execution `{sessionId, runId, attemptId}` from
  trusted admitted context only (never model arguments or a latest-session lookup).
  Revokers live in RAM, never in the journal, and are invoked before `chat.abort`, on
  send uncertainty, yields, terminal events, connection loss and shutdown.
- `serve` routes host `worker.memory` receipts through `createAdapterMemoryClient`, so
  cancellation keeps its `{signal, assertCurrent}` authority through to the host's
  final synchronous approval/apply guard.
- Profile owner schema 5 and journal schema 4 bind `memoryContract`
  (`worker-memory-v1` or `native-retained-v1`): a profile prepared under one contract is
  never reinterpreted under the other; fresh profile only, no replay.

Native chat `seq` is the shared per-run agent-event counter (tool/item/status/lifecycle
events consume numbers and paced deltas are merged), so chat events are strictly
increasing but not consecutive. The adapter enforces ordering and takes the terminal
message as authoritative; a non-consecutive sequence is ordinary Gateway behaviour,
not an uncertain outcome.

`memory-gateway-proof.mjs` is the integrated acceptance fixture: actual host
`HarnessProcess` transport and `WorkerMemory` SQL, this adapter under the actual
per-agent sandbox, the actual pinned Gateway with the plugin loaded, ordinary paired
literal `chat.send`, and synthetic LOCAL loopback inference that emits `worker_memory`
tool calls. It proves the native catalog is exactly `[worker_memory]` for a granted
agent and empty for a zero-tool agent, dispatch reaching host SQL, two-agent private
isolation, rejected model-supplied identity, exact approval share, search, immediate
revoke, a Stop that fences a pending approval before SQL apply, lifetime after Stop,
embedding-owned stop/restart on the same profile, and kernel-level denial of the host
SQL and native memory paths. It does not exercise `PersonAgentRuntime`, the approval
card UI, a live provider/account, or a paired device; those remain separate gates.

## Connected lifecycle and platform ownership

**Connected lifecycle is held and disabled (`extensions.connectedLifecycle:false`).** The production launcher rejects a connected descriptor before opening a socket. The existing descriptor, fake-socket and detach seams remain only for inert contract regression fixtures. There is no proven connected durable reservation journal or restart lifecycle, so this candidate must not expose connected service access, messaging or an automatic fallback to managed launch. Endpoint authentication alone would not establish those guarantees.

Managed mode retains the exact curated source/build and inherited-listener requirements below and remains held, not production-ready. October 6 built and partially exercised the native runtime offline; the historical suppression blocker is superseded by DEVELOPMENT literal adoption; integrated native acceptance remains outstanding.

Managed bootstrap no longer forces heartbeat off, memory-provider none, bootstrap/context suppression, empty skills or fast mode. Native settings survive restart while host resources and broker bindings are reapplied. The managed zero-tool prototype still denies unsupported resource tools and does not enable scheduler/computer/auxiliary listeners. Host preference/shared-memory text is not injected into turns. Schema 4 owner markers bind the literal parsing contract and full development build identity. Old markers are refused: see the fresh-only migration policy below. Current resource scope is revalidated independently.

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

The prototype disables **all native tools** with `deny: ["*"]` at global and agent levels. It can therefore accept a broader host tool allowlist while operating strictly below it. Host broker tools are not implemented and cannot be granted by widening OpenClaw's native policy. Channels, cron execution, browser control, automatic updates, delivery, uploads, ambient environment and login-shell snapshots are disabled. Without the trusted uniform-memory selection this is **not native-memory suppression**: native memory plugins/skills and dormant heartbeat state may still initialize. With `workerMemory: true` the uniform configuration below replaces those settings. No account setup, installed profile adoption, scheduled execution or billed fallback is performed. Only the isolated client device is paired through native policy; no production device identity is adopted.

The launcher requires a clean exact curated checkout, the original public base object, matching patch digest, `dist/entry.js`, `dist/yorozu-gateway-embedding.js`, exact `dist/build-info.json`, normal `node_modules` and a supported real Node runtime with `node:sqlite`. Stock or dirty sources and official-base build metadata are rejected. It never downloads dependencies, builds, repairs configuration or invokes `doctor`. Package preparation is a separate authorized task; embedding does not flatten the runtime package.

The Gateway receives an adapter-generated token in this private profile, listens on loopback and accepts the generic upstream `gateway-client`/`backend` lane. The client requests only `operator.read` and `operator.write`, verifies them in `hello-ok`, and rejects extra scopes or a mismatched Gateway version. Managed launch signs the real challenge with its private isolated Ed25519 device; native pairing policy remains authoritative and any issued device token is ignored rather than retained. An unpaired wire-fixture client still rejects an unexpected device token. Source authority for this local token lane is `src/gateway/server/ws-connection/handshake-auth-helpers.ts` and `connect-auth.ts` at the pin. No first-party native app identity is impersonated.

Fresh managed subscription onboarding is unsupported. Without an explicit local proof provider, `initialize` reports `auth.status: "unsupported"` and turns are refused before native handoff. An optional `providerConfigPath` must reference a bounded regular JSON file in this profile with only `{ "baseUrl": "http://127.0.0.1:<port>/v1", "model": "synthetic", "api": "openai-responses", "bearer": "<optional host-provided broker bearer>" }`. The host must bind a unique authenticated broker at that literal numeric address and exact port (1024–65535), include it in the process's broker policy, and provide the bootstrap itself. IP aliases, IPv6, credentials in the URL, alternate paths and ambient credential references are rejected. A supplied bearer is a bounded literal token used only by the native provider's authorization header and private runtime config; bootstrap errors never echo its value. Without a bearer, synthetic inference keeps its fixed dummy key and disables the auth header. This support proves no live model or subscription behavior and does not change the reported local-proof authentication status.

## Contract mapping

| Outer method/event | Native Gateway seam | Behavior |
| --- | --- | --- |
| `initialize` | `connect.challenge` → `connect` → `hello-ok` | Version/scopes/readiness verified; no planner or model calls. |
| `session.open` | `sessions.create` (managed) or `chat.history` (connected), `sessions.messages.subscribe` | Deterministic agent-prefixed session key, native session ID; no initial task/message/title request. Only adapter-owned sessions resume. |
| `turn.submit` | `chat.history`, `chat.send` | Exact native session/run currency, idle preflight, transcript branch CAS, `followup` queue mode, native-selected fast mode, `inputMode:"literal"` (no privileged suppression, no normal fallback) and native idempotency key. |
| `assistant.update` | Native `chat` delta/final events | Full host text assembled from actual native text; strict agent/session/run/sequence ownership. |
| (no `turn.started`) | Exact native `started` receipt | The `accepted` receipt is the host's admission; `turn.started` is reserved for harness-owned continuations and is never emitted for an ordinary turn. Pre-ACK events are buffered. |
| `turn.terminal` | Native `chat` final/error/aborted | Completion/failure/Stop only from that run's terminal event; yielded runs stay unknown. Non-consecutive native `seq` is ordinary. |
| `run.stop` | `chat.abort` with exact run ID | Preserves side runs and pending unrelated input; ACK must name exactly the origin. `requested` waits for terminal evidence. |
| `task.steer`, `task.stop`, `request.answer` | No verified mapping yet | Cached `unsupported`, without native RPC mutation. |
| `session.snapshot` | Adapter-owned projection | Recorded current currency/text and empty task list; not a native history hydration or crash-resume claim. |
| `runtime.closed` | Native socket/shutdown/process exit | Active work becomes unknown; no success, resend, auto-reconnect or replacement is invented. |

`backgroundTasks`, `targetedSteer`, `taskStop`, `approvals`, `reconnect` and `attachments` are false. OpenClaw itself supports more features, but these capabilities cannot be claimed for this prototype without native ownership, exact-control, permission and recovery proofs. Scheduling and computer use remain disabled. `run.stop` is an exact conversation turn control, distinct from unsupported child-task Stop.

Adapter-owned `adapter-journal-v1.json` contains session bindings, input fingerprints, receipts and projections. Its schema 3 binds the literal-v1 contract, full pinned runtime identity, official base and curated source; stock, earlier-schema and foreign patch journals are refused without native RPC. It is separate from OpenClaw's private state. Unknown send/control outcomes are reserved durably before handoff and cached; duplicate currency cannot replay execution even after adapter restart. A proven native busy preflight returns `handoff:"not-submitted"` and may be retried with the same input. A race after preflight can become queued or uncertain; neither is automatically retried. This is not an atomic native reject-if-busy guarantee.

OpenClaw alone owns native sessions/transcripts/model state. The host must retain portable app history/preferences and schedules across plugin switches. This slice does not import old harness transcripts, hydrate native history, implement switch/migration UI, enable native children or implement host broker bindings. On switch, unresolved old work remains tied to its original binding/process; never send its controls or retries into the new plugin. Rollback can select the original plugin while preserving app history and its original private profile.

## Validation and remaining gates

```sh
/absolute/task/node --test packages/harness-plugins/openclaw/adapter.test.mjs
```

The synthetic contract tests exercise wire parsing/handshake with a fake socket and adapter methods with a fake Gateway: explicit connected descriptor/identity checks, socket-only detach, identity filtering, duplicate currency, lost/queued/malformed ACKs, unknown caches, restart without replay, Stop receipt versus terminal, sparse/stale native sequence numbers and yielded runs, strict scope/environment policy, derived-source identity, shipped patch digest, exact FD3 metadata, and the uniform-memory binding/revocation order against a fake bridge. They are synthetic tests. Native build and confined inference are separate gates. Live subscription onboarding, packaged Mac/iOS integration, background tasks, child steer/Stop, approvals, native history hydration and broker-tool execution remain unproven.

`native-proof.mjs` is an acceptance fixture; its October 6 partial native execution is documented below (the full acceptance remains failed). It constructs fictional agents through the host's real `PersonAgentStore`, derives zero tools, acquires real host listener leases, calls `isolatedAgentLaunch`, transfers actual descriptors and requires physical kernel checks before launching OpenClaw. It then checks native Gateway readiness, conversation history across two inference turns, exact Stop/provider cancellation, accepted-input deduplication and clean-restart non-replay. Its provider is local synthetic Responses inference only. It persists `evidence.json`; unsupported policy, lease, build, startup or lifecycle failures cannot become acceptance evidence.

## Historical October 6 native build and bounded execution result (pre-literal adapter)

The source-only build blocker below is superseded: exact curated source now builds offline with its supported `OPENCLAW_BUILD_ALL_NO_PNPM=1` route, network denied, no dependency fetch or signature/integrity bypass. Actual confined Gateway readiness, signed isolated-device pairing under native policy, session creation, exact subscription/history identity and clean shutdown were observed. **Historical inference blocker (not the current literal adapter):** the unchanged safety field `suppressCommandInterpretation: true` is rejected with `system provenance fields require admin scope`; that adapter requested only read/write. No admin scope, command-suppression removal, production Gateway, native source patch or capability enablement was attempted. `commands.text=false` does not disable text-command interpretation for this non-native-command surface. See [the exact follow-up report](../../../docs/verification/openclaw-native-build-gate-20261006.md).

The managed adapter now maintains a fresh private Ed25519 client identity in its owned profile; Gateway-generated device tokens are not retained or imported. Existing native pairing/approval policy remains authoritative. The optional trusted `git` initialize path selects a development verifier and its explicit read-only dependency closure; default `/usr/bin/git` behavior is unchanged. Shipping still needs sealed runtime input preparation, not an ambient developer toolchain.

## Curated inherited-listener route

The source patch is implemented and signed; its build and partial native execution are now proved, but integrated Gateway/inference acceptance remains pending; the historical denial below is preserved as evidence. This is a curated extension, not a supported upstream embedding API. The public base already has an internal `HttpServer` seam: `src/gateway/server-runtime-state.ts:73` accepts `testListener`, lines 135–149 validate address `127.0.0.1` and configured port, `src/gateway/server-http.ts:200` attaches native HTTP handlers, and `server-runtime-state.ts:539` skips the ordinary listen call. Native WebSocket handlers and the complete Gateway loop remain upstream-owned. The public base's startup options do not forward a listener; its `test-helpers.listener.ts:68` injects one with a Vitest spy. The plugin SDK exports clients, not a prebound-server startup API.

The independent kernel owner proved numeric-loopback inherited HTTP under the actual sandbox: host `BoundSocket.fd()` captured before server adoption, stdio FD3 duplication, parent close, real child HTTP response, non-loopback refusal, new IPv4/IPv6/wildcard and inherited-child bind denial, and peer file/memory denial. The production minted-lease/compiler path has a separate raw HTTP proof. These establish the descriptor mechanism, not OpenClaw execution. [Node's documented descriptor adoption](https://nodejs.org/api/net.html#serverlistenhandle-backlog-callback) and [server-handle transfer](https://nodejs.org/api/child_process.html#subprocesssendmessage-sendhandle-options-callback) explain the mechanism; the kernel canaries supply physical evidence.

The patch adds process-local `yorozuListener` to `src/gateway/server-public.ts`, forwards it as `testListener` in `src/gateway/server-start.ts`, and adds `yorozu-gateway-embedding` to `buildCoreDistEntries()` in `tsdown.config.ts`. `src/gateway/yorozu-embedding.ts` adopts only FD3, checks its OS-reported address/port, rejects early connections, and calls the patched `startGatewayServer`. It requires immutable loopback config with reload, restart, TLS, Tailscale, portal ingress and MCP app ingress disabled. There is no loader interception, factory spy, alternate port or Gateway outside the sandbox.

The manifest and launcher distinguish the public base from the signed derived source and patch digest. `prepareRuntime()` verifies exact HEAD, a clean tracked tree, the base-to-HEAD patch digest and curated build metadata. A newly applied patch has a different commit identity unless the exact signed source revision is retained; any new derived revision requires explicit repinning/review. Each upstream update requires inspecting the forwarding seam, endpoint validation, auxiliary listeners and close behavior again.

Until native transport adoption, the embedding startup owner closes the descriptor on failure. After adoption, the existing Gateway `httpServers` collection owns it; `src/gateway/server-close.ts:175` closes idle connections and the server, then forces remaining connections after a bounded grace period. `server-start.ts:118` caches close, and `server.ts:25` retains the Gateway lock until native close succeeds. The new entry reuses `createGatewayStartupOperations()` for cancellation/join, owns SIGTERM/SIGINT, treats SIGUSR2 as stop with failure, bounds startup to 60 seconds and shutdown to 20 seconds, and exits unsuccessfully on failed or timed-out cleanup. It has no internal restart loop. Startup abort, repeated close, stuck connections and native descriptor/lock closure still require actual process tests; fake Gateway tests do not establish them.

## Historical build evidence and blocker (superseded October 6)

The authorized frozen-lock install completed with lifecycle scripts disabled in an isolated task HOME/cache/store. pnpm's version-manager bootstrap added first-document lock entries; their diff was retained and the official lock restored. The signed curated checkout is clean. No `dist` directory exists. The source entry passed syntax transformation and formatting, but no native compilation or runtime acceptance has completed.

A prior task-local native build attempt was blocked before execution by authorization review. No native build or live Gateway evidence is supplied by this adapter hardening. Historical task-local logs are not release inputs or instructions to retry. Build authorization, a successful exact curated build and confined native process evidence remain required before acceptance.

## Review hardening (inert fixtures only)

Reservation persistence fsyncs the temporary file, renames it, then fsyncs the containing directory. A fsync failure cannot authorize handoff. Every existing-session reopen resubscribes on the current connection and requires `ok:true`; new turns are busy/not-submitted until subscription is acknowledged. Unknown outcomes still block new work and **never** become settled from history absence or an idle-looking snapshot. No automatic replay or replacement conversation is introduced. An explicit, evidence-backed recovery protocol remains outstanding.

Reply limits are presentation limits: actual encoded JSON-RPC size is checked, oversized projection is unavailable, and provider terminal evidence still arrives. Neither escaped text nor raw text overflow is permission to shut down/abort the native Gateway. The inherited descriptor must actually be a socket before spawning or closing FD3.

Synthetic fsync ordering/failure, dense escaped text, resubscription and held-launch fixtures are not power-loss, live lifecycle or production acceptance evidence. Managed journal cumulative capacity and unknown-outcome recovery still need a separately approved lifecycle design and native proof.
