# Minimal worker platform and packaged activation

Status: **packaged source candidate; native/provider/device acceptance and release artifact gates remain**.
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

The platform replaces composition and memory/tool ownership while retaining the proven
cancellation/recovery supervisor boundary rather than introducing an untested execution loop. The old coordinator remains only in the unselected legacy composition for rollback; selecting the
minimal composition requires an explicit secretary identity and has no planner fallback.

## Explicit selection

Trusted code calls `serveSecretary({ minimalWorkers: { adapters, initialAgent,
secretaryAgentId, resourceRoots, protectedRoots }, ...existingTransportOptions })`.
Each adapter has `{ id, label, memory: "worker-memory-v1", createFactory(store) }`.
The factory uses the existing pinned runtime and mandatory OS scope contract. For Hermes it can
wrap `createCuratedAgentRuntimeFactory(store, explicitlySelectedCuratedConfiguration)`; configuration
is still host-owned, and absence of an exact broker remains unavailable rather than an auth fallback.

`minimalWorkers` cannot be combined with a different `personAgentPlatform` or `nativeAccountHost`.
The internal packaged entry **does** select it through `packagedPersonAgentPlatform()` and the
existing native account host; there is one protected account/broker owner. Fresh/quiescent state
binds secretary identity `yorozu`. Unsettled legacy state receives a visible reconciliation hold
without service startup failure, history loss or legacy planner fallback. Controls receive durable
typed rejection receipts during that hold. The developer/older unselected composition remains
separate; no ambient flag chooses the packaged backend. No environment flag, relay message, model output,
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
scope. The private pipe requires `{execution:{sessionId,runId,attemptId},request:{...}}`, stamped
by the adapter from owned native tool calls, never from model arguments. The host accepts a current
foreground attempt or a verified harness-owned continuation. Continuation tool starts and requests
wait for the existing native identity probe. Plain envelopes, idle/unknown currency, wrong sessions
or attempts, and calls after Stop fail closed; no synthetic user turn or guessed foreground owner
is introduced.
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

1. The internal packaged composition selects the new backend. Validate fresh temporary profiles
   through the actual assembled entry and reviewed adapter before any distribution or normal-profile
   adoption. No production data or credential migration is part of source testing.
2. Before any later adoption, verify no active/unknown turns, children, controls, continuations, queue
   entries or unreconciled legacy worker records. Explicitly select the host composition and agent binding.
3. Keep old registry/history/native profiles/receipts. New SQL state is additive; a new profile epoch
   prevents accidental adoption. A rollback changes only the trusted composition **after quiescence**;
   it does not automatically replay old work or translate SQL notes into vendor memory.
4. Retire legacy coordinator admission only after real adapter/provider, reconnect/stop/approval and
   physical native-client acceptance, plus explicit release authorization. Retain a read-only legacy
   history/recovery projection and rollback checkpoint before deleting old execution code. No deletion
   is included here.

Remaining product work includes a second real uniform-memory adapter/connected-harness policy,
longer approval UX/note viewer, production migration/reconciliation acceptance, actual native
provider/device proof, and eventual physical deletion of legacy code after rollback custody is settled.
Packaged account-host composition and verified-continuation memory provenance are now wired.
The native client exposes Memory access only for the advertised managed capability; sharing and
revocation use its existing conversation and exact harness-action cards. A configured Mac host
defaults to menu-bar-only, while deliberate Open Yorozu/Settings and onboarding remain native.

## Evidence boundaries

The current source integration is recorded in [verification/minimal-workers-integrated-20261006.json](verification/minimal-workers-integrated-20261006.json) and `../HANDOFF.md`. It includes actual packaged selection/account composition, verified-continuation memory, native menu-bar/default policy, native memory settings and the four prepared patches. Local receipts:547 runtime passes (6 optional skips),86 adapter passes (6 optional native skips),10 shared,97 native plus the separately executed exact composer regression,22 final packaged/admission checks,9 staging and16 native-selector checks. The earlier isolated Rust22-pass receipt is retained with unchanged Rust sources. These are source/fixture proofs, not live native/provider/device acceptance. The first-slice `minimal-workers-20261006.json` remains historical.

Run `worker-*` plus retained harness/person/registry/isolation tests against the **staged production
source**; raw checkout `serve.ts` does not contain the production decorator. `stage-internal-alpha.py`
and the internal gate explicitly include the new files and tests. Protocol peers and deterministic
adapter gateways are synthetic. Real pipes, SQL, kernel isolation and encrypted loopback relay tests
are local implementation proof, not live subscription, deployed relay or physical-device proof.

The owner has conditionally authorized eventual internal TestFlight, GitHub alpha and normal-app
replacement; the parent owns those commit points. This document grants none independently. The
earlier artifact remains ineligible until final source review/CI, canonical-branch custody, regenerated
runtime provenance, real native/provider checks and native-client acceptance are verified. See
`../HANDOFF.md` for the acceptance matrix, exact local commands and bounded remaining test plan.
No push, release, install or branch-ref change is performed by this implementation worker.
