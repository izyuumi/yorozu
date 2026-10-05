# Hermes whole-harness adapter

Hermes owns reasoning, memory, learning, autonomous continuation and native approval choices. Yorozu hosts the native process and transports conversation, action and peer-message projections. It inserts no model loop or planner above Hermes.

This candidate pins Hermes 0.21.5 at `f97608f178d1ffeca59860195ab7da295f7c8e5f`. Initialization verifies metadata, exact commit and tracked source cleanliness. It never installs, updates, adopts an installed profile or reads ambient credentials. `productionReady:false` remains intentional.

## Process and resource ownership

The private NDJSON JSON-RPC protocol remains 1, with negotiated `extensions.version:1`. Frames are bounded to 256 KiB, pending calls to 32 and acknowledgements to 30 seconds. Lost or ambiguous acknowledgements stay unknown and are never replayed automatically.

Product initialization requires explicit `agentId`, marker-owned `profileRoot`, `workspace`, `python`, `sourcePath`, immutable directory/tool resource scope and the host's `macos-seatbelt-v1` handshake. A handshake is not physical sandbox evidence. Profiles and configuration must not traverse symlinks. Isolated HOME/CODEX_HOME and an environment allowlist prevent installed account/profile discovery.

`lifecycle:{version:1,mode:"managed"}` owns the gateway process. `shutdown` ends that owned gateway. Hermes connected lifecycle is unavailable and is rejected before connecting: the pinned WebSocket disconnect path can orphan-reap a session when its final peer leaves. Yorozu cannot promise safe external-session ownership using that seam. Authority: `tui_gateway/ws.py`, `session_transports.py` and `session_lifecycle.py` at the pin.

Explicit `file`, `terminal`, `web` and `browser` grants select supported resource toolsets. Private native memory and delegation are not governed by legacy Yorozu feature flags. Their configuration belongs to Hermes; state remains inside the agent's private runtime. A chat-only resource selection therefore still exposes native memory/delegation while granting no user files, terminal or network resources. The bootstrap verifies the exact selected model catalog without an empty-selection/all-tools fallback. Native children inherit the host OS resource boundary.

Fresh configuration does not set manual approvals, disable auto-continuation, force delegation limits, priority tier or a current-user-only prompt. Restarts preserve native behavioral configuration and registered plugin settings while reapplying the host's resource/broker bindings. Known prototype-generated memory/delegation denials migrate away; other native non-resource disabled toolsets remain intact. Scheduler/computer tools remain unavailable because their host resource integration is not implemented.

## Conversation and actions

The host supplies one canonical conversation per agent. Legacy native sessions remain lazily resumable for retained history. `session.open` never injects host preference/shared-memory text, sends a task, resets native memory or interrupts an active native session. An observed running session is projected as unknown until native identity/idle observation can reconcile it.

`turn.submit` forwards only actual user text. Native idle preflight yields a truthful `busy/not-submitted` receipt; native busy races, queued/redirected acknowledgements and losses remain unknown. Native Responses inference still requires an explicit isolated loopback provider bootstrap; fresh subscription onboarding is unsupported. No installed authentication or billed fallback is probed.

Native `approval` and single `clarify` requests become `action.open` with exact native choices and owning session identity, even outside a host foreground turn. `action.answer` requires that identity and an offered choice, or native-supported text. Session/permanent approval choices are preserved when Hermes offers them; the adapter never invents or selects them. Native withdrawal becomes `action.cancel`. Legacy boolean `request.answer` remains only for protocol compatibility. Secret/sudo/vault, batch questions and native desktop bridges remain unsupported; no credential entry or unverifiable UI target is created.

Exact task/turn Stop and Steer retain operation IDs and native receipts. A native timeout or process exit is not proof of cessation. Native continuation projection needs an exact delegation origin; unavailable projection currency or an oversized reply does not cause a platform interrupt. Autonomous rendering beyond correlated delegation remains unverified and `autonomousEvents:false` is honest.

## Persistent-agent messaging

`platform:{team:true,computer:false,peers:[{agentId,name,pluginId}]}` is trusted host-selected membership, independent of legacy behavior flags. It grants no files or tool authority. The native platform plugin registers `send_agent_message` and `read_agent_messages` through the pinned plugin/contract registry. The previous `delegate_to_agent` tool is removed; legacy execution-handoff requests are rejected without starting another agent.

A native message tool carries dispatch-injected durable/live session and tool-call identity. The adapter checks its actual native `tool.start` before emitting `agent.message`. The outgoing event deliberately has no sender/origin fields: the host derives those from its authenticated binding. Only selected peers are available. `message.receipt` settles admission after the host durably accepts the message; it does not wait for a peer's execution or answer. The 30 second native wait bounds that receipt only. Caller Stop/cancellation never cancels already delivered recipient work.

`message.deliver` accepts the host-stamped public exchange, stable deliveryId, attemptId and destination native session. It validates origin/sender, explicit peer membership and recipient identity. Acceptance follows fsync of the separate adapter transport inbox, meaning custody only. Content deduplication excludes transient attempt/native-session IDs and rejects identity reuse with different text/origin. No peer data is submitted as a fake user turn or native execution request.

Hermes chooses when to call `read_agent_messages`, what to share and whether to reply using exchangeId. Reads page at most 4 messages of 32 KiB to honor the frame bound. Stable entries may recur; the harness owns interpretation. The native inbox retains at most 64 records without silent expiry; a full inbox returns `busy/not-submitted`, leaving durable custody with the host. It is transport state, not a shared-memory store. General OpenClaw peer delivery lacks a verified native provenance seam and remains unavailable; a live two-harness exchange is still an acceptance gate.

## Validation

`node --test packages/harness-plugins/hermes/adapter.test.mjs` uses synthetic native protocol fixtures. It verifies typed choices, exact control receipts, no fake peer turns, durable inbox/restart deduplication, native tool/session identity and unsafe connection refusal. Optional source/interpreter tests require separately authorized `YOROZU_HERMES_TEST_SOURCE` and `YOROZU_HERMES_TEST_PYTHON`; ordinary protocol runs leave them unset. Fixtures do not prove native discovery, model/subscription access, OS sandbox enforcement, native UI or product acceptance.

Native seams: `tui_gateway/contracts/{sessions,prompt_voice,server_requests,events}.py`, `tui_gateway/server_requests.py`, `methods_subagents.py`, `session_notifications.py`, `hermes_cli/plugins.py`, `gateway/session_context.py`, `tools/approval_context.py`, `tools/registry.py` and `toolsets.py`. Package `bootstrap.py`, `platform/`, `adapter.mjs`, `manifest.json` and this README together; changing them invalidates earlier packaged-adapter digests and requires a new verified runtime artifact before delivery.
