# Whole-harness plugin candidate

This opt-in development path retains native SwiftUI, encrypted device connections,
visible history and ordinary coding sessions. Hermes owns the secretary loop,
delegation and result continuation. The legacy JSON coordinator is used only when
no harness plugin is selected. No model classifies or plans above the plugin.

## Process and language boundary

The existing Node host uses TypeScript supervision and a small durable JSON ledger.
It reuses the existing Rust core's kernel-backed lease in a plugin-only store;
the production history writer remains unchanged. It does not add a Rust harness
runtime or migrate history. A supervised Node adapter speaks the
upstream's public stdio JSON-RPC to native Python Hermes. SwiftUI sees normalized
conversation/task metadata. The iOS app remains a client of its paired Mac.

The first-party adapter is pinned to Hermes 0.21.5, tag `v2026.9.24`, commit
`f97608f178d1ffeca59860195ab7da295f7c8e5f`. Python must be >=3.11,<3.14;
the development proof uses Python 3.13 and the upstream frozen lockfile. Packaging
includes the adapter, manifest and provenance, not an installed Python profile.

## Contract v1

Private newline-delimited JSON-RPC 2.0 on dedicated stdin/stdout; stdout carries
protocol only. Frames are bounded to 256 KiB and 32 simultaneous requests.
Transport request IDs are unrelated to durable admission or control IDs.

A readonly native-busy preflight returns `busy` with `handoff: not-submitted`.
The host retains that accepted input and retries the identical execution currency
for at most 30 seconds. An actual upstream queue/redirect race or lost receipt is
`unknown`, which is never retried. Native atomic busy admission remains a release
gate. Lost task-control receipts are also `unknown`; they cannot become a known
rejection or be sent again under the same accepted operation.

- `initialize`: protocol/version/readiness and effective capability negotiation.
- `session.open`: stable conversation plus binding epoch, optional private durable
  session reference, bounded reference-only history and explicit preferences.
- `turn.submit`: immutable run/attempt plus current user input. An accepted receipt
  is not terminal execution proof.
- `task.steer`, `task.stop`, `run.stop`: exact current owner currency and immutable
  operation ID. Queued guidance and requested cancellation remain distinct from
  consumed guidance and terminal execution.
- `request.answer`: current request-only decisions. Denial or one-shot approval;
  no persistent upstream allowlist, secret collection or authorization widening.
- `session.snapshot`, `shutdown`: owned runtime inspection and closure.

`harness.event` carries protocol version, event ID, conversation, owned run and
attempt, kind and bounded data. Events cover whole-reply updates, actual terminal
states, child lifecycle, server questions, runtime closure and harness-owned
continuation attempts. Continuations remain anchored to the original user event;
correlated result-task IDs establish which pending results were delivered.

## Persistence and uncertainty

`harness-v1/binding.json` stores plugin/version, binding epoch, private session
reference, immutable admission hashes, controls, tasks, autonomous attempts and
pending result deliveries. Atomic replace and fsync precede every execution or
control handoff. The existing single writer lease protects this store too.

Repeated operation IDs must match their original payload; they never dispatch
again. Lost receipts, damaged storage, dead owners and interrupted autonomous
work stay explicitly unknown. Upstream has no durable prompt idempotency key.
Restart cannot silently resume or resubmit old work. Both foreground recovery
and abandoned-child result continuations are fenced; cold activation is refused
when a prior action or result continuation is uncertain. Lazy session inspection
alone is not proof of cessation.

Task IDs are opaque plugin identities scoped by the binding. Host-generated
subthread IDs contain neither Codex session IDs nor vendor assumptions. Existing
main-thread agent/session metadata, history bytes, pairing and language settings
are retained. A corrective input completes only its control command, with typed
`controlReceipt`; it does not mark the child execution completed.

Initial engine switches require confirmed quiescence, including no live/unknown
children, controls, autonomous work or undelivered results. Target preparation
must succeed before atomically replacing the binding; failed preparation leaves
the old selection unchanged. Old binding evidence and visible history survive.

## Current access and permission limits

The candidate adapter supports a loopback synthetic Responses inference provider
for development proof. It does not support live authentication yet, start a
provider auth probe, import credentials or fall back to billed usage. Both HOME
and CODEX_HOME are fresh isolated directories in addition to HERMES_HOME. Root
and auxiliary/delegated calls are configured STANDARD; priority overrides are
excluded. Cron and computer-use tools are unavailable in this initial slice.

Native Hermes approval requests are translated with refusal and one-shot answers.
Its heuristic command approval is not a universal Yorozu permission broker or OS
sandbox. Production enablement requires verified pre-execution enforcement for
descendant tools, and a supported fresh provider sign-in or app-owned inference
bridge. An inference bridge may authenticate/translate model requests only;
secretary continuation must remain inside Hermes. The Codex app-server transport
that takes over the loop cannot satisfy this whole-Hermes acceptance gate.

Portable preferences are passed through the host-owner interface. This candidate
does not duplicate or install the separately owned preference journal. No new
scheduler, marketplace, updater, installed-profile migration or release is added.

## Local candidate validation

The additive person host is `person-agent-host.ts`. `serveSecretary` accepts its
trusted `PersonAgentPlatform` explicitly; client settings cannot supply a runtime
factory, interpreter, source path, broker, or permission roots. The fixed bundled
CLI activates this platform only with the explicit internal build marker; the
developer CLI and older bundles retain their current route. Account selection is
still unavailable in that entry, so execution cannot silently use local credentials.
`person-agents-v1` is advertised only when
the production host supplies the registry/control callbacks.

Person settings and chat creation use separate durable control receipts and
immutable creation identities. They do not enter the conversation transcript.
Creating a chat binds its published person without resolving authentication or
starting a harness. Model/account removal uses the explicit `clear` array;
omission preserves a value and JSON null is rejected. Registry revisions protect
against stale edits, and preparation, running work, and unknown outcomes hold
settings changes.

The registry default applies to new chats. Continuous secretary migration remains
an explicit trusted host operation. It requires idle legacy work and an empty
queue. Existing legacy worker records hold migration until explicitly reconciled;
absence of a running main turn alone does not prove those workers have settled.
Migration retains the legacy backend session and workspace metadata as rollback
evidence, and grants none of that old workspace to the new person. Existing chat
identities are immutable; this slice does not offer live secretary reassignment.
Adding person chats preserves the existing secretary execution route and its task
controls. Each thread uses its own owner; person preparation failures do not block
unrelated legacy chats.

Host tests exercise immutable admission/control IDs, uncertainty after restart,
single ownership, quiescent switch preparation and process failure. Adapter
checks exercise actual upstream frame translations and current scope. A separate
real-native proof uses deterministic loopback inference but real Hermes tools,
children, steering and continuation; it is not live subscription validation.
Shared Swift checks protect task schemas, queue semantics and unsupported controls.

`scripts/stage-internal-alpha.py` assembles the actual production baseline,
overlays, patched execution route and adapter provenance. Validate that assembled
source and its compiled entry; raw checkout builds alone are insufficient.
The installed application and its profiles are not replaced by these checks.

## Harness-owned agent platform

Each agent now publishes one durable ongoing conversation. Previous topic bindings,
native session metadata and transcripts remain readable; they cannot admit new user
turns. The host no longer injects its preference/knowledge journal or answers harness
approvals through global YOLO. Native profile/session identity survives ordinary
name, role, model, account and shared-folder changes after confirmed idle execution.
Changing harness or selected connected service selects a separate owned profile.

Typed `action.open`/`action.cancel` requests carry native session provenance and become
conversation cards, including requests outside the foreground user turn. Host answer
intent is durable before a single native handoff; missing receipts remain unknown.
Explicit native choices belong to the harness. Sign-in/UI targets use host-selected
opaque references, never client-supplied URLs or credentials. Unsupported native
sign-in and action mappings stay unavailable.

Managed runtimes are host-owned. Connected OpenClaw services use explicit trusted
selection through `withConnectedAgentPlatform`; detaching stops only the bridge.
The bundled default has no selected connected service and keeps OpenClaw disabled.
Connected Hermes is disabled at the pinned release. Existing external services keep
their native resource policy; managed folder grants cannot be applied to them.

Peer data goes to the recipient's existing native inbox and has its own inspectable
exchange thread. The platform never creates a temporary teammate or substitutes a
user prompt. Inbox admission and model execution are distinct; unknown handoffs are
never replayed. Recipients without a verified inbox receive a visible not-submitted
rejection. Shared memory remains deferred; old host journals are preserved.

New offline user messages remain in the encrypted outbox indefinitely until first
delivery, with Waiting for Mac, edit and cancel controls. If the original wire
deadline elapsed while never transmitted, the host-compatible timestamp/deadline
is refreshed once and persisted before the first attempt. The operation ID and
edited content remain stable. After any attempt, the 30-minute wire deadline stays
immutable; uncertain/expired delivery requires visible reconciliation and fresh
confirmation. Old caches retain their existing explicit confirmation semantics.
No content is silently discarded at 30 minutes. Peer journal budgets reject new
admissions when full while preserving existing records; there is no timed purge.

Synthetic host/adapter checks do not establish a live cross-harness exchange.
OpenClaw remote fetch/build, candidate app builds/reopen and external Claude review
remain held under their earlier denials. Installed Mac 10266 is outside this change.
