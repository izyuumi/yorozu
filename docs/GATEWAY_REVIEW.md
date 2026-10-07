> **19:54 live-repair update:** dedicated `projectx` model probes succeeded; native client and installed API parsing repaired; 44 Swift tests pass. Waiting owner-independent app launch. Attribution prohibition below unchanged. See [LIVE_VERIFICATION.md](LIVE_VERIFICATION.md) for exact current status, enrollment facts and steering gate. Older Python terminal probe is historical, not the current native-app handoff.

> Later worker-file review: 60 tests pass; see [WORKER_MEMORY_WRITES.md](WORKER_MEMORY_WRITES.md). A real-filesystem/mock-transport tool bridge is implemented; no new live transport attempt or exec-marker bypass occurred.

> 18:10 approved-stack follow-up: the Swift-native app/adapter now exists; see [NATIVE_R1.md](NATIVE_R1.md) for native fixtures/build and remaining gates. **The attribution prohibition in this document remains controlling. No new live Gateway test or reauthentication was performed.**

> Subsequent bounded memory review: 42 tests now pass; see [TOPIC_KNOWLEDGE.md](TOPIC_KNOWLEDGE.md). No new live transport attempt was made and the Gateway attribution gate described here is unchanged.

# Configured Gateway review — 2026-10-07

## Correction to the first implementation report

The failed isolated `agent exec` calls were the wrong evidence for configured Gateway availability. They stripped ambient configuration and used `openai/gpt-6-astra` instead of the configured `openai-pool/gpt-6-astra`. They do **not** justify asking the owner to authenticate again.

`openclaw gateway call models.list --json` succeeded with ordinary CLI-resolved authentication. Only public model names/capabilities were used; no credential was read, copied or persisted. The configured catalog included Astra, Luna and Sol under `openai-pool`. Numeric model size is not specified by that catalog.

## Successful live native evidence (not app transport proof)

Fresh isolated, light-bootstrap attributed sessions, synthetic content only:

1. Secretary — `openai-pool/gpt-6-astra`
   - Run: `69f1306e-820a-4b21-abe3-ab9e95c3156f`
   - Session: `agent:coding:subagent:cefe8cc7-8437-4d99-81d8-756f77176325`
   - Spawn receipt: modelApplied=true, exact model/provider resolved.
   - Final: `{"action":"delegate","instruction":"Compute 17 + 25 and return only the integer.","topic_id":"synthetic-arithmetic"}`
2. Worker — same configured Astra, receiving that exact delegated instruction
   - Run: `a9aaa29c-b887-4e64-8e57-8a51c2cd7a0e`
   - Session: `agent:coding:subagent:670e0ede-7ee5-4fda-9ccd-975aadbc371b`
   - Final: `42`; actual response metadata provider/model matched.
3. Capable knowledge worker — `openai-pool/gpt-6-sol`
   - Run: `35df1125-287e-4bd5-babd-b6e28b012a8e`
   - Session: `agent:coding:subagent:c388b2d3-5193-4994-a6c0-805a78097955`
   - Final: “A memory system should retain source references when correcting a preference so the change can be verified against the original evidence and audited later.”
   - Actual response metadata confirmed Sol; terminal outcome ok.

All three completed. No existing personal sessions were inspected, no tools requested by these probes, no channel delivery. This proves configured live model access and basic secretary/delegated knowledge responses. **It does not prove the app's RPC transport, its exact schema prompts, semantic extraction quality or live steering.**

## Supported app interface implemented

Public installed docs and public TypeBox schemas were inspected, not invented endpoints:

- CLI: `openclaw gateway call <method> --json --params <JSON> --expect-final`.
- `--expect-url` pins the loopback target while preserving configured authentication. Unlike `--url`, it does not require copying an explicit token.
- Stateless secretary/extractor: `agent`, `modelRun=true`, `promptMode=none`, no delivery. Public implementation confirms raw model runs disable tools and do not import durable chat history.
- Task worker: `sessions.create` with fresh project key/cwd and read-only permission; then `agent` with `bootstrapContextMode=lightweight`, `promptMode=minimal`, no message delivery. This is a knowledge-text worker, not an action grant.
- Steering: `tools.invoke` → `sessions_send` with `mode=steer`, active-only. An independent fresh project controller session supplies attribution. Admission must say targetDisposition=steered. No fallback to `chat.send(queueMode=steer)`: that method can start a new full-bootstrap turn when the target becomes idle.
- `tools.invoke` is documented as sharing `/tools/invoke` policy, whose default deny list includes sessions_send. Actual configured exposure is **not yet tested**. No exposure/global-config changes were made.

Worker output carries `applied_revision`. A steer receipt is stored as accepted_not_confirmed. Only terminal output reporting the latest admitted revision advances it to applied_confirmed_by_output. That is model-reported incorporation of a text task, not verification of real-world effects. Older/unadmitted revision output remains stale. Transactions reconcile terminal-result-before-receipt races without duplicate answers. Each sub-chat keeps the same growing Gateway model session for its lifetime and steering; no custom compaction or periodic reconstruction is implemented. App input bounds do not claim to bound the complete retained harness history.

## Exact remaining test restriction

The attempted synthetic CLI `gateway call agent` from this child was rejected **before provider execution**:

> Gateway agent from agent exec would lose inter-session attribution. Use the attributed session-messaging tool available to this run, or return the result through normal subagent completion. Do not retry through another CLI route or remove the exec marker.

This is an **agent-exec caller-attribution policy**, not a provider login failure. It was respected: no environment-marker removal, alternative HTTP/RPC bypass or GUI-terminal escape. The adapter preserves it and tests assert it cannot launch a subprocess under that marker.

This child's native catalog exposes sessions_spawn and subagent status/history but not sessions_send (exact tool description returned unknown); the parent has a different effective tool surface. The repeated steering of this implementation child already demonstrates the broader harness can receive steering, but cannot be substituted for proof of this app's callable route.

### Smallest authorized next verification

In an ordinary owner terminal, using existing configured credentials:

```sh
cd /Users/yumi/Projects/PROJECTX
python3 probe_gateway.py
python3 probe_gateway.py --steer
```

No credential entry or config change is requested. If the strict-steer tool is refused, capture the sanitized refusal and decide whether a narrow exposure grant is authorized; the app will not make that change. The probe uses only fresh project sessions and never retries an idle target as a new task. Full R1 acceptance remains open until standalone roundtrip + actual same-task live steering are observed.

## Regression evidence

Current suite: **30 tests passed** before documentation refresh; Python/JS syntax checks passed. New tests cover raw Gateway contracts, preserved exec guard, strict-steer refusal/no fallback, exact wire-context snapshots, bounded one-step ambiguity escalation, no unresolved dispatch, semantic provenance/correction, memory-only forget/no replay, background topic stability and completion-before-steer-receipt reconciliation. Gateway transport tests use doubles and do not masquerade as live success.

## Message/progress delivery (16:49/16:51 clarification)

Implemented a capability-specific committed-message observer using supported chat.history on the exact fresh project worker session. It polls every two seconds, projects visible assistant messages and tool-name metadata only, persists source IDs/order with deduplication, and renders them in the inspect-only sub-chat. Main shows receipt acknowledgment and final answer, not intermediate events. Reasoning blocks, analysis-channel text, raw tool arguments/results and uncommitted live token snapshots are excluded; obvious credential-shaped text is withheld. No synthetic progress is generated.

This is **not** a claim to capture every ephemeral harness progress event: the POC polls up to 40 committed messages per snapshot rather than a long-lived WebSocket event subscription. Actual Gateway event delivery remains part of the ordinary-terminal live probe gate; projection/persistence/no-main-flood tests use explicitly labeled synthetic events. Current final suite: **30 tests passed**, 0.234 seconds; Python compilation/JS syntax checks passed. Current local HTTP smoke again returned 200 for the UI and 403 for cross-origin writes, then the server was stopped.
