# Portable Rust host transition

The product direction is a Swift/SwiftUI native interface with an independent Rust host core.
The core must be usable on Linux and Windows without depending on Swift. The default experience
should eventually be one continuous conversation, while retaining an explicit way to create
separate conversations. These are migration requirements, not claims about the current release.

## Current boundaries

- `apps/mac` and `apps/ios` provide Swift/SwiftUI interfaces. The shared Swift `ChatModel` and
  `ThreadCache` own encrypted client drafts, attachments, saved-draft recovery and pending sends.
- The Mac launches the bundled Node executable and `packages/runtime/dist/serve.js`. The
  TypeScript host currently owns relay transport, admission, sequencing, approvals,
  thread history, recovery and orchestration. This is approximately 4,000 lines in `serve.ts`,
  plus its supporting modules; replacing a launcher alone would not rewrite the backend.
- Claude uses a TypeScript SDK adapter; Codex has both SDK and native app-server adapters.
  OpenClaw's separate channel plugin uses a local JSON-lines socket and durable acknowledged
  outboxes. SDK adapters can remain compatibility workers during a staged core migration.
- `yorozu-native` is a separate Swift process for Mac-only OS integrations. The portable core
  must use an explicit platform-tool interface; Swift is a macOS adapter, never a required
  Linux/Windows runtime dependency. Existing security prompts and approvals remain effective.
- The relay and website are independently deployed services. A host rewrite does not require
  rewriting them or changing existing device wire protocols.

## First Rust extraction

`packages/host-core` is a Rust library and headless executable with no Swift, UI, provider SDK,
gateway, credential or network dependency. Its first production integration replaces the
TypeScript attachment staging/assembly engine behind the existing async `AttachmentUploads`
interface. The compatibility bridge uses private bounded JSON lines over child-process pipes.

The Rust worker owns quota reservations, staged metadata and bytes, hash validation, fsync before
acknowledgement and assembly. An OS-held writer lock prevents concurrent Rust owners of a staging
root and releases on process termination. Message admission remains in the surrounding host;
assembling a file cannot accept, acknowledge or execute a user turn.

This extraction preserves the existing hashed directory names, `index.json` metadata and
`index.bin` bytes under `attachment-uploads`. Existing partial Node uploads resume without
rewriting metadata. Source identity, message identity, thread, deadline, content hash and slot
remain bound together. A conflicting retry cannot overwrite committed metadata or existing bytes.
Limits remain 5 MiB per file, ten files and 20 MiB per message, with bounded staged bytes and slots.

The bridge does not retry a possibly completed operation under a new identity. Worker failure or
a lost response leaves the request unconfirmed; the client can retry its same original upload and
receive the durable offset. Fixed storage failure codes exclude internal paths or subprocess
diagnostics. No provider environment or credentials are passed to this worker.

This is a real Rust backend component, **not a completed independent Rust runtime**. Transport,
relay transport, thread/admission state, approval currency and agent execution remain TypeScript
until their individual compatibility and recovery tests pass. The existing native UI slices are
preserved, including separate conversations. Actual schedules, PAIOS ownership and the future
continuous-conversation task store remain unimplemented.

## Durable channel outbox extraction

The Rust worker now also owns channel enqueue, model-preparation markers, uncertain reply
dispatch markers, acknowledgements and withdrawal removal. It reads the existing
`channel-outbox.json` and `channel-model-delivery.json` formats, retains unknown message fields,
and leaves valid legacy files byte-for-byte unchanged until an actual transition is necessary.
A separate OS-held lock prevents a second Rust channel writer.

Model preparation and delivery retain replayable intents before removing the associated outbox
data. New `channel-model-original.json` metadata binds a removed model pin to its original
choice; `channel-cancelled.json` records pre-dispatch withdrawals before removal. Recovery also
reads validated prior host withdrawal records with their thread ownership. An attempted quoted
reply remains uncertain and cannot be converted into a definite rejection or withdrawal.

The compatibility host awaits the Rust save before acknowledging a user message. Repeated pending
IDs share one save, failed saves receive no receipt, and a fresh message stopped while its save
is pending is withdrawn before any dispatch. Stop first reports a durable request; confirmed
withdrawal is reported only after Rust has durably removed the work. A pre-dispatch Stop intent
survives interruption of that removal and completes on the next host startup. Dispatch eligibility
is rechecked after storage
awaits. On restart, run ownership is restored before processing a plugin's immediate lifecycle
replay; otherwise a final reply could be lost while async recovery is still running.

Snapshots contain only outbox IDs and thread IDs; attachment payloads are fetched one message
at a time. Bridge request frames are limited to 32 MiB, responses to 34 MiB, with at most 32
pending requests and 64 MiB of pending encoded input. Channel protocol semantics, peer capabilities,
thread logs, admission identity and Stop journals remain in TypeScript. This is the second
production Rust state component, not the completed standalone host rewrite.

## Native local transport extraction

The production local and OpenClaw channel listeners now use Rust-owned Unix sockets. The
TypeScript `startLocalChannel` interface remains a compatibility facade for frame dispatch;
it no longer creates listeners, parses socket bytes, changes socket permissions or writes
socket payloads. Bound-listener confirmation is distinct from worker-spawn success.

The Rust listener retains the existing UTF-8 JSON-lines protocol and preserves unknown fields.
New sockets are private inside a private state directory. Existing directory permissions and
process umask are unchanged. A per-socket OS-held writer lock refuses another active writer;
an existing live legacy listener, regular file or symlink is retained. A stale socket is
recovered only after connection refusal. Shutdown removes only the socket inode this owner
created, closes idle peers and wakes its bounded idle wait.

Limits are 16 peers per listener, eight listeners per worker, 32 MiB per frame and 64 MiB of
reserved inbound bytes per listener. Writes have a five-second deadline. The compatibility
facade snapshots each outbound frame before asynchronous dispatch, serializes writes per peer,
and bounds queued output to 64 MiB per listener. Failed writes remain unconfirmed. Oversized
or invalid input produces fixed error codes without echoing contents.

A worker crash disconnects existing peers. Listener recovery uses bounded backoff and new
transport/peer identities; an old callback cannot send into a newly connected peer. Listener
recovery does not replay user operations or generate replacement operation IDs. Storage and
listener owners share a worker lease: closing one owner cannot kill its siblings, and closing
the last owner waits for its own child to exit. Child I/O deadlines use the actual event-loop
clock independently of application approval-expiry clocks.

This extraction implements Unix local transport only. Windows explicitly returns
`local-transport-unavailable`; it does not claim readiness. Relay encryption, device sequence
currency, capability negotiation, durable thread/admission state, approval decisions and
provider execution remain future Rust boundaries. No provider credentials enter this worker.

## Expired-admission journal extraction (in progress)

Rust now owns the append writer for `expired-admissions.jsonl`. Legacy complete records and
unknown fields are validated without rewriting their bytes. Interrupted final bytes remain
untouched on open; before the next append Rust saves a private recovery copy of the entire
original, then removes only the incomplete tail. An OS-held writer lock excludes another Rust
owner. Bounds are 64 MiB per journal, 1 MiB per record and 65,536 records; unsupported/corrupt
stores fail closed and retain originals. JavaScript-safe integer deadlines retain equivalent
legacy numeric notation.

An expired ID stays bound to its original thread, content identity and deadline. Rust syncs the
record and directory before reporting expiration. Identical pending retries share one save;
a changed-deadline retry waits for that save and cannot become accepted work. Persistence or
worker failure leaves expiration unconfirmed and fences new user-message admission until safe host recovery.
Closing the compatibility owner awaits pending writes before releasing its worker lease.

The surrounding TypeScript host still supplies the trusted clock and admission policy, reads a
validated legacy snapshot, and owns accepted history. This is the expired-operation currency
boundary only; accepted-operation/event state, Stop journals and provider execution remain to
be migrated. Existing approvals and safety confirmations are unchanged.

Seven new Rust recovery tests and the full 32-test core suite pass, including actual process
termination after acknowledgement, interrupted-tail retention, conflicts, corruption/bounds,
writer exclusion and symlink refusal. Four facade tests plus host expiry/restart and pending-ID
race checks pass. The final runtime aggregate passes 782 tests with one skipped across 44 files using four workers,
including the storage-failure fence and pending-identity/restart regressions. Strict clippy and
the production runtime build also pass. Windows execution and physical power-loss durability
remain unverified locally.

## Following migration boundaries

1. Move the durable event/admission/outbox state engine to Rust with one authoritative writer.
   Preserve immutable operation IDs and content identities, receipt-after-durability ordering,
   rejection history, Stop ownership, explicit reply context and uncertain dispatch markers.
   Multi-file transitions need explicit transactions or replayable intents; file-level rename
   alone does not establish atomicity across these records.
2. Move transport, catch-up and capability negotiation to a Rust host executable. Preserve the
   native local JSON-lines protocol, relay envelopes, crypto vectors, replay counters and the
   OpenClaw channel protocol. Version/capability differences must produce the same safe behavior.
3. Reduce TypeScript to isolated provider SDK workers. Use a versioned, bounded execution interface
   with run IDs, streamed events, cancellation and explicit approval questions. Later replace
   individual workers where a supported non-Node provider contract exists.
4. Add platform adapters and headless integration tests on Linux/Windows. Unix sockets are not
   the Windows transport contract; select and test an appropriate local transport there before
   claiming Windows support. Retain a macOS tool adapter for APIs that require it.

At every step, legacy state must be read and validated before writing. Unknown schemas or
conflicting identities must stop safely, retaining originals. Switching writers requires stopping
the previous owner; two engines must not independently append or migrate the same store. Changes
to client cache encryption, keychain data, pairing, gateway scopes or OS permissions are excluded.

## Validation and release status

Rust recovery tests cover actual process termination after acknowledgement, re-opening the store,
unchanged legacy metadata, retries and conflicts, empty files, exact missing slots, corruption,
per-message and cross-device global reservations, writer exclusion and newly created private files.
Host integration and native regression validation are in progress. macOS process-crash evidence
does not establish Windows filesystem behavior or physical power-loss durability.

The second extraction has passed nine Rust outbox recovery tests and ten attachment recovery
tests on this Mac, strict clippy, the runtime build and 277 affected TypeScript host tests across
channel/admission/replies/Stop, uploads, threads and readiness. Seven credential-free alpha-audit
tests and nine existing ASC candidate tests also pass. An earlier complete host run timed out in
the older pairing-history test; it passed in the focused diagnostic run and the subsequent full
verification. The timeout is retained in the local evidence rather than treated as a confirmed
root-caused fix.

The local transport extraction passes six additional Rust socket tests, including fragmented
Unicode, malformed input followed by valid input, live-owner exclusion, stale socket recovery,
retained files/links/permissions, idle-peer shutdown and peer/frame limits. All 25 Rust tests,
strict clippy and the TypeScript runtime build pass. The affected aggregate host suite passes
300 tests. Five initial failures were resolved by waiting for actual listener readiness and
separating child I/O deadlines from the injected application clock. The complete runtime suite passes 776 tests with one skipped across 43 files, using four workers
to bound process concurrency. The unconstrained runs exposed additional greeting/broadcast
ordering assumptions, now corrected; they also exceeded the five-second test budget in two
multi-step cases during parallel simulator building. Synthetic upload-stage timings measured
4.455 seconds through the repeated receipt in the bounded aggregate run. Temporary tracing
was removed after diagnosis. These results are not a latency benchmark.

Native validation used a disposable simulator and synthetic hosts. The first build under
Documents failed because signing rejected Finder metadata in a generated resource bundle.
A build using temporary derived data then passed the lost-receipt/relaunch case (62.979 seconds).
The repeated-send case failed when a simulator notification prompt intercepted Send. A DEBUG-only
UI-test flag now avoids requesting that unrelated permission; release behavior is unchanged.
The following run displayed the first queued message but was interrupted after more than ten
minutes of XCTest animation-idle waits. It is incomplete, not passed. A bounded 180-second
reproduction subsequently failed in 44.374 seconds: the initial Send tap left “hello” in the
composer. The exported accessibility hierarchy and screen recording show an enabled Send control,
retained input and no notification prompt. This is a concrete native UI failure under investigation,
not a pass and not evidence that animation waits alone explain the earlier result.
A subsequent boolean-only Send-action diagnostic failed at the first offline message in 41.030
seconds; result collection is still active. Its temporary DEBUG diagnostics are not committed. These runs do not establish the full native release gate.
Cross-platform CI, physical devices and publication remain pending.

No speed claim follows from the language choice. Measure cold launch, request latency, streaming
under large history/attachments, memory and recovery time on comparable builds. Maintain bounded
queues and measure fsync cost. Reliability must be demonstrated with crash, duplicate, concurrent,
timeout, disconnected and upgraded/rolled-back workflows.

The requested 0.6.0 alpha must not enter the existing 0.5.0 beta update path. The published
0.5.0 Mac updater follows `/beta/appcast.xml` and permits the beta channel; the live redirect still
points to `v0.5.0-beta`. The canonical main release path would replace that beta. Release-branch
candidate titles are excluded by the existing website's beta discovery. Merely setting GitHub's
prerelease flag is insufficient.

The requested iOS destination is internal TestFlight. The canonical iOS workflow currently adds
every candidate to the existing Public group, so it must not be used unchanged for this alpha.
`scripts/asc-alpha-audit.mjs` performs only GET requests for app identity, group attributes and
tester memberships. It detects external recipient overlap and unknown/broadened all-build access,
and reports aggregate counts without exposing tester identities. Its injected-API tests need no
credentials. The API's `hasAccessToAllBuilds` attribute alone is not treated as proof of the separate
automatic-distribution setting in the App Store Connect UI.

Live group membership and automatic distribution remain unverified. Automatic approval review
rejected adding ASC credentials to a pull-request workflow because branch code could expose them;
that credential workflow was not added. The parent's separate official ASC browser audit reached Apple passkey confirmation and is waiting
for the user's device action; authenticated access and group readback are not yet verified. Safari
is left untouched by this implementation task.
No release has been dispatched, no tester access changed, and no version or tag overwritten.
Gateway authorization remains pending; no gateway connection or credential issuance/rotation is
part of this migration.
