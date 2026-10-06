# Minimal workers: first integrated replacement slice

Status: **opt-in source candidate, not a complete worker rewrite or release authorization**.
Base: reviewed `be87a28`. No installed profile, credential, account, app or relay deployment is changed.

## Design and ownership

The harness owns the execution loop, tool choice, delegation, continuation and native approvals.
Yorozu supplies transport, identity, bounded capabilities and durable receipts. There is no model
planner above the selected harness and no new agent SDK.

| Boundary | Keep / change | Source owner |
| --- | --- | --- |
| Encrypted relay, pairing, trusted device admission, outbox and history | Keep existing production transport and Rust storage; no wire fork | `serve.ts`, `scripts/secretary-production.patch`, `packages/shared`, `packages/host-core` |
| iOS/Mac UI and onboarding | Keep existing conversation/registry/task/action cards and pairing flows | `apps/ios`, `apps/mac`, `packages/shared-swift` |
| Accounts and inference | Keep existing protected helper/broker contract; this slice neither signs in nor probes providers | `native-account-*`, `siwc-*`, `curated-agent-runtime.ts` |
| Agent identity | Keep **one** durable `agents-v1` registry. Person IDs do not become harness IDs | `agent-store.ts`, `person-agent-controls.ts` |
| Adapter registration / selection | New small explicit host-code map; no marketplace, ambient discovery or fallback | `worker-platform.ts`, `secretary-serve.ts` |
| Execution supervision | Reuse the established isolation, lease, immutable admissions, current owner currency, task controls and unknown-outcome fences | `person-agent-runtime.ts`, `harness-process.ts`, `harness-runner.ts`, `harness-ledger.ts` |
| Memory and sharing | New uniform host-owned SQL source for every selected agent, behind bound capabilities | `worker-memory.ts`, `worker-tools.ts` |
| Native tool adaptation | Hermes tool calls are forwarded over the existing private child pipe, not interpreted as user prompts | `packages/harness-plugins/hermes` |

The retained supervisor is deliberately **not yet rewritten**. This slice replaces composition and
memory/tool ownership through that boundary, rather than replacing proven cancellation/recovery
with an untested new loop. The old coordinator remains only in the unselected legacy composition for rollback; selecting the
minimal composition requires an explicit secretary identity and has no planner fallback.

## Explicit selection

Trusted code calls `serveSecretary({ minimalWorkers: { adapters, initialAgent,
secretaryAgentId, resourceRoots, protectedRoots }, ...existingTransportOptions })`.
Each adapter has `{ id, label, memory: "worker-memory-v1", createFactory(store) }`.
The factory uses the existing pinned runtime and mandatory OS scope contract. For Hermes it can
wrap `createCuratedAgentRuntimeFactory(store, explicitlySelectedCuratedConfiguration)`; configuration
is still host-owned, and absence of an exact broker remains unavailable rather than an auth fallback.

`minimalWorkers` cannot be combined with a different `personAgentPlatform` or `nativeAccountHost`.
The regular packaged entry does **not** select it. No environment flag, relay message, model output,
registry patch or client-supplied command can activate this composition. The selected secretary
identity is mandatory and requires the existing quiescent migration check. In this composition the
legacy secretary coordinator is not started. Ordinary coding conversations retain their existing
runners and history; they are not silently converted into workers.

The shared native protocol currently names Hermes and OpenClaw. The central map handles independent
agents selecting those IDs, but **only Hermes has a uniform-memory native adapter in this slice**.
An OpenClaw descriptor alone is not implementation: a compatible reviewed adapter must explicitly
acknowledge the memory contract before any turn. Arbitrary third-party harness IDs require a later
coordinated registry/wire change, not a speculative universal SDK today. Connected external harnesses
are refused by this selection because their native memory authority is not controlled here.

## Memory contract

All selected agents use the same SQLite implementation. SQL rows are the canonical source; no
production notes are imported and no existing native/Markdown memory is rewritten. Search is bounded
lexical retrieval, not embeddings, semantic RAG, or a vector database. A search index, if introduced,
must remain rebuildable from the canonical notes, never a second source of truth.

The SQL root is host-only, excluded from every agent's OS file grants. The old native memory directory
is retained but denied to the new execution. Uniform mode disables native vendor memory; missing
adapter support fails closed. Native harness session context/history still belongs to its own isolated
profile; it is not a second implementation of the supplied durable memory tool.

`worker.memory` accepts only these discriminated operations:

- `read {ownerId,key}` and `search {ownerId,query}`: own notes, or individual explicitly shared notes.
  Search returns at most 16 snippets of 2,048 characters; use `read` for a whole note (up to 16 KiB).
- `write {key,body,operationId}`: the bound agent's namespace only; no foreign owner argument.
- `grant {toAgentId,key,operationId}`: a one-note read/search grant, requiring an exact one-shot owner
  approval using the existing `harness_action` card. No caller-supplied approval boolean is accepted.
- `revoke {toAgentId,key,operationId}`: remove that grant immediately; no approval is needed to reduce access.

Each mutation has a durable payload-checked operation identity. Replaying an old grant receipt after
revocation does not regrant access. Revocation is checked on every subsequent read/search; it cannot
make an agent forget text it already received or erase intentional independent copies. A grant covers
future updates to that note until revoked; the approval card states this explicitly. This first UI
bridge refuses notes larger than 6,000 characters for sharing, rather than asking approval for hidden
content. It does not offer wildcard grants or cross-agent writes.

The harness cannot select its actor identity: the host binds the memory capability to the registered
agent and owning confined process. Tool calls revalidate registration, memory-tool selection and current
scope. This first pipe contract additionally requires a current foreground attempt; calls after stop,
from an idle session, or from an autonomous-only continuation are refused rather than guessed onto a
new turn. Autonomous memory calls need a later explicit native work-provenance envelope.
Native tool/session ownership is also checked in the adapter. Team membership alone does not
share memory. Harness changes do not change SQL ownership.

## Approval, cancellation, errors and restart

The new pipe direction is restricted to `worker.memory`, bounded by the existing 256 KiB frame and
32-request window, with a bounded per-process ID set. Unknown methods, malformed frames, duplicate
transport IDs and unnegotiated calls cannot acquire a capability. Errors do not echo note content.
No tool call is automatically retried. Host shutdown aborts pending tool authority before closing pipes.

Sharing approval is anchored to one current conversation/session/epoch. Durable answer intent precedes
the SQL mutation; stale scope, changed note content, expired request or cancellation prevents the grant.
The approval window is bounded; a lost response is not permission to replay. Native harness tool
approvals remain native, not converted to global YOLO. Existing stop/steer, FIFO/admission and unknown
execution recovery contracts are unchanged.

Uniform mode has its own profile-selection key and marker. Old native profiles are preserved and are
not silently adopted; legacy selection cannot adopt a new uniform profile either. Existing unsettled
ledgers still block activation. Restart recovers memory and receipts but never resubmits uncertain work.

## Migration, rollback and retirement

1. Keep this source candidate off by default. Validate fresh temporary profiles through the assembled
   production entry and reviewed adapter. No production data or credential migration is part of the test.
2. Before any later adoption, verify no active/unknown turns, children, controls, continuations, queue
   entries or unreconciled legacy worker records. Explicitly select the host composition and agent binding.
3. Keep old registry/history/native profiles/receipts. New SQL state is additive; a new profile epoch
   prevents accidental adoption. A rollback changes only the trusted composition **after quiescence**;
   it does not automatically replay old work or translate SQL notes into vendor memory.
4. Retire legacy coordinator admission only after real adapter/provider, reconnect/stop/approval and
   physical native-client acceptance, plus explicit release authorization. Retain a read-only legacy
   history/recovery projection and rollback checkpoint before deleting old execution code. No deletion
   is included here.

Remaining product work includes native work-provenance for autonomous memory calls, a second real
uniform-memory adapter, connected-harness policy,
native account-host composition, longer approval UX/note viewer, production migration and recovery
reconciliation UX, real provider/device acceptance, and eventual supervisor/legacy-path retirement.

## Evidence boundaries

The October 6 local run is recorded in [verification/minimal-workers-20261006.json](verification/minimal-workers-20261006.json).
It tested code source `e3282e5` through the clean production assembly: 526 runtime tests passed
(6 optional skips), 84 adapter tests passed (6 optional native skips), 10 shared protocol tests,
22 exact isolated Rust cases, 9 staging tests and the explicit kernel file-isolation probe passed.
This includes the encrypted two-agent slice and the actual Hermes adapter/host-pipe bridge, not
live native/provider acceptance.

Run `worker-*` plus retained harness/person/registry/isolation tests against the **staged production
source**; raw checkout `serve.ts` does not contain the production decorator. `stage-internal-alpha.py`
and the internal gate explicitly include the new files and tests. Protocol peers and deterministic
adapter gateways are synthetic. Real pipes, SQL, kernel isolation and encrypted loopback relay tests
are local implementation proof, not live subscription, deployed relay or physical-device proof.

No release, tag, push, PR closure, deployment, installed-app replacement or branch cleanup is authorized
by this document. The prior release hold remains in force; separately blocked branch cleanup stays separate.
