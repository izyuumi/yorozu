# Continuous chat and PAIOS memory: design v0.0

Status: proposal for review, 2026-09-30. **Design only; nothing here is implemented by this
change.** v0.0 labels this proposal, not an app version or release.

## Goal and scope

Yorozu should offer one continuous user-facing chat. People can change subjects, correct a
request, or start another request while work continues. They need not create, name, select,
or manage threads to keep the assistant coherent. Internal message relationships and task
state determine what each turn needs to know.

This is an independently scoped architecture proposal. It does not resume the paused issue
283 implementation, redesign screens, change runtime behavior, migrate data, or remove code.
It makes no claim about proprietary Dots internals; the design stands on the requirements
and existing Yorozu contracts alone. All examples below are synthetic. No personal PAIOS
corpus or private conversation content belongs in this document, fixtures, or GitHub.

The proposed ownership boundary is:

| Component | Proposed responsibility |
| --- | --- |
| Yorozu | Admit messages; resolve reply relationships; maintain the task state machine; assemble per-turn context; authorize dispatch; reconcile results; present the continuous chat. |
| PAIOS | Own durable knowledge, history, conversation/task records, provenance, correction history, and permission-filtered retrieval. Yorozu writes orchestration transitions through this persistence boundary. |
| OpenClaw | Initial isolated tool/task executor behind a replaceable adapter. Receive an explicit work package and return correlated events; do not govern the conversation's context or durable memory. |

PAIOS now means the **whole memory layer**: Markdown knowledge plus history, a conversation/task
database, and retrieval. The existing PAIOS folder is a corpus/handbook, not a complete runtime.
The design does not imply that a new PAIOS service, database schema, or API already exists.

## Current system and proposed boundary

The [current architecture](../architecture.md) and [channel contract](../../packages/openclaw-channel/README.md)
describe separate user-visible threads, JSONL conversation logs, an index, and OpenClaw sessions
associated with Yorozu threads. OpenClaw currently owns execution and conversational behavior
for its channel. Direct Claude Code and Codex integrations also exist. Some older memory and
orchestration code is [dormant](../legacy-runtime.md); its presence is not evidence that this
proposal is already supported.

The channel already has inbound IDs, run boundaries, exact-run cancellation, and durable final
reply correlation through `MessageData.replyTo`. These are useful starting points, not proof
that the existing adapter can accept a bounded context package without retaining unrelated
session history. In particular, current thread serialization must not become a global lock
on a continuous chat.

The target flow is:

```text
User message
  -> Yorozu admission and reply/task resolution
  -> PAIOS durable records and scoped retrieval
  -> Yorozu bounded context and execution plan
  -> OpenClaw adapter / initial executor
  -> Yorozu validation and reconciliation
  -> PAIOS durable outcome -> anchored answer in the same chat
```

Conversation storage and execution sessions are separate identities. A task can have an
isolated executor session without creating another user-facing chat. Isolation here requires
both context separation and an enforced capability boundary; a session ID or an owner-only
socket alone is not a sandbox. The concrete process/filesystem/network isolation remains
to be verified before enabling side effects.

## Three distinct relationships

| Relationship | Meaning | What it does not imply |
| --- | --- | --- |
| `reply_to` | A message points to its direct parent message. Ancestry explains what a reply or correction addresses. | Semantic similarity alone cannot establish a reply relationship. |
| Topic / mini-thread ID | Internal grouping of related conversational work, which can be revised as interpretation improves. A message can relate to more than one topic. | A topic label neither authorizes work nor identifies an executor run. |
| Task ID and attempt ID | A durable unit of requested work and one execution attempt. Each task names its originating message and current request revision. | A retry is not a new user request; executor IDs are not conversation identities. |

Each message has a stable ID, owner/host scope, role, accepted sequence, creation time, optional
`reply_to`, and provenance. A reply parent must exist in the same authorized scope; reject
cycles and cross-scope references. Messages may reference several tasks, but each execution
result must name the one task and attempt it belongs to. Topic membership is derived metadata.

An explicit user reply wins over inferred routing. Without one, Yorozu resolves ordinary
follow-ups against recent exchanges and active task state. Record the inferred relationship
and its confidence. If ambiguity could change an action or its destination, ask a plain
language question before dispatch. Do not ask users to choose an internal thread ID.

## Per-turn context

Build a new context package for each turn from:

1. The current user message and its attachments.
2. Its reply ancestry, with bounded summaries for older ancestors.
3. Relevant task state: current revision, accepted results, outstanding actions, and corrections.
4. Permission-filtered PAIOS knowledge/history relevant to this request.
5. A bounded recent-chat window for continuity and ambiguity resolution.

Do not send the entire conversation history by default. Budget these inputs separately;
preserve the current request, applicable restrictions, and unresolved corrections before
optional recent chat. If indispensable input cannot fit, retrieve a narrower source or ask
for clarification rather than silently dropping a constraint. Summaries carry source IDs
and revisions and can be invalidated; they never replace the durable originals.

Persist the context manifest: selected record IDs/revisions, retrieval scope, summary version,
budget policy, and omissions. It explains why a turn knew something without unnecessarily
duplicating sensitive content into debug logs. Concrete token limits and model/provider choice
for Yorozu's conversational reasoning remain verification items.

Retrieval scope is different from global knowledge. First filter by owner, authenticated host,
permissions, and applicable task/project scope; then rank relevance. A trip-specific budget
must not become a global spending preference. Global facts need an explicit global scope and
provenance; inferred preferences remain tentative. A task may retrieve an authorized global
fact without importing every other task's history. Do not combine private records across
paired hosts just because the UI presents one chat; the MVP uses one owning host.

## Concurrency, corrections, and late results

Persist every admitted user message immediately, even while another task runs. Independent
tasks may run concurrently within a small bounded capacity; the MVP can serialize execution
while still accepting and correctly associating interleaved messages. Work that changes the
same resource must serialize or detect revision conflicts. A new message does not implicitly
cancel all running work.

Use a minimal state machine: `queued -> running -> completed | failed`. A queued cancellation
can become `cancelled` without dispatch; running work enters `cancel_requested`, then becomes
`cancelled`, `completed`, `failed`, or `cancellation_unconfirmed` according to the actual outcome.
An unconfirmed cancellation can resolve when a matching terminal event arrives. Persist a
monotonically increasing task revision; superseding a request increments it and records which
revision became stale. Executor completion and acceptance of its result are separate decisions.

- A completion carries origin message ID, task ID, request revision, attempt ID, and stable
  result/event ID. Yorozu validates them before committing an outcome or presenting an answer.
- Show an asynchronous result in the current timeline with a short reference to its originating
  request and a way to reveal that request. Arrival time does not make it the answer to the
  newest message. Do not insert late messages into already-read history invisibly.
- A correction appends a linked revision/event; it does not silently rewrite the historical
  request. Rebuild dependent context and summaries. Superseded results remain attributable
  history, clearly marked as outdated, and cannot update current task state or current memory.
- Cancellation targets a specific task/attempt. Persist the intent before sending it. Await
  an actual outcome; a timeout means unconfirmed, not stopped. Reject new actions under an
  obsolete revision. Cancellation does not undo an already completed external effect.
- If a stale attempt already changed an external resource, report that effect and its uncertainty
  to the originating request. Do not hide it or automatically perform a compensating action
  without the appropriate authorization.
- A completion with no user origin, such as a scheduled action, needs a durable authorized
  trigger record. An unknown or invalid correlation is quarantined for reconciliation, never
  attached to the latest user message by guesswork.

## Ordering, idempotency, and recovery

Start with one authoritative host writer. Use a durable accepted sequence for chat events;
wall-clock timestamps describe timing but cannot order competing devices reliably. Preserve
per-attempt event order and distinct phases: accepted, dispatched, acknowledged, completed,
and result committed. Transport acknowledgment is not durable completion.

Atomically commit admitted messages/task transitions with an outbox entry. Deduplicate incoming
operations and executor results by scoped stable IDs, then commit the result and client delivery
intent before acknowledging it. Retries reuse the same identity. This provides at-least-once
transport with deduplicated records, not a promise of exactly-once external effects.

On restart, rebuild projections from durable records, resend pending outbox entries, restore
cancel intents, and reconcile running attempts with the executor. If dispatch may have caused
an effect before its acknowledgment was lost, query/reconcile using the same action identity;
if the adapter cannot establish the outcome, pause and tell the user. Never blindly repeat a
purchase, message send, or other irreversible action. Lost transient previews can be replaced
by durable finals. Executor disconnect must not erase accepted user messages.

## Storage, provenance, and trust boundaries

A local SQLite database for messages, tasks, revisions, an inbox/outbox, and a retrievable
history projection is a **candidate**, not a selected or implemented dependency. Markdown
remains the human-readable knowledge corpus. Use file revision/hash plus section references
to attribute retrieved text. Start with scoped lexical retrieval if adequate; embeddings and
a separate service require demonstrated need. Define a single authoritative store per record
type; do not create competing JSONL and database owners of the same task state.

Memory records retain source message/document/result IDs, author or producer, scope, observation
time, revision, and supersession links. An assistant inference and a user-confirmed fact are
different provenance classes. Corrections invalidate affected retrieval entries and summaries;
the current view prefers the corrected fact while history preserves the explanation. Retention
and explicit deletion must also cover derived indexes, cached context, executor copies, and
backups; append-only correction history is not a reason to retain deleted personal data forever.

Authorize retrieval and execution separately. Retrieved documents and tool results are data,
not authority to expand permissions. Give an executor only necessary context, an explicit
working scope and action capabilities, and short-lived access appropriate to the task. It must
not independently scan the whole PAIOS corpus or enroll all history into its own memory.
Credentials stay with their current credential owner unless a reviewed migration changes that.
Approvals bind to task revision, attempt, action, resource, and expiry; a correction or retry
cannot inherit permission to do a materially different action. Revalidate at the actual action
boundary so stopping or superseding work cannot race a previously approved action.

Preserve authenticated host identity, encrypted transport, and scoped client caches. Local
database/corpus encryption, key ownership, export, retention, and backup restoration need a
concrete policy before real personal data is migrated. Diagnostics should contain identifiers
and state transitions rather than raw prompts, corpus contents, or secrets.

## Staged MVP and verification gates

| Stage | Smallest useful scope | Exit gate |
| --- | --- | --- |
| 0: verify contracts | Use synthetic data to spike explicit context input, session isolation, result correlation, cancel/reconcile behavior, and storage transactions. | Prove that OpenClaw can execute the supplied package without hidden unrelated history or independent memory writes. If unsupported, revisit the adapter; do not present the old channel as this architecture. |
| 1: durable continuous chat | One owning host, one visible chat, reply links, internal tasks, bounded context, durable inbox/outbox; serialized execution is acceptable initially. | Interleaved-topic, late-result, duplicate-delivery, and restart scenarios below pass with deterministic record associations. |
| 2: safe concurrent work | Bounded parallel independent tasks, revisions, stale-result handling, exact cancellation, and scoped lexical memory with provenance. | Correction, cancellation, permission, and conflicting-resource scenarios pass before enabling side effects. |
| 3: simplify integrations | Evaluate replacing executor adapters and later removing direct Codex/Claude Code integrations to reduce stability burden. | A separately reviewed migration preserves existing conversations, results, approvals, and recovery; equivalent essential capabilities are demonstrated first. |

The removal of direct Codex/Claude Code integrations is future scope only. This proposal deletes
nothing and does not turn on a new orchestration path. Migration from current logs/sessions,
compatibility negotiation with older clients, rollback, and multi-host behavior require a
separate implementation plan before rollout. Consumer copy should say things like "Working",
"Stopped", or "This result belongs to your earlier request"; harness, adapter, executor,
mini-thread, and task-ID jargon stays out of the ordinary chat flow.

## Acceptance scenarios for future implementation

These are design criteria, not tests run by this documentation change.

| Scenario | Required observable outcome |
| --- | --- |
| Interleaved topics | Request A asks for a trip plan; B asks to summarize a document; a reply to A changes the trip date. A receives the date correction, B retains its own inputs, and neither requires switching chats. |
| Late completion | B finishes before A. Both answers appear in arrival order with their own request reference; A's late result cannot complete B or answer a subsequent C. |
| Ambiguous follow-up | Two active tasks could match "change it to Friday". Yorozu asks which request is meant before any action; unrelated messages remain accepted. |
| Correction during work | Correct A's revision 1 to revision 2, then deliver revision 1's result. Keep the original request and correction, mark the old result outdated, and leave revision 2's state/memory intact. |
| Cancel race | Cancel A while B continues, including a completion racing cancellation and a timeout. A shows the confirmed outcome or explicit uncertainty; B is unaffected, and completed effects are disclosed. |
| Duplicate delivery | Repeat the same user operation, completion, and acknowledgment after reconnect. Exactly one durable message/result exists; duplicates cannot create another task/attempt or imply a repeated external effect. |
| Conflicting resource | A and B both update the same synthetic document revision. Serialize the writes or detect the stale revision before committing; neither task silently overwrites the other's accepted change. |
| Restart | Crash after durable admission, after dispatch but before ack, and after result commit but before client delivery. Restore the same IDs and cancel intents, replay committed answers once, and pause uncertain side effects. |
| Retrieval and provenance | A task-specific synthetic budget stays out of another task; an authorized global preference can be retrieved. A later correction updates the current view and invalidates dependent summaries with traceable sources. |
| Permission and privacy | Reject cross-host reply links, unauthorized retrieval, expired approvals, and permission reuse after a material correction. Raw private text stays out of diagnostics and GitHub. |
| Adapter boundary | Replace OpenClaw with a fake executor returning the same correlated contract. Reply ancestry, context selection, task reconciliation, and durable records remain owned by Yorozu/PAIOS. |

## Decisions still requiring evidence

1. Whether the installed OpenClaw SDK can supply stateless or task-isolated execution, bounded
   explicit context, capability enforcement, and reconciliation across a Gateway crash. Verify
   the actual version/API; no feasibility guarantee is made here.
2. Where Yorozu's conversational reasoning runs, how it obtains model access, and which context
   budget/routing policy is sufficient. Do not make the executor's hidden session the fallback
   source of conversation truth.
3. SQLite versus extending the existing durable log, transaction/recovery details, the PAIOS
   read/write boundary, corpus revision tracking, and eventual schema/migration ownership.
4. Privacy/retention and encryption keys, backup/delete semantics, approval enforcement, and
   host scope. The initial single-host boundary must be maintained until federation is designed.
5. Inference confidence and clarification behavior, topic reassignment, concurrency limits,
   and display anchoring. Validate with the synthetic scenarios before investing in richer UI.
