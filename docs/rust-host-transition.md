# Portable Rust host transition

The product direction is a Swift/SwiftUI native interface with an independent Rust host core.
The core must be usable on Linux and Windows without depending on Swift. The default experience
should eventually be one continuous conversation, while retaining an explicit way to create
separate conversations. These are migration requirements, not claims about the current release.

## Current boundaries

- `apps/mac` and `apps/ios` provide Swift/SwiftUI interfaces. The shared Swift `ChatModel` and
  `ThreadCache` own encrypted client drafts, attachments, saved-draft recovery and pending sends.
- The Mac launches the bundled Node executable and `packages/runtime/dist/serve.js`. The
  TypeScript host currently owns relay transport, admission policy, sequencing, approvals,
  history read/sync policy, recovery policy and orchestration. Rust owns the extracted durable
  attachment/outbox/expiry/Stop/accepted-message stores, event/transcript transactions, native queue
  writes, steering intent/outcomes, private session identity and wire cryptography, thread metadata
  mutations and Unix listeners. This is approximately 4,000 lines in `serve.ts`,
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

## Expired-admission journal extraction

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

## Durable Stop journal extraction

Rust now owns all production appends to `stopped-turns.jsonl`. Complete legacy rows, unknown
fields and request identities survive migration without rewriting valid existing bytes.
Stop intent remains bound to its original operation and conversation; another conversation
cannot take it, and confirmed stopped/completed/withdrawn proof cannot be downgraded. Repeated
request IDs are merged without losing the callers that need a final outcome.

Stop and expiry share a private, bounded append journal with an OS-held owner lock. Interrupted
tails are retained in an fsynced recovery copy before truncation; appends and the containing
directory are synced before acknowledgement. The shared journal also checks Unix file identity
before and after writes, so replacing a path cannot produce an acknowledgement for an orphaned
file. Reading a malformed oversized line is bounded before allocation can grow beyond the
record limit. Bounds remain 64 MiB, 1 MiB per record and 65,536 rows. Existing user permissions
are unchanged; newly created private files use the existing private-storage conventions.

The compatibility host reserves Stop identities synchronously to prevent dispatch races, but
never publishes a terminal status from that reservation. Stop receipts and confirmed status
wait for Rust persistence. Channel abort waits for durable requested intent, and channel idle
state follows durable completion. Persistence failure leaves cessation unconfirmed and fences
new user-message admission. Both local greetings/inbound work and relay registration wait for
startup Stop recovery; the old interrupted native marker is cleared only after uncertainty is
durable. This prevents a new turn from racing recovery and losing its marker. The host still
owns run orchestration, abort timers and thread-history projections.

Six additional Rust recovery tests pass, including actual worker termination after an
acknowledgement, owner conflicts, terminal-proof retention, interrupted-tail recovery and path
replacement. All 38 core tests, formatting and strict clippy pass. The focused host/facade suite
passes 38 tests; six initial host failures identified confirmation/idle and startup readiness
races that are now covered by the passing workflows. New fixtures additionally hold writes,
force persistence failure and verify startup connection gating. The final complete runtime suite passes 790 tests with one skipped across 45 files using four
workers, and the production runtime build passes. Cross-platform execution and physical
power-loss behavior remain unverified locally.

## Immutable accepted-message extraction

Rust now owns receipt-backed user-message identity and immutable accepted bodies in a separate
`accepted-messages` store. Each record retains original text, attachment data, explicit reply
identity, model choice, client timestamp, deadline, unknown event fields and execution purpose.
A Rust content fingerprint independently binds the client-owned fields even if a caller claims
an unchanged wire fingerprint. A duplicate returns the original body and purpose; it cannot
retarget a conversation or turn a previously consumed approval reply into new agent work.

An OS-held writer lock excludes another accepted-store owner. Records are published through
an exclusive hard link from a private, synced temporary file, then both directories are synced
before acknowledgement. Integrity envelopes detect changed committed bytes. Corrupt or
unsupported final paths are retained and fail closed. Interrupted private temporary files remain
recoverable and do not become accepted operations. Bounds are 32 MiB per record, 65,536 identities,
4 GiB including retained temporary bytes and 128 interrupted temporaries. Exceeding a bound
stops acceptance without discarding original history. Metadata snapshots are paged at 256
identities and never collect attachment bodies; restoration fetches one body at a time.

Startup imports known legacy user records without rewriting valid thread logs, then repairs
missing accepted-message projections before local greetings, relay registration or native
recovery. A partial projection tail is copied into a private synced recovery file before only
those incomplete bytes are removed. The repaired user-message projection is synced. Restoration
alone never starts a new turn. Existing native queue/run/completion state and same-ID client
retry decide execution, preserving uncertain backend outcomes.

Identical pending messages share one Rust save. No receipt, native execution or fresh thread-log
projection precedes that save. A pending acceptance can be withdrawn through durable Stop, even
before a channel outbox exists. Admission queries wait for pending persistence and report
uncertainty after failure rather than misidentifying pending work as unknown. Persistence failure
fences subsequent user messages. The update gate includes pending acceptance and restarts its
idle countdown when new acceptance begins; installation cannot race a still-pending save.

The complete event log, thread index, transcript writer, delivery/steering transitions, approval
outcomes, execution markers and providers remain compatibility-host responsibilities. This is
the immutable receipt currency boundary, not the completed standalone history engine or host.
The development Rust profile now uses optimization level 1 with debug/overflow checks retained;
release builds keep their separate profile. Repeated checksum serialization was also removed.
No production speed claim follows from these changes.

Nine new Rust tests and all 47 core tests pass, including actual worker termination with
attachment-bearing accepted content, corruption, ownership, bounds, retained temporary data,
client-content conflicts, numeric compatibility and bounded metadata pages. Six facade tests
cover pending identity, original approval purpose, failed paths, owner shutdown and non-BMP
paging. Host fixtures verify delayed receipts, pending queries, Stop during acceptance for
native/channel turns, interrupted projection recovery, same-ID execution and storage fencing.
The latest history/host verification passes 302 tests across four files with unchanged test
budgets. Earlier complete runs recorded a native Stop restart timeout and multi-step upload/update
timeouts; the isolated Stop reproduction passed without a production fix. Subsequent work removed
redundant integrity processing and fenced pending acceptance during updates. The remaining
upload timeout in a development build motivated bounded-payload optimization with debug checks
retained. These earlier failures are retained as evidence, not silently counted as passes.
The final complete runtime suite passes 802 tests with one skipped across 46 files using four
workers, and the production runtime build passes. Test timing budgets remain unchanged. Windows
execution and physical power-loss durability remain unverified locally.

## Durable thread metadata extraction

Rust now owns production mutations of `threads.json`: conversation settings, immutable agent and
working-directory ownership, native session IDs and interrupted-run markers. The existing JSON
schema and unknown fields are preserved. An identical legacy index remains byte-for-byte unchanged,
including equivalent safe numeric notation. Before a changed index is published, the exact old
bytes are saved in a private, content-addressed recovery snapshot. Both snapshot and replacement
are synced before confirmation. Interrupted private writes remain retained; legacy `threads.json.tmp`
is treated as unconfirmed state and blocks mutation rather than being overwritten or deleted.

An OS-held transaction lock and a hash of the exact previous bytes exclude competing Rust writes
and stale revisions. A changed agent, folder, creation identity or unknown field fails closed.
Conversations cannot be removed; the existing empty legacy Home cleanup is allowed only when its
history file is absent or a regular empty file, with the old index retained in recovery. Corrupt,
unsupported, duplicate, colliding sanitized IDs and symlink stores are retained and refused.
Bounds are 16 MiB per index, 65,536 records, 4 GiB of recovery data and 128 interrupted index writes.
Existing directory permissions are unchanged; newly created private files use mode 0600 on Unix.

The TypeScript compatibility layer still reads metadata and supplies mutation policy. Its synchronous
helper call preserves the native recovery ordering: a running marker reaches disk before an SDK can
start. The bounded helper receives only its JSON transaction and the existing environment allowlist,
never provider credentials. It has a 30-second deadline and fixed uncertainty errors. No new service,
listening port or platform permission is introduced. This short-lived process boundary is transitional;
it will disappear when orchestration moves into the standalone Rust host. It is not a throughput claim.

Native callbacks are fenced after shutdown. A late session, tool result or completed runner response
cannot overwrite the metadata of a replacement host or append a stale completion. New two-host tests
exercise this for Claude Code and Codex while the replacement is recovering the original user turn.
The complete event-log writer, transcripts, queue/steering state, relay, approvals and provider execution
remain to be migrated. Date/admission policy remains in the compatibility layer; Rust validates the
structural metadata and durable ownership boundary.

Nine new Rust tests and all 56 core tests pass, including helper process exit, concurrent processes,
stale revisions, exact recovery bytes, unknown fields, legacy/interrupted pending data, bounds,
owner locks, symlinks and private new files. Eleven focused metadata/restart tests pass. Formatting,
strict clippy and the production runtime build pass; all 47 thread tests also pass. The first complete
runtime run passed 804 tests and timed out in two multi-step update/Stop workflows. Both passed in
isolation with unchanged five-second budgets. The subsequent complete run, with no overlapping build,
passes 806 tests with one skipped across 46 files using four workers. The earlier timeout evidence is
retained; it is not counted as a passing run or a proven production fix. Windows execution and physical
power-loss durability remain unverified locally.

## Transactional event and transcript extraction

Rust now owns conversation-log and daily-transcript appends. A private immutable transaction
retains the event bytes, append identity, target offsets and prefix hashes before either projection
changes. Both projections are synced before a committed marker and acknowledgement. Startup replays
unfinished transactions before the compatibility host reads history, recovers native markers or
starts an agent. If only one projection or part of an append survived, recovery finishes the other
without duplicating the first. Changed unrelated bytes stop recovery and remain untouched.

Append identities are distinct from event IDs: identical progress cards can be appended again with
new sync cursors. Retrying the original append identity returns the original proof, while different
content or destinations cannot reuse it. Legacy complete bytes, unknown fields and formerly skipped
malformed complete rows remain unchanged. These legacy rows are opaque history, not admission proof.
An incomplete final tail is copied into a private synced recovery file before only that tail is
removed. Immutable checksums and private exclusive publication protect transaction records.

The existing transcript-only control traffic still belongs only to transcripts, including empty
conversation IDs. Conversation logs retain their existing event-kind filter. Date/admission, reading,
search, sync, rewind visibility and provider execution policies still live in the compatibility host.
New bounded batches preserve event order in one transaction for one conversation/day. Native activity
bursts collect at most 256 events or 8 MiB before flushing (a single bounded larger event remains
possible); tool calls/results, approvals, tool boundaries and completion flush before proceeding.
Live activity is published only after the batch is durable. Long-history fixtures now use this
production batch API without reducing assertions, data volumes or original timing budgets.

A bounded JS I/O thread carries private child-process pipe requests while the calling compatibility
thread waits for Rust proof. It has no listener or provider environment. Requests remain limited to
32 MiB, responses to 1 MiB, and I/O has a 30-second deadline. A host lease keeps its Rust writer and OS
lock alive while an SDK is idle; another host cannot acquire it. Unleased fixture/helper workers close
after two seconds idle, and the bridge limits roots to eight, evicting only its own unleased idle
workers. The transitional JS I/O bridge does not make the current Node launcher a standalone Rust host.

Bounds are 32 MiB per transaction, 1,024 events per batch, 65,536 transactions, 4 GiB including retained
transaction temporaries, 1 GiB per projection and 128 interrupted temporary writes. Recovery copies
are separately bounded to 128 and 4 GiB per projection directory. Symlink targets and stores are
refused; existing permissions remain unchanged. Corrupt/unsupported stores fail closed with originals
retained. Linux/Windows filesystem execution and physical power-loss durability remain unverified.

Ten Rust history tests and all 66 core tests pass, covering actual worker termination after proof,
partial/two-projection recovery, exact legacy retention, repeated cards, identity conflicts, bounds,
symlinks, private files and UTC calendar boundaries. The first thread/transcript run exposed repeated-
card suppression and per-event setup costs. Correct append identities and bounded batches resolved
these without increasing timing budgets; all 55 thread/transcript tests pass. The first complete host
run passed 182 tests and failed 51, mainly because transcript-only control events had been incorrectly
sent to the conversation log. After restoring the existing distinction, the focused encrypted round-
trip, trace-burst, accepted recovery and both late-callback cases pass (five tests). Diagnostic state
logging has been removed. Three bridge tests now pass, including a pinned idle writer, owner exclusion, clean release and actual
child loss with an original append retry. The subsequent affected aggregate passed 287 tests and
failed four: one long sequential fixture setup and three SDK auxiliary-delivery cases. The auxiliary
path previously treated a missing receipt as failure after 20 ms in these fixtures, even though the
host had durably stored the prompt. Negotiated SDK tool prompts now request receipt replay under
their original delivery identity, independently of the final reply identity. This local retry option
is removed before encoding the existing wire frame; legacy delivery behavior is unchanged. All 33
channel-plugin tests and the four host reproductions pass with unchanged timing budgets. Plugin
configuration snapshots and settings reload handling are untouched. The long history fixture uses
the bounded production batch API with all original assertions retained. The next complete run passed 807 tests and failed two: an owned-child exit between request reservation
and worker-message dispatch missed its failure notification, and the multi-step update case timed out.
The shared handoff now exists before dispatch and is notified even when no active worker request has
been installed. Twelve actual child interruptions and the original update reproduction pass without
changing deadlines. The final complete runtime suite passes 809 tests with one skipped across 47 files
using four workers; the production runtime build passes. Queue/steering migration and the remaining
standalone/native/release gates are still open.

## Durable native queue

Rust now owns `native-turn-queue.json` mutations through the existing pinned local history worker.
Startup requires a queue-ready proof before orphan cleanup or SDK recovery. Waiting turns recheck
that proof before execution. Exact legacy bytes and unknown fields are retained until a mutation;
before each rewrite the prior bytes are saved in a private content-addressed recovery snapshot.
Original event/thread retries are idempotent; retargeting is rejected. An OS writer lock excludes
another owner, and unexpected external changes fence the queue without overwriting them. An ambiguous
legacy `.tmp` remains untouched and blocks startup; a blocker introduced after startup produces a
retryable failure. Own interrupted private temporaries remain retained and cannot admit work.

Queue files are bounded to 16 MiB/65,536 entries, recovery snapshots to 4 GiB/65,536 files, and pending
temporaries to 128 files. Native message bodies remain in the existing Rust accepted/history stores.
This extracts durable queue writes; lifecycle decisions and steering/run policy are still in Node.
Eight queue tests and all 74 Rust tests pass, including actual worker termination after enqueue/remove
acknowledgement, exact-byte snapshots, restart retries, owner conflicts, external mutation fencing,
ambiguous legacy recovery, bounds and symlinks. Strict Clippy, the production runtime build, nine
native interruption/queue/update regressions and two startup/waiting-turn fence regressions pass.
The full runtime suite passes 811 tests with one skipped across 47 files using four workers.
The first queue check stopped on a Clippy formatting warning before any build or host test; this was
fixed and all checks rerun. Cross-platform execution and actual power-loss durability remain unverified.

## Durable native steering

Before invoking live SDK input, the compatibility host now requires Rust to durably reserve a
steering intent in `native-steering.jsonl`. The immutable binding includes the original accepted
message identity, conversation, active operation, completion, attempt and optional native session.
Repeated intents cannot reserve another external effect. A definite `false` from a provider proves
no input was accepted and allows queue fallback; a thrown error preserves the attempted effect as
uncertain. Only a fresh explicit attempt may retry a definitively rejected intent. Original message
bodies and attachments remain in accepted/history storage and are never deleted by steering recovery.

Rust commits successful delivery through the existing two-projection history transaction under a
stable attempt identity, then writes its outcome and removes the native queue entry. If interrupted
between those steps, startup verifies the original projection and finishes only outcome/queue cleanup.
It cannot repeat the SDK call. Unknown outcomes stay queued in storage and report `indeterminate`;
Stop reports `unconfirmed`, without falsely claiming withdrawal. An interrupted active run with an
uncertain follow-up remains paused rather than injecting that follow-up through an automatic recovery
prompt. Continue explains the unconfirmed outcome. Normal recovery omits undispatched queue entries.
Late confirmations from a closed host cannot mutate its replacement's state.

The journal has an exclusive OS writer lock and limits of 64 MiB, 65,536 rows and 1 MiB per row.
Startup snapshots are paged by at most 64 records/512 KiB. Unknown fields and incomplete legacy tails
are retained; an incomplete tail is copied privately before a subsequent safe append. Invalid complete
rows and conflicting bindings fail closed. The host still supplies execution decisions and constructs
the corrected message; provider reconciliation of ambiguous external effects remains part of the
required run-orchestration/provider-worker work, rather than a completed standalone Rust host.

Ten steering tests and all 84 Rust tests pass, with strict Clippy. Fifteen focused host regressions
pass, covering real Claude/Codex adapters, repeated Send now, tool-question gating, concurrent
completion/Stop/withdrawal, lost response after accepted input, attachments through restart, paused
uncertain recovery, and late confirmation after host replacement. The initial focused run passed nine
and failed one outdated expectation that an SDK exception permitted another execution; the tightened
fixture now proves that accepted input with a lost response is retained without replay. A subsequent
late-confirmation test exposed recovery prompts admitting undispatched follow-ups, which is now fixed.
The first recovery-filter build stopped on TypeScript union narrowing before host tests; after preserving
the event-kind narrowing, the production runtime build and focused checks pass. The final full runtime
suite passes 812 tests with one skipped across 47 files using four workers. Earlier failure logs
remain retained. Cross-platform execution, physical power loss and native release gates remain open.

## Rust session cryptography

The compatibility host now routes relay signatures, pairing proofs, modern and legacy encrypted
boxes, and private notification previews through Rust. Rust loads the existing `keys.json` identity,
verifies its public/private pairing, and returns only public identity metadata through the local
worker. Existing key bytes and unknown fields remain unchanged. Missing identity beside any saved
pairing/counter file blocks readiness rather than generating a replacement room. Readiness is checked
before orphan cleanup. A connection-identity error explains the recovery action without exposing keys.
Synthetic tests create temporary identities; no installed application identity or connection was used.

The implementation retains the current X25519/HKDF-SHA256 salt and directional info, ChaCha20-Poly1305
nonce/tag layout, Ed25519 signatures, envelope format and legacy compatibility policy. Non-contributory
key agreement is rejected; strict signature verification is used. The checked APIs are documented by
[x25519-dalek 2.0.1](https://docs.rs/x25519-dalek/2.0.1/x25519_dalek/struct.SharedSecret.html),
[ed25519-dalek 2.2.0](https://docs.rs/ed25519-dalek/2.2.0/ed25519_dalek/struct.VerifyingKey.html),
[RustCrypto ChaCha20Poly1305 0.10.1](https://docs.rs/chacha20poly1305/0.10.1/chacha20poly1305/), and
[HKDF 0.12.4](https://docs.rs/hkdf/0.12.4/hkdf/). Dependencies are locked. Peer-key caches are bounded to
16 entries and cleared on revocation. The private local worker exchanges public identifiers and
messages with Node; provider environment variables are excluded. Relay networking, pairing policy,
sequence persistence, reconnection and catch-up policy still belong to Node.

Eight crypto tests and all 92 Rust tests pass, with strict Clippy. Six bridge/facade tests and the
production runtime build pass. Thirteen focused encrypted relay/facade tests and ten notification/
child-recovery reproductions pass with the original timing budgets. The original Swift signature
fixture verifies but is not byte-identical to a signature reproduced by either Node or Rust; the test
checks validity for both languages and exact reproduction for the TypeScript fixture. No fixture was
rewritten. The first full run passed 805 tests and failed ten: nine fixtures had seeded saved pairings
without creating their synthetic host identity; these now model complete existing installations.
The repeated child-loss test also exceeded its five-second total budget in that aggregate and passed
its unchanged focused reproduction. The next aggregate passed 814 and timed out in the multi-step
update fixture. Its local-client helper now waits on the actual response event rather than accumulating
50 ms polling intervals; every original assertion and the five-second test budget remain intact.
Five update/notification/steering/Stop reproductions pass. The final full runtime suite passes 815 tests
with one skipped across 48 files using four workers. Earlier failure evidence remains retained.
Cross-platform execution and the remaining standalone/native/release gates are open.

## Rust sequence currency extraction

Rust now owns live-channel counter persistence. The compatibility host initializes the counter
store immediately after identity, before rewriting legacy pairings, and requires a durable Rust
acknowledgement before accepting a modern box or using a reserved send block. Node still owns
reservation/replay policy, relay connections, reconnect/catch-up and capability negotiation.
This extraction does not complete checklist item 2 or make the launcher standalone.

The store retains the exact legacy projection and unknown row fields, seeds counters from legacy
pairings when needed, merges only nondecreasing currency and retains omitted or re-paired peers.
The canonical integrity envelope is synchronized before the compatible projection. Restart
reconciles an old or missing projection, accepts validated forward progress from a stopped old
build, and refuses lower/malformed state without overwriting it. Live unexplained drift fences
counter operations; a projection directory blocker remains retryable without advancing counters.
Original backups are private, content-addressed and bounded to 128 files/128 MiB without deletion.
An exact existing backup can reopen at the limit. Malformed originals remain untouched.

Ten new Rust tests cover counter bounds, exact migration bytes, monotonicity, omitted peers,
writer exclusion, corruption, links, projection recovery and actual process termination after
acknowledgement. The backup-limit regression failed before repair. The existing phone-restart
fixture now also proves higher legacy pairing counters are durably merged before a pairing
rewrite strips them; it reproduced a 2000-to-1000 send-ceiling loss before the ordering repair.
All 102 Rust tests, locked formatting/strict Clippy and the runtime build pass. The initial
239-test affected runtime suite passed. The final complete runtime suite passes 816 tests with
one skipped across 48 files, with two workers and every original test deadline retained.
An earlier four-worker aggregate passed 814, skipped one and timed out in the multi-step update
fixture; its unchanged isolated reproduction passes. That earlier failed run is retained and
is not evidence of a root-caused update bug. Two workers bound concurrent process/storage load.

## Required 0.6.0 host work

The requested rewrite has a finite completion checklist. These responsibilities are required before
claiming an independent portable Rust host or replacing the installed application:

1. Finish verified persistence: event/transcript transactions, native queue transitions and durable
   steering intent/outcomes. Preserve uncertain external effects and existing indexed history.
2. Move relay/session crypto, sequence currency, reconnection, catch-up and capability negotiation
   into the Rust host, retaining the current wire contracts and connections.
3. Move approval/admission/Stop/run orchestration into Rust. SDK workers may supply provider access;
   they cannot bypass Rust's durable decisions or existing safety confirmations.
4. Establish a bounded versioned provider-worker contract with run/task/origin identity, streamed
   activity, cancellation, supersession and explicit approval questions. Claude Code and Codex are
   internal workers of one user-facing Yorozu agent; remove their direct session-creation entrypoints
   and reject new direct-provider session requests in the backend. Preserve saved provider history,
   worker/session compatibility and user installations during migration.
5. Implement and verify Linux/Windows headless operation and the Windows local transport contract.
   Swift remains an optional macOS OS adapter. Test interrupted/repeated/concurrent workflows.
6. Switch the actual launcher and package to the standalone Rust host; implement one continuous main
   conversation with optional separate conversations and saved draft recovery. Use the approved
   SQLite operational store plus editable Markdown knowledge with defined synchronization and rollback,
   as specified below. Topics and tasks remain separate; bounded context and delayed-result ownership
   are required parts of this item.
7. Pass native, build, CI and migration/rollback gates; release only 0.6.0 alpha to the authorized
   internal-only destination, preserve current connections and exclude the 0.5.0 beta updater, then
   replace the same installed application with a hidden recoverable rollback copy.

Actual new schedule execution and PAIOS ownership are optional later product features. Their current
truthful unavailable UI is retained; they cannot expand this checklist or substitute for the requested
Rust host responsibilities. No control removal may silently remove a required capability.

## Accepted conversation and storage target (implementation pending)

One user-facing Yorozu agent serves the main conversation and optional focused conversations.
Stable message/reply IDs anchor reply ancestry; topic identity is separate from task records.
Each turn receives a bounded context packet containing the new message, reply ancestry, relevant
source-backed decisions, current task/evidence and a recent window. Delayed worker results carry
task and origin IDs and check cancellation/supersession before application. Interleaved topics,
corrections, cancellation and delayed results need executable coverage before completion.

SQLite is the authoritative operational store for messages, tasks, events, permission records and
searchable history. Start with SQLite full-text search; embeddings remain optional later. PAIOS
memory is source-backed and revisable, separate from permission scope and revocation. Memory or
retrieved text never grants authority. Markdown provides human-readable, editable Obsidian knowledge,
not a second copy of every operational record. Define stable knowledge IDs, revisions and the last
exported/imported content hash; import edits against their base revision in a database transaction.
Concurrent edits preserve both versions as an explicit conflict instead of silently overwriting the
operational decision. Markdown import must not create or broaden permission grants.

Migrate the verified journals and replayable transaction intents in stages, with one stopped prior
writer and one authoritative new writer. Retain exact legacy bytes/history and a recoverable migration
manifest; validate schema/identity and imported counts/content before switching reads. Rollback stops
the new writer and restores the retained state at a recorded checkpoint. Do not discard verified
journals or introduce competing writable truth stores. These are accepted requirements, not a claim
that SQLite, Markdown sync, bounded context or standalone conversation routing already exists.

A visible YOLO mode with user-configured standing policy is a requested design direction. Central
permission enforcement should reuse already-granted ordinary tool access, record decisions/execution
and retain Stop. The scope for messaging, spending and permanent deletion awaits the user's answer;
do not introduce blanket bypass or enable it by default. OS/provider/MFA constraints and tool
capabilities still apply; no credential expansion follows from this design request. Unknown external
outcomes remain explicit and require reconciliation. Use provider-supported idempotency when available;
never claim universal exactly-once external side effects. Voice integration is deferred.

## Compatibility requirements

The following criteria apply to the seven required work items above.

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
seconds. Its terminal result is exit 65; its retained tap trace shows XCTest sending the offline
Send tap to the pre-keyboard coordinate (364, 757), and only the successful initial Send reached
the model. The temporary diagnostics have been removed.

The UI-test Send helper now waits, for at most ten seconds, until its enabled/hittable
accessibility frame is above the visible keyboard before tapping. This preserves app animations,
network deadlines, receipt behavior and all original message/duplicate assertions. The bounded
reproduction passed in 63.027 seconds on the installed iOS 27.0 iPhone 17 Pro simulator: both
messages appeared once, delivery confirmed after reconnect, and both replies arrived once in
order. Its retained screenshot shows the queued messages and reconnection state. The synthetic
host binary was pinned for this run so later core development could not replace it mid-test.
This is evidence for a test-coordinate race, not a production Send-action fix. The full iOS 26.5
release suite and physical-device/IME checks remain open. These runs do not establish the full native release gate.
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

The parent's authenticated App Store Connect browser audit on October 1 verified app
6811274963 (`to.yumi.yorozu.ios`), exactly one Internal group with one owner, and a Public group
with three recipients: the same owner and two external-only beta testers. All reported installed
builds were 0.5.0 (10121). Internal Automatic for Xcode Builds was enabled. This verifies eligibility;
individual device automatic-update settings were not inspected. No group, setting or grant changed.
The Mac application identity remains separately `to.yumi.yorozu`.

The owner overlap is expected for the explicitly chosen internal alpha. Upload routing must
use Apple's TestFlight Internal Only option where supported, preventing external distribution
([Apple documentation](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/)),
and must never assign 0.6.0 to Public. The current canonical Public-group assignment workflow
still requires a separate alpha route. The existing 0.5.0 beta updater must remain isolated.
The browser audit and Safari belong to the parent task and are untouched by this implementation.
An earlier automatic approval review rejected adding ASC credentials to a pull-request workflow
because branch code could expose them; that credential job was not added.
No release has been dispatched, no tester access changed, and no version or tag overwritten.
Gateway authorization remains pending; no gateway connection or credential issuance/rotation is
part of this migration.
