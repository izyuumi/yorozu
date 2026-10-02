# Portable Rust host transition

The product direction is a Swift/SwiftUI native interface with an independent Rust host core.
The core must be usable on Linux and Windows without depending on Swift. The default experience
should eventually be one continuous conversation, while retaining an explicit way to create
separate conversations. These are migration requirements, not claims about the current release.

## Current boundaries

- `apps/mac` and `apps/ios` provide Swift/SwiftUI interfaces. The shared Swift `ChatModel` and
  `ThreadCache` own encrypted client drafts, attachments, saved-draft recovery and pending sends.
- The Mac launches the bundled Node executable and `packages/runtime/dist/serve.js`. The
  TypeScript host currently owns relay registration/frame policy, admission policy, approvals,
  history read/sync policy, recovery policy and orchestration. Rust owns relay socket IO,
  heartbeat/reconnect, authenticated channel crypto and sequence reservation/replay currency,
  plus the extracted durable
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

`packages/host-core` is a Rust library and headless executable with no Swift, UI or provider SDK
dependency. The initial storage extraction had no network dependency; the current library also
owns relay WebSocket/TLS IO. Its first production integration replaces the
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

## Rust reservation and replay decisions

Rust now chooses outgoing sequence numbers and reserves the existing 1000-number blocks before
sealing a current box. Restart skips the whole previously reserved ceiling; receive admission
rejects stale counters and proves new currency before exposing an authenticated event. The
compatibility host no longer increments, reserves or rolls back its own live counter copies.
Generic legacy seeding still merges monotonic records before pairing projection rewrites.
An explicit stored send advance burns an earlier in-memory block. At the shared JavaScript/Swift
safe-integer limit, the last reservation is capped and subsequent sends report exhaustion rather
than wrapping or publishing an invalid envelope.

The history worker composes encryption and sequence decisions into one bounded local request per
current box, reducing compatibility-bridge round trips. Component ownership and storage fences
remain intact. Missing identity also refuses canonical counter files, original backups and pending
counter publications, even if the legacy projections disappeared. The missing-canonical identity
regression failed before repair; original evidence remains retained without generating a new room.

All 104 Rust tests, locked formatting/strict Clippy and the production runtime build pass. The
uncomposed policy passed 240 affected runtime tests but its full aggregate timed out in the same
multi-step update fixture (815 passed, one skipped, one failed). Eight composed-box/migration/crypto
focused tests and the final complete runtime suite pass: 816 passed, one skipped across 48 files,
two workers, with original assertions/deadlines intact. Failed aggregates remain in local evidence;
the passing run does not establish a general latency benchmark or a standalone-host completion.
Relay socket IO, reconnect, catch-up, capability negotiation, provider orchestration and launcher
ownership still belong to the remaining finite migration work.

## Rust relay socket ownership

The portable worker now owns relay WebSocket/TLS connections, connection/write deadlines, JSON
heartbeat expiry and reconnection. Established Tokio/Tungstenite/Rustls libraries implement the
wire/TLS protocols, with the ring provider selected explicitly by Cargo features. Certificate
verification uses the standard trust roots; no credential files, provider environment, new grants
or relaxed certificate checks enter this worker. The existing room query and registration/frame
formats remain intact.

Every connection has a new generation. Outgoing work is bound to that generation and never replayed
onto a replacement socket. Writes confirm socket IO only, not message delivery or admission. Input
and individual output messages are bounded to the relay's 1 MiB contract, the Rust command queue to
32 frames, and the compatibility facade to 8 MiB of output. Writes have a five-second deadline;
DNS/TCP/TLS/handshake share a cancellable ten-second deadline. Reconnect starts at two seconds,
doubles to thirty seconds and resets after registration. Actual process termination still leaves
unconfirmed operations for their existing durable identity/recovery policy.

Three independent real-socket tests pass: room routing, opaque text/binary frames, protocol ping,
old-generation exclusion, output bounds, cancellable incomplete WS/WSS handshakes, and rejection
of an actual self-signed relay. The initial WSS test exposed missing Rustls provider selection;
that failed evidence is retained and the library configuration is repaired. Nine existing host
relay tests also pass, including heartbeat recovery, buffered replay, pairing counters and startup
gating. A separate compatibility-facade test kills the actual owned worker, proves retired callbacks
cannot send to the replacement connection, and verifies final-owner cleanup. Read-only review also
identified that cancelling a system DNS future does not bound Tokio runtime destruction. Runtime
shutdown now detaches that OS resolver while a shared permit bounds resolver work across retries
and replacement owners. Literal IPs bypass DNS; all resolved IPv4/IPv6 addresses and the original
TLS hostname/routing are retained. DNS failure cannot stall storage-owner shutdown.
The complete Rust suite passes 107 tests, strict Clippy and the runtime build pass, and
the final runtime aggregate passes 817 tests with one skipped across 49 files after the DNS
repair and worker-termination fixture. An initial full core run failed one
existing thread-index writer-release fixture (106 passed, one failed); its unchanged isolated
reproduction and the repeated complete suite pass. Both results are retained without a cause claim.
Catch-up policy, capability
negotiation, registration/frame semantics and provider/run orchestration remain TypeScript.

## Rust peer negotiation

Rust now supplies the host's released capability catalog and validates authenticated peer claims:
UTF-8 byte/text bounds, capability identifiers/counts/uniqueness, integer protocol ranges, required
capability subsets and claim/reply shape. Compatibility follows protocol overlap and security
capabilities, never the display app version. Current shared client metadata and reason strings
remain compatible. The Node facade retains the existing authenticated-current-box gate and durable
`peerInfoRequired` projection before requesting a decision; malformed or reflected claims do not
restore legacy admission. Node's per-command capability checks remain compatibility projections
until run/admission ownership moves.

A cross-language real-worker check compares Rust against the released shared-client contracts,
including multibyte UTF-8 bounds, UTF-16 claim-ID lengths, numeric ranges, missing/unknown security
capabilities and reflected/invalid claims. It and eight existing affected host cases pass. The complete
runtime run passed 818 tests and skipped one across 50 files; production build passes. The first
complete Rust run hit the inherited writer-lock fixture race, while its isolated reproduction passed.
The fixture now explicitly unlocks before close, matching production and retaining immediate
reacquisition/no-mutation assertions without sleeps or retries. The final complete Rust run passed all
107 tests, formatting and strict Clippy. Failed verification logs are retained alongside the final runs.
Catch-up selection and registration/frame policy still remain to migrate.

## Rust relay replay acknowledgement ownership

The relay owner now assigns opaque, connection-scoped receive tokens to buffered frames on both
text and binary paths. The compatibility handler reports success or failure after its existing
synchronous boundary; Rust acknowledges only the successfully handled prefix. A failed handler
fences all later cumulative acknowledgements until reconnect. Malformed inner frame bodies remain
deliberately disposable. Live frames have no replay token. Receive tokens and relay buffer sequences
are separate from durable encrypted channel counters, accepted-message proof and provider completion.

Rust retains at most 32 pending buffered receipts. A full window pauses socket reads while commands
and shutdown remain active; it does not reconnect merely because a legitimate replay burst exceeds
one window. The oldest unresolved receipt has a 30-second deadline. Heartbeat reads receive fresh
grace after a full window drains. Stale connection/token results and repeated completions are rejected
before touching the prefix. Unhandled overflow/failure/timeout leaves the relay's retained copy intact.

The Node facade preserves incoming order and waits for each synchronous handler's response/ack
writes to drain before delivering the next frame. Incoming and outgoing encoded buffers are each
bounded to 8 MiB, individual frames to 1 MiB and facade command/input queues to 64 entries. This
prevents ordinary reply amplification (receipt plus thread/project lists) from exhausting the command
queue during a healthy replay burst. No task/provider completion is awaited by the acknowledgement.

A real Rust socket fixture covers 40 buffered frames, mixed text/binary delivery, sequence zero,
failure fencing, new-connection recovery and stale results. A prefix check covers out-of-order
results, duplicate results and integral exponent notation. A real Node/Rust fixture additionally
covers 40 replayed requests producing 120 response writes without reconnect or loss. Affected existing
malformed-frame, catch-up and actual worker-termination cases pass. The first socket-test driver
lost concurrently arriving frames while waiting for results; its corrected bounded inbox retains them,
with the original assertions intact. Failed and successful verification logs are preserved. Final
complete verification passed all 109 Rust tests, formatting, strict Clippy and production build,
plus 819 runtime tests and one skip across 50 files. Read-only review found no remaining blocker
after the ordered-input repair. History page selection and catch-up job policy remain TypeScript.

## Rust catch-up scheduling

The pinned Rust history owner now retains ephemeral plaintext response jobs, one per authenticated
phone and request generation, bound to the exact relay owner/connection epoch. Replacement and
cancellation invalidate old claims. Rust controls round-robin rotation, the 512 KiB congestion pause
and a global 100 ms monotonic dispatch interval. The compatibility timer only wakes the scheduler;
client timestamps and JavaScript wall-clock changes cannot accelerate its interval. A claim must
finish with matching token/phone/request generation before the next can be issued. Retired cards
consume no pacing. Completed jobs release their projection targets rather than accumulating phones.

Jobs are bounded to 32 phones, 65,536 responses and 32 MiB of encoded plaintext per job, 64 MiB in
aggregate. Failure remains explicit and leaves retained historical events/counters intact. The Node
facade keeps authenticated pairing/device currency and refreshes card actionability immediately at
dispatch, including `sync_delta.current`; historical `events` remain unchanged. Encryption and durable
channel-sequence reservation still occur only after claim selection, never when history is queued.
Disconnect, revocation, re-pairing and new request generations invalidate obsolete work. Failure of
an ephemeral cancellation cannot prevent revocation; the connection closes before removal proceeds.
A retired socket's late close callback cannot clear the replacement connection's jobs.

Ordinary synchronous bridge allocations retain the1MiB default. The shared result transport below
now supplies transient large responses from exact Rust bytes, replacing catch-up's per-job allowance.
A real-owner fixture returns multimegabyte UTF8 and numeric extensions, proving the pinned PID
survives and subsequent ordinary RPCs work. The earlier numeric-extension pinned-owner failure and
its original allowance repair remain recorded; no permanent34MiB buffer is kept for every bridge.
Additional contracts verify supersession, round-robin/congestion, stale/duplicate claims, monotonic
pacing, connection invalidation and job/byte bounds. Existing affected sync/catch-up cases pass.
The first build's Clippy boolean-style failure and omitted `done` response field are retained in
verification logs. Final complete verification passed all 110 Rust tests, formatting, strict Clippy,
production build and 821 runtime tests plus one skip across 51 files. Read-only recheck found no
remaining blocker after the numeric allowance and pre-mutation validation repairs. History page
selection, current-state extraction,
capability-specific preview rendering and live approval ownership still remain outside this slice.

## Rust retained-history paging

The pinned Rust history owner now selects replay pages directly from retained JSONL. Released
occurrence cursors keep their physical offsets and decoded-UTF8 prefix hashes, including malformed
lines and valid unterminated final events. Legacy ID cursors retain last-occurrence behavior except
retimed queued messages, which keep their first position. Unknown or rewritten cursors restart
safely; complete-prefix cursors survive appends. Pairing cutoff and approval-status filtering precede
the page limit. Historical duplicate IDs and unknown event fields are retained.

Pages contain at most200 events and target512KiB of encoded JSON, with the existing single-oversized
first-event escape so a large retained event cannot prevent forward progress. `more` reports a byte
or count cutoff, including the released conservative full200-row signal. Oversized first events use
the shared one-result transport described below. The I/O bridge validates the pinned id/result frame
and forwards exact Rust result bytes, avoiding JavaScript numeric re-encoding expansion.

Metadata indexing is bounded to an estimated4MiB per log and16 recent logs, with no cached message
bodies. Beyond that limit, up to256 returned offset/SHA checkpoints per log let normal and globally
truncated sequential pages seek forward. Older arbitrary cursors use a bounded-memory scan. LRU
registration precedes cache publication so failed reads also obey the cap. Unix stamps include file
identity, length and nanosecond modification/change times; Windows conservatively rebuilds because
the supported standard surface cannot establish equivalent replacement identity. Reads refuse
symlinks, non-files, logs over1GiB and physical lines over32MiB. File drift fails explicitly.

The original TypeScript helper is retained as an independent compatibility oracle, with no production
paging caller. Three real-owner contracts cover cursors/retimed IDs, split and malformed UTF8,
EOF/appends/replacements/deletion, pre-limit filtering, byte pages, oversized numeric extensions,
prepared-result currency, cache overflow and exact retained bytes on unsupported legacy input.
JavaScript accepts lone escaped UTF16 surrogates and overflowing JSON numbers that the Rust parser
cannot represent. These cause an explicit unconfirmed query, preserving the complete original file,
rather than silently hiding rows. The first focused run reproduced the high-surrogate skip and the
repair includes its actual parser error. These legacy cases remain a migration compatibility limit;
no conversion or destructive cleanup is claimed.

Complete verification passed110 Rust tests, formatting, strictClippy, production build and824 runtime
tests plus one skip across52 files. The preceding aggregate passed823/1skip and timed out in the
existing multi-step update fixture; its unchanged isolated check passed2.35s. Failed evidence is
retained. The final cache-publication ordering repair was followed by strictClippy/build and all55
affected paging/history/bridge checks. Read-only reviewers checked the cursor, framing and bounds
repairs. Current-state extraction, device-specific rendering, approval/run orchestration and the
actual standalone launcher remain unfinished finite migration work.

## Shared-owner thread metadata transactions

Thread metadata writes now use the pinned history owner's bounded protocol instead of spawning a
Rust process for each native marker, session or metadata update. The same existing transaction
implementation keeps exact-byte revisions, ownership locks, immutable unknown fields, recovery
snapshots and pending-file fences. A storage failure fence still precedes delegation; Node updates
its expected revision only after a validated durable stored/hash proof. The old production process
helper was removed. The standalone thread-index CLI remains available for recovery/compatibility
and existing independent transaction tests; it obeys the same ownership lock.

All nine Rust metadata contracts,47 runtime history contracts and three affected update/drain/queue
checks pass. Complete verification also passes110 Rust and824 runtime tests plus one skip,
formatting, strictClippy and the production build. Read-only review found no remaining defect.
This reduces process boundaries without claiming ownership of run/approval policy yet.

Metadata locking now explicitly unlocks every return and error after acquisition, while retaining
ownership through final publication/readback. Dropping one File can leave a shared open description
locked in a concurrent fork or duplicate ([Rust File locking contract](https://doc.rust-lang.org/std/fs/struct.File.html#method.try_lock)).
An isolated Linux Rust 1.92 diagnostic retained a real duplicate descriptor: the unchanged no-op then
mutation contract failed at the same assertion as CI with WouldBlock/errno11. The acquired-lock guard
makes that diagnostic pass, as well as all nine unchanged Linux metadata contracts. Local validation
also passes 23 Rust metadata/history/readiness contracts, 50 runtime storage/shared-owner contracts,
formatting, strict Clippy and the production build. The original CI timing was not reproduced by
ordinary baseline repetition; the diagnostic establishes the lock hazard without a production hook.

## Shared bounded response transport

Every history-owner operation now uses the same result transport, removing paging-specific handles
and catch-up buffer sizing. Rust serializes a result once, keeps at most one pending response, and
returns a small handle only when it exceeds the ordinary1MiB envelope allowance. The compatibility
bridge fetches it synchronously into a transient buffer proven to fit, capped at34MiB. Any subsequent
ordinary operation invalidates the pending response. Wrong, duplicate and restart-stale handles
cannot consume another result. Handles include a fresh random process epoch and checked serial;
they are internal response currency, never authentication grants or provider credentials.

The real stdio-owner test covers wrong/duplicate handles, ordinary-call invalidation, exact large
UTF8 results, restart currency and preservation of the retained file. The restart case first exposed
a serial-only collision, then passed after the process epoch repair. Failed build, restart and full
runtime runs remain in evidence. The existing update workflow's completion waits now observe exact
final messages, duplicate receipts and archived-thread broadcasts instead of polling runner counts
and storage. All original assertions and its5000ms deadline remain in place. Final verification passes111 Rust and824 runtime tests plus one skip across52 files, formatting,
strictClippy and the production build. Read-only review found no remaining protocol blocker.
This transport does not complete run/approval policy.

## Shared-owner operational journals

Acceptance, durable Stop, irreversible expiration and channel outbox operations now run inside the
same pinned Rust history owner as queue, steering, crypto and metadata. Existing component code,
private files, ownership locks, checksums, recovery snapshots and independent failure fences remain
in use. Stop recording remains available when an unrelated history projection fails. The legacy
attachments CLI delegates these operations through the same root owner, so it cannot become a
second operational writer. Transport and attachment ingress keep their existing separate IO worker.
No additional operational truth store or journal format is introduced by this step; the approved
SQLite migration remains required below.

The async facade snapshots queued input immediately, bounds it to32 requests,32MiB per frame and
64MiB aggregate, and keeps its original30s total deadline through queue wait, RPC and any large
response fetch. Domain error objects remain intact, including the benign admission-not-expired
response; the existing throwing synchronous facade still requires a successful proof. Bound native
monotonic clocks keep IO liveness independent of business/test wall clocks. Independent shared
leases prevent one adapter or host controller from closing another's writer. Each adapter drains
pending operations before release; failed startup closes collected partial owners before their
last lease can disappear.

The expanded real-owner contract exercises large immutable accepted content, direct operational
reads through that same owner, future-expiration refusal followed by valid expiration,32 queued
requests and excess refusal, idle ownership, external writer exclusion and independent release.
Startup cases preserve both ambiguous queue bytes and invalid Stop bytes, then prove root ownership
is released even when failure occurs after an admission lease is retained. Existing component
recovery/failure contracts and affected update/Stop checks pass. Complete verification passes111 Rust and825 runtime tests plus one skip across52 files, formatting,
strictClippy and the production build. Final legacy CLI error-name preservation also passes42 focused Rust component contracts,18
runtime contracts, strictClippy and the production build. Read-only review caught and repaired a queued-deadline reset before this
slice was committed. Run/approval decision policy remains unfinished.

## Rust native dispatch readiness

Before a retained native origin reaches its SDK, the same Rust History owner now checks immutable
acceptance, conversation purpose, durable Stop and expiration, steering ownership/uncertainty,
per-thread queue head, thread worker ownership, the canonical retained origin identity, and stable completion
evidence. Legacy accepted purpose remains immutable and can recover only with matching retained
conversation evidence. Failed operational journals refuse new dispatch. This operation decides readiness; the subsequent SDK attempt claims and callback fencing are
described below. Full approval/control transitions remain unfinished parts of checklist item3.

A paused exhausted owner keeps its marker and queue head. Later work remains queued until explicit
Retry completes that origin; it cannot replace the interrupted task. Every refused dispatch settles
its in-memory admission. Queue draining shares the existing Node availability/steering fences,
retains uncertain follow-up evidence, and retires a durably stopped queue row while keeping its Stop
record and unconfirmed status. Restart Stop recovery can therefore admit fresh work without inventing
an old terminal reply or claiming confirmed cessation.

Three real Rust-owner contracts cover acceptance, FIFO, stable completion, Stop, expiration,
approval replies, steering uncertainty, failed journal fences, retained-body conflicts and paused
ownership. The existing failed-result/Retry and Stop-restart tests now check queued successors.
Failed follow-up preparation also verifies host responsiveness and retained work. Against isolated
unsafe sources, a new message caused five SDK calls instead of one; the stopped head remained;
and preparation failure starved the event loop until an external18-second deadline terminated only
that test process group. All six focused repaired runtime cases pass. The long update integration fixture is split at its
installation boundary, preserving queue/countdown/control and reconnect/cutoff/replay assertions
under the original 5-second deadlines. Verification passes 114 Rust tests and 827 runtime/plugin
tests plus one skip across 52 files, formatting, strict Clippy and the production build.
Retained run evidence uses the existing bounded JSONL reader and exact file identity checks; it
currently scans the retained log. SQLite indexing remains checklist item6, not a second truth store.

## Rust-issued SDK callback ownership

Each native SDK iteration now claims a fresh Rust-issued internal attempt ID after the existing
operational readiness checks. The same History owner persists it on the existing nativeTurn through
metadata CAS; there is no new truth file or credential. At most 1,024 active thread scopes are retained.
The process registry excludes previous iterations and dead Rust-owner epochs. Same-thread recovery
claims retain the origin/completion IDs and increment the bounded recovery count from current metadata.

SDK callbacks capture the issued scope. Session updates, steering hooks, stream updates, new tool
calls and permission requests require the exact current running scope without Stop/expiry. Approvals,
questions and tool waits recheck after awaits and share an iteration abort signal. Settled iterations
cancel orphaned requests. Buffered observations flush before replacement; a result for an already
observed open call may still be recorded under exact ownership after Stop. Explicit completed results
retain the existing completed-after-Stop exception. Losing ownership pauses recoverable work; policy
denial is distinct from lost ownership. Stable final evidence prevents a late ownership loss during
change reporting from resurrecting a completed task. Change reports finish before releasing the scope
and advancing the same-thread queue. Synthetic native origins also enter accepted/queue currency.

The actual late-callback regression failed for both Codex and Claude within one host before this
change; replacing the host already passed. The extended owner test now covers four replacement cases,
including stale session/activity/stream writes and rejected old approvals/questions/tools. All42
focused native recovery/Stop tests pass with assertions unchanged. An initial implementation dropped
an already-running tool's result during Stop; the retained failing log and repaired existing Stop test
preserve that evidence. The Rust owner contract exercises fresh/replaced/restarted scopes and separates
Stop denial from ownership while retaining metadata bytes. The first full runtime run passed829
plus1skip/52files, and115 Rust tests passed; strictClippy and production build passed after an
equivalent Boolean simplification. A further real scheduler regression then proved that native jobs
waiting behind a worker had not entered durable history/acceptance. Native synthetic admission now
precedes FIFO reservation, including direct legacy turn callers, so queued jobs survive host recovery.
The failing baseline expected2 retained origins but got1. The follow-up full runtime run passed830
plus1skip/52files. Final cleanup also recognizes a durable terminal produced during a pre-claim
Stop/pause, preserves the exact retained scope and only clears that marker; it cannot block a
successor or clear a replacement. Pre-claim runs cannot publish unowned change reports. The exact
Rust Stop-denial proof now explicitly checks that ownership remains true. After these final cleanup
refinements, all4 Rust ownership and43 focused native runtime tests pass, along with formatting,
strictClippy and production build. The830-test full run preceded those final cleanup refinements;
its passing log and the final focused validation are retained separately.

This is an incremental callback boundary. Generic metadata/control/startup transitions and successful
result/explicit Retry recovery resets still use the compatibility host; their full Rust policy and
approval ownership remain checklist item3. The bounded provider-worker contract, platform IPC,
standalone launcher, SQLite/Markdown conversation plan and native release gates remain items4–7.

## Rust-owned native session persistence

Native SDK session and rewind IDs now enter the existing metadata CAS through a scoped Rust
operation. It accepts only effect or terminal policy, validates the live issued attempt and origin,
and rechecks that the exact mutation snapshot is still running. Owned-only cleanup proof cannot
write a session, including after Stop. Terminal mode retains the established completed-after-Stop
exception. Generic index replacement rejects session-field changes while an issued attempt marker
is retained; caller JSON cannot grant the internal crate-function privilege. Legacy records without
an issued attempt remain compatible, and metadata backups and unknown fields are preserved.

A denied or failed scoped write is an error, distinct from an unchanged session. The SDK observer
aborts and pauses before returning that error, so a custom worker cannot swallow it and continue
streaming, tool effects or completion. When interrupted state cannot itself be persisted, a sticky
process-local availability fence blocks automatic admission, queue draining and recovery for that
thread. Unconfirmed attempt claims use the same fence when they cannot confirm an interrupted
marker, including absent-marker cases. Durable accepted origins, queue entries and conflicting files
remain intact. A confirmed unconfirmed-write pause retains its own pause reason, exposes the existing Retry
control and suppresses the recovering indicator without changing the recovery counter. Automatic
resume leaves that explicit pause intact across restart; Retry clears it only after a successful
metadata write. A marker left running by unavailable storage requires storage repair and restart;
current Retry handlers do not project an unpersisted pause. This fence is not a competing truth store.

The retained regressions use actual Rust requests and real metadata conflicts. They cover a paused
mutation snapshot, a swallowed session write error, persistent session conflicts and failed claim
storage without worker launch or repeated admission. Removing the persistent session fence causes
the negative control to exceed its owned external deadline; with the fence, the host answers its
thread-list request and preserves the conflict and marker. The Retry projection regression initially lacked the visible Retry control and reported recovering;
the retained baseline and repaired summary checks cover that false status. Generic control/startup
transitions and recovery resets still remain item3 work; this slice does not complete the Rust orchestrator or the
standalone conversation interface.

Validation for this slice: all115 Rust tests, formatting, strictClippy and the production build
pass. The full runtime/plugin run passes834 tests plus1skip across52files. That aggregate preceded
the final pause-reason projection; after it, production build and101 focused summary/native
recovery/Stop/queue/restart tests pass. The final explicit-pause extension additionally passes both
same-host and restarted-host Retry cases without automatically launching a replacement worker or
changing the recovery budget. All commands are terminal; baseline and passing logs are retained.

## Rust-owned interrupted run controls

Explicit Retry and Dismiss now use typed Rust operations against the existing interrupted nativeTurn.
Both match the exact thread, completion, retained origin and optional issued attempt; an omitted
attempt only matches a legacy marker with no attempt. Retry validates accepted conversation history,
FIFO ownership, Stop, expiry, uncertain steering and stable terminal evidence before resetting the
recovery counter and clearing the explicit pause reason through metadata CAS. A legacy interrupted
origin missing its queue row can repair an empty per-thread queue only after all non-queue
eligibility and retained evidence pass; it cannot move behind or reorder a successor. Repair status
is mirrored even if a later transition remains unconfirmed. A retained completed origin or missing
history cannot create a queue row. Dispatch still claims and rechecks readiness separately.

Dismiss durably removes its queue row before clearing the checked interrupted marker. A failed queue
write retains both. If queue removal succeeds but metadata CAS fails, Rust reports that partial
outcome: the compatibility host updates its queue mirror, preserves the marker and fences automatic
execution. Retrying Dismiss after storage repair can clear the exact marker and advance waiting work;
it cannot clear a replacement index revision. Existing Stop denial also applies to legacy markers
without an origin by checking their canonical completion's Stop target. No-origin legacy Dismiss
remains supported. Accepted origins and historical evidence are preserved rather than fabricated as
completed replies.

The actual previous Dismiss storage regression erased the paused marker while its queue removal
failed. The retained negative baseline and repaired workflows cover both queue failure and partial
metadata failure, preservation of waiting work and exactly one successor execution after confirmed
Dismiss. Core cases also cover empty legacy queue repair, issued-scope mismatch, Stop/expiry/steering,
terminal evidence, successor FIFO protection, recovery snapshots and legacy Stop denial.

This slice transfers explicit interrupted-control policy only. Generic marker lifecycle/startup and
successful-result resets still use Node compatibility paths; full approval currency remains unfinished
item3 work. Claim recovery admission is now derived by Rust as described below. The provider-worker contract, platform IPC, standalone
launcher/conversation persistence and native release gates remain required later items.

Validation for interrupted controls: all119 Rust tests, formatting, strictClippy and production
build pass. The full runtime/plugin suite passes837 tests plus1skip/52files. That full aggregate
preceded the final eligibility-before-repair fix; after the fix, all119 Rust tests, strictClippy,
production build and104 affected native/summary/recovery/Stop/queue/restart cases pass. The retained
terminal-without-queue negative baseline demonstrates the repair bug; repaired guards also cover
missing retained history without modifying queue bytes. Earlier new-fixture/read-operation and
Clippy failures were corrected, with their logs preserved separately. All commands are terminal.

## Retained-state recovery admission

Rust now derives initial/recovery admission and its counter from retained nativeTurn state. A running
marker cannot be replaced, including after loss of the Rust process epoch. An interrupted marker
increments the retained counter up to three automatic recoveries; a caller's recovering hint cannot
reset it. Integer-valued legacy JSON counters such as 2.0 retain their meaning. A pauseReason blocks
admission until the existing typed explicit Retry confirms its reset. Successful claims return both
the authoritative recovering flag and counter; Node uses them before constructing the SDK prompt.

After an SDK failure with observed execution, Node confirms interruption of the exact origin and
issued attempt before requesting a replacement. A failed interruption write fences further dispatch
and preserves the running marker and durable queue for storage repair. Known claim policy refusals
preserve the current marker; uncertain persistence can only pause the previously captured scope.
This does not migrate the remaining generic Stop/rewind/pre-SDK marker lifecycle or
progress-based counter resets. Those remain item3 work before the bounded provider worker and later finite items.

Validation: all120 Rust tests, formatting, strictClippy and production build pass. The complete
runtime/plugin suite passes841 tests plus1skip/52files with one local worker and unchanged five-second
test deadlines. Two local two-worker runs each had a different existing integration flow time out;
both flows subsequently pass under the original deadlines in the focused diagnostic (eight cases).
Repository CI remains at two workers. Negative baselines demonstrate caller-driven budget admission
and replacement marker mutation; regression coverage includes legacy numeric counters, running owner
refusal, sticky uncertainty, explicit Retry, failed interruption storage and unchanged replacement
marker/queue bytes. Initial new-fixture barrier/title issues were corrected and their logs retained.

## Scoped Rust pause and terminal cleanup

Issued attempt pause and finish now use typed Rust metadata transitions. Both match the exact thread,
canonical completion, retained origin and issued attempt. Rust verifies the accepted-origin
fingerprint against retained history; cleanup requires the same-thread canonical agent message with
done=true. The unrelated exhausted-recovery advisory cannot satisfy that proof. Terminal evidence is
checked independently of dispatch admission, allowing cleanup after Stop, expiry or FIFO advancement.

A conservative pause can survive loss of the Rust process epoch without granting new execution. It
preserves counters, unknown fields and existing sticky uncertainty. A known terminal refuses pause
and tells Node to retire the completed scope without another final or recovery advisory. A replaced
or absent scope aborts only the captured worker; it does not rewrite the replacement or install a
permanent storage fence. Unconfirmed storage/evidence stops recovery and fences dispatch.

Issued SDK error/session/update/ownership-loss pauses now use these operations. Node awaits the
changed-files report before typed terminal cleanup and attempt release. Failed finish persistence
retains the canonical final and original marker while queued successors remain fenced. Known
pre-SDK updates with no issued attempt retain their compatibility path. Generic Stop/rewind/pre-SDK
transitions and full approval currency still require migration; generic nativeTurn writes are
not yet sealed. This remains a partial transfer within finite item3.

Validation: all123 Rust tests, formatting and strictClippy pass; production build and the complete
runtime/plugin suite pass843 tests plus1skip/52files with one local worker and unchanged deadlines.
Focused checks pass12 Rust readiness/lifecycle cases,76 affected runtime cases, and two new runtime
terminal-known/finish-conflict cases. The previous runtime's actual terminal-known negative leaves
waiting work stranded; the repaired path advances it once without another final or advisory. Core
cases cover epoch loss, replacement scopes, sticky state, noncanonical/wrong-role/wrong-thread
terminal evidence, independent Stop/expiry/FIFO cleanup and persistent metadata conflicts. Prior
admission checkpoint c10706f CI passes all jobs under the normal two-worker configuration; this
remains distinct from the required exact native26.5 release gate.

## Legacy complete-row delimiter preservation

A complete legacy JSON row without a trailing newline stays in visible history when a new event
is appended. Rust verifies the bounded tail and appends exactly one newline before publishing the
new transaction; original whitespace, numeric spelling and unknown fields remain byte-for-byte.
Append-mode descriptors, raw-prefix hashes, path/descriptor identity checks and normalized-log bounds
protect the operation. Target fields and journal schema remain unchanged, with lengths and hashes
covering the normalized prefix for retry, restart and old-reader compatibility.

An independently normalized projection may retain its delimiter when another destination refuses
preparation. That does not accept a new event or publish its transaction; recovery requires reopening
the existing fault-latched owner. Genuine incomplete tails retain the existing exact recovery copy
and tail-only repair. JS-readable values unsupported by serde, including lone surrogates and
out-of-range numbers, explicitly refuse append while preserving visible bytes.

Validation: all127 Rust tests, formatting and strictClippy pass. The27 focused history/readiness
cases include mixed thread/transcript termination, original retry, restart with an uncommitted
existing-format intent, second-projection refusal and preservation of the accepted native origin
through final cleanup. Actual prior-code negatives lost visible bytes/origin and accepted unsupported
tails; logs are retained with the initial recovery-fixture failure. No runtime TypeScript changed in
this slice. The preceding scoped-lifecycle checkpoint2be39cd passes every CI job, including normal
two-worker runtime and Rust on all three platforms; exact native26.5 remains a separate release gate.

## Scoped Rust retained-progress reset

Rust captures one raw physical history-prefix cursor per issued attempt, within the1024-owner cap.
A progress reset requires the current running scope and effect admission, including Stop and expiry
checks. It accepts only the first successful MAIN same-thread tool_result occurrence after the
claim and last confirmed cursor. A replayed old success cannot replenish the recovery budget by
being appended at a later offset. A failed-only ID can later supply its first retained success.
Activity IDs retain the event record budget rather than the shorter origin-ID limit.

Raw-prefix hashes detect truncation or rewrites, with physical identity checks on Unix. Metadata
CAS resets only recoveryAttempts, preserving recoveryActive and unknown marker fields. The cursor
advances only after confirmed CAS; a failed metadata write leaves both cursor and counter intact.
Node removes its unbounded result-ID set and uses the authoritative result. Unconfirmed progress
aborts and fences the worker independently of callback exceptions, suppressing even an explicit
completed result if a provider swallows the observer error. Normal duplicate refusals leave the
counter untouched. This still trusts the compatibility worker's scoped admission; full origin and
attempt provenance belongs to finite item4.

Validation:131 Rust tests, formatting and strictClippy pass locally; production build and the full
runtime/plugin suite pass846 tests plus1skip/52files with one local worker and unchanged deadlines.
The17 readiness cases include successful progress, failed-then-success IDs before/after claim,
replays, successive fresh successes, long IDs, wrong sender/thread, absent/failed results, Stop,
expiry, scope replacement, epoch loss, metadata conflict retry, same-inode rewrite and Unix file
replacement. Five focused runtime cases pass; actual previous-Node negatives blocked a first
success after an earlier failure and failed to abort a swallowed storage error. Prior failed
fixture/lint logs are retained. Each progress proof currently hashes and scans retained history
from its beginning, so CPU cost grows with history despite bounded memory; no speedup is claimed.
Generic Stop/rewind/pre-SDK marker transitions and approval currency remain within item3.

## Scoped Rust boot reconciliation

Native boot marker reconciliation now uses a typed Rust preview and metadata transition. The
checked expected marker uses the existing safe-number compatibility rule, allowing valid legacy
2.0 counters while refusing rounded opaque values beyond the safe-integer range. Rust clones its
retained marker and preserves counters, recoveryActive, sticky pause reasons and unknown fields.
A thread with an issued live Root registry owner refuses boot reconciliation.

Bounded same-thread history evidence identifies a real user origin, canonical issued completion,
and successful rewind visibility. Legacy canonical IDs may infer an origin only from a retained
user row. The supported unissued literal-final case can retire from matching agent/done evidence;
arbitrary no-origin legacy markers stay paused and dismissible. User-role or wrong-thread rows
cannot satisfy completion. A proven rewind-hidden origin retires distinctly from an unexplained
missing origin, which remains retained and explicitly unconfirmed.

Node first checks the scope, persists dead-card no/Interrupted answers, then asks Rust to recheck
and apply metadata CAS. Card retirement occurs before the marker changes, so a failed write or
crash can retry without losing the cleanup trigger. Existing answers suppress duplicates, including
repeated card IDs; interrupted markers also retire their dead cards. Card enumeration remains the
Node full-history compatibility path. No boot operation grants execution or requires Accepted to
have initialized. Confirmed orphan PID termination remains first; acceptedReady and durable Stop
recovery still gate actual resumption.

Validation:134 Rust tests and formatting pass; strictClippy and production build pass. The complete
runtime/plugin suite passes850 checks plus1skip/52files locally with unchanged deadlines and one
worker. Focused validation passes20 readiness cases and nine startup/rewind/runtime cases. Actual
previous Node code erased a marker from a user-role final and discarded a missing-origin marker;
reviewed strict equality also rejected unchanged raw2.0. Those negatives and the initial numeric
fixture setup failure are retained. Metadata conflicts retain the old marker after dead-card
answers, and retries retire each card once. Full approval currency and remaining generic
Stop/rewind/pre-SDK transitions still belong to finite item3.

## Scoped Rust paused-Stop cleanup

A durable same-thread Stop with status unconfirmed or stopped can now retire its exact retained
paused native marker through run_turn_stop_clear. Rust checks the canonical origin, interrupted
state, existing safe-number compatibility and current registry owner before metadata CAS. It retires
that registry only after confirmed storage. Missing/requested/wrong-thread Stop evidence, running
markers, replacement scopes and replacement registry owners preserve state. An absent marker is a
safe no-op. Queue, history and Stop records remain unchanged; this operation grants no execution
and does not publish a synthetic final or turn uncertainty into confirmed cessation.

Node captures the marker before awaiting durable Stop storage. Failed cleanup retains the marker
and allows replay to retry without a permanent Stop-only storage fence. Startup also retries
unconfirmed/stopped paused markers, while the existing accepted and Stop recovery gates still
precede queue dispatch. After confirmed cleanup, normal queue draining retires the stopped row and
advances waiting work once. A scope replaced during the Stop write remains intact.

Focused validation passes21 Rust readiness cases, strictClippy, production build and28 runtime
Stop cases. Actual previous Root code rejected the new operation; previous Node code stranded
waiting work after a metadata conflict, failed startup recovery and erased a replacement marker.
Those failures and the final positive evidence are retained. Full validation passes135 Rust tests
and formatting plus853 runtime/plugin checks and1skip/52files with one local worker and unchanged
deadlines. One initial full run timed out only in the existing external-queue-mutation case; that
case passed unchanged in489ms at its original five-second deadline, followed by the green full rerun.
Both runs are retained. The broader Stop fallback, rewind,
pre-SDK/unissued marker transitions and full approval currency remain within finite item3.

## Scoped Rust rewind retirement

Edit from here now reconciles the exact durable successful rewind through run_turn_rewind. Rust
checks its event and request identity, same-thread main-agent result, and real user anchor physically
before the rewind. Two bounded history passes prove only explicitly hidden prior user IDs from the
existing queue and retained marker. Agent rows, missing rows, other-thread ownership and users first
appearing after the rewind do not authorize removal. Failed, ambiguous or foreign rewinds refuse
cleanup. Root admission and explicit Retry also refuse retained hidden origins.

The authoritative native queue retires all proved rows in one save, preserving its existing raw
recovery snapshot and unknown fields. Every confirmed result returns the entire remaining queue,
including no-op retries and metadata-CAS failures. Node refreshes that mirror before interpreting
the marker result, so a lost response or partial write cannot leave a stale hidden queue head.
History, accepted and Stop evidence remain retained.

Only the captured safe-compatible canonical interrupted marker may clear, with an exact matching
registry owner when present. Running, replacement and mismatched registry scopes remain intact;
registry retirement follows confirmed metadata CAS. Queue-only recovery works after boot has
already cleared a hidden marker. Replays retry cleanup, and startup reconciles all retained rewinds
for affected threads after accepted/Stop recovery and before resuming or draining work. A successful
cleanup also retires stale reply buffers when no current native marker or running replacement owns
them. Provider-backed Yorozu rewinds retain their compatibility route.

Focused validation passes23 Rust readiness cases, strictClippy, production build and seven runtime
rewind/Edit-from-here cases. Actual old code retained hidden queued work, stalled multi-rewind
startup and erased a replacement scope. The reviewed candidate also emitted false native uncertainty
for a legacy provider; its regression was reproduced and fixed. Initial capability/observation
fixture failures are retained separately; startup now checks durable completion plus explicit sync.
Full validation passes137 Rust tests and formatting, plus856 runtime/plugin checks and1skip in
52files with one local worker and unchanged deadlines. The complete run finished successfully after
a brief execution-connection interruption; its owned process terminated with exit0.
History scans remain bounded by existing log/record limits but repeat for each selected rewind;
this slice makes no latency improvement claim. Remaining pre-SDK/unissued marker lifecycle,
broader Stop fallback and full approval currency still belong to finite item3.

## Scoped Rust unissued pause and retirement

The pre-SDK lifecycle now uses typed run_turn_unissued_pause and run_turn_unissued_finish.
Rust compares the exact captured nullable marker using safe numeric compatibility. Any attemptId
field or live registry entry refuses unissued ownership. Null pause creation also requires the
actual FIFO head. Existing counters, recoveryActive, pause reasons and unknown fields survive;
creation starts at zero and never issues a worker or increments recovery. Accepted conversation,
real user, durable Stop/expiration, rewind and terminal evidence prevent resurrection. Metadata
CAS must confirm before Node receives the authoritative paused marker.

Node retains that returned scope for later cleanup and never adopts a replacement through a
fresh metadata read after a refused claim. Pure retirement requires physical canonical agent
completion and its real user origin, independently of dispatch, Stop, expiration, FIFO or retry
budget. It preserves queue/history and refuses every replacement or issued registry. Update now
also pauses turns still waiting before SDK issuance; issued work retains its existing approval
and tool safe boundaries. A known terminal clears the stale automatic-resume flag.

The focused Rust suite passes25 readiness tests and strict Clippy. Production build and five
runtime cases pass, including a real Git child-process wait interrupted by Update, zero issuance
before that pause, one issuance on recovery, an issued replacement preserved byte-for-byte,
and a refused claim preserving both replacement metadata and a foreign queue. The actual old
runtime fails the ownership and pre-SDK Update cases. An initial title-observation fixture race
and the missing production pre-SDK Update boundary are recorded separately. Full validation passes139 Rust tests and formatting, plus859 runtime/plugin checks and1skip
in52files with one local worker and unchanged deadlines. Scoped preflight failed-final publication, broader Stop
fallback and full approval currency remain within finite item3; generic writes are not sealed.

## Scoped Rust preflight failed-final publication

Missing-runner and missing-folder replies now use run_turn_preflight_finish. Node captures the
native marker before those checks; Rust proves its exact nullable scope, canonical origin, accepted
conversation and real retained user before admitting the failed final through the existing history
journal. A metadata writer lease spans scope validation and journal admission, followed by its
lock-aware CAS. A running or foreign registry refuses publication. An exact interrupted issued
marker may retire with its matching paused registry, or after restart without that registry.
Cleanup issues no worker and does not depend on dispatch, FIFO, expiration or retry budget.

The operation accepts only the two existing preflight reasons and generates the canonical error
reply in Rust. Its scope-bound deterministic key normalizes safe numeric notation and recursively
sorts object keys while preserving opaque values. Retried publication verifies the original Entry,
checksum and committed projection, then returns the original final bytes and timestamp/day. It
never creates another transcript record from a fresh retry timestamp. The existing Entry/Target
formats, accepted records, queue, Stop journals and recovery snapshots remain intact.

Stored-final confirmation is separate from metadata cleanup. A failed CAS retains marker/registry,
returns the already durable final and permits exact retry; registry retirement follows confirmed
CAS. Journal admission/recovery failure fences future execution while retaining independent Stop
writes. Replays after successful retirement return the same original final without adopting a new
registry. Node broadcasts only Root-confirmed final evidence and no longer performs generic clears
in these two preflight paths.

Twenty-seven readiness tests pass, including a held metadata writer lease, replacement/running/
foreign-registry refusal, paused issued retirement and retained final cleanup after restart across
midnight. The actual old runtime publishes a false terminal reply after a replacement Root claim;
the repaired runtime preserves the registry and exact metadata and emits no final. The candidate's
initial object-order retry bug was independently reproduced and repaired; key stability now covers
nested and numeric-string keys and safe numeric variants. Strict Clippy, production build and three
focused runtime cases pass. Complete validation passes141 Rust tests and formatting, plus860
runtime/plugin checks and1skip in52files with one local worker and unchanged deadlines. Broader Stop
fallback and full approval currency remain within finite item3; the whole standalone migration is unfinished.

## Rust native Stop fallback decision and currency

The fallback reached when no local native runner owns the Stop target now uses
run_turn_stop_fallback. Rust holds the metadata writer lease, checks durable same-thread Stop,
immutable Accepted origin and real user evidence, and classifies canonical terminal history.
Only role-agent done=true is completion; interrupted agent completion means stopped. A canonical
ID occupied by a user, another kind, a nonterminal row or conflicting terminal meanings remains
unconfirmed without publication or overwrite. Hidden origins do not authorize a new final.

A new stopped reply requires exact captured null scope, no registry and actual FIFO ownership of
pending work. Every retained marker or registry makes absence of a local controller insufficient
evidence of cessation. Running/replacement scopes remain intact and receive an unconfirmed Stop.
The existing exact paused-Stop cleanup can then retire an interrupted captured scope after durable
Stop currency, with the writer lease already released. The fallback itself never changes metadata,
registry, queue or accepted history.

Rust records the decided Stop through the existing Stop journal and returns confirmed currency
separately from saved-final evidence. A Stop write failure returns the last known requested record
and stopConfirmed=false while preserving any saved final. The common final-journal helper retains
the previous preflight key/schema and original event bytes/day; Stop keys exclude growing request
IDs. Restart can confirm a saved final without another history/transcript append. Partial history
admission still fences dispatch while independent Stop writes remain available.

StopStore.reconcileNativeFallback awaits all pending target writes, then performs synchronous
Root mutation and adoption of both confirmed and reservation mirrors without an intervening await.
It validates target/thread, retained request IDs and terminal status. Only a real Stop-currency
failure fences that store. Node's initial Stop and steered completion selectors now require strict
agent terminal proof, so they cannot bypass Root with a user/done row.

Actual old runtime regressions report stopped for an issued replacement and completed for a
retained user/done row. Both fail before the repair and pass afterward. Twenty-nine readiness
cases, strict Clippy, production build and39 focused Stop/preflight runtime cases pass, including
startup greeting gating and replacement during post-currency cleanup. The fixtures now gate the
actual StopStore reconciliation boundary and use its real Root result. The complete checks pass:
143 Rust tests and862 runtime/plugin tests, one existing skip, across52 runtime files with the
original deadlines and one local worker. Active-worker acknowledgement provenance and provider/plugin approval
currency remain unfinished; this does not claim the entire orchestration or standalone migration.

## Rust native permission admission

Native SDK approval cards now use native_approval_raise with the captured Rust-issued origin,
canonical reply and attempt IDs. Rust verifies its live registry, same agent, actual Accepted
conversation and retained user evidence under the metadata writer lease. It refuses Stop,
expired admission, rewound origins, terminal history and replacement attempts. The card's immutable
tool/input and nativeRun are saved through the existing history journal before publication.
Questions and plugin rules/grants retain their existing paths for later finite work.

native_approval_decide authenticates that registration and any previous applied status through
owned journal/projection evidence. Public history_append reserves native-approval-* operation
names; arbitrary matching public rows cannot grant permission or consume the registered card.
A bounded retained-history scan supplies card evidence, rather than another operational truth store.
The Node waiting map is only a liveness veto and never selects a newer attempt. Root applies the
existing MCP notification restriction, thirty-minute answer lifetime and five-minute future-clock
allowance, and also expires an old card despite a newly timestamped answer.

The original answer and status share one journal transaction and host admission day. clientTs
retains the original device timestamp. Stable request identity authenticates action/answer/source/
rule content; a conflicting reused request ID remains uncertain without overwrite. Retries prove
original bytes and projections, return the original status and never release another SDK execution,
including after host epoch loss. Rejected notification answers retain the prompt. Stale/expired
answers settle false. Initial YOLO for host approval callbacks and late YOLO for waiting cards use
this captured registration/admission boundary. The SDK's own bypass configuration remains a Node
compatibility setting until the worker contract migrates it; SDK checks it suppresses do not raise
host cards. Native approvals still install no task grants or permanent rules.

Node removes the waiting card only after Root admission, before confirmed publication, and checks
its captured effect scope and abort signals again before the SDK receives permission. Storage
uncertainty pauses/aborts that captured worker even if it ignores the denial. A thrown native queue
turn remains fenced/uncertain and cannot use the generic provider error-final writer.

The actual old Node implementation reports applied for a released/replaced attempt and returns true
to the SDK after its separate status projection fails. Both regressions fail on the signed baseline.
The focused candidate passes two Root permission tests, strict Clippy, production build and fourteen
runtime cases, including encrypted transport, notification rejection, both YOLO paths, Stop and drain.
Initial type rebuild, Clippy and unhandled generic-fallback failures are retained with final evidence.
The final Rust source passes145 tests; the complete runtime/plugin rerun passes864 tests and one
existing skip across52 files with one local worker and unchanged deadlines. The initial full run
exposed four SDK fixtures lacking a real Root owner and an application-clock test that also advanced
the phone answer by24 hours. SDK fixtures now use actual Accepted/FIFO/claim ownership and distinct
answer IDs; the phone keeps real time while the update clock advances. That failed run and the final
rerun are retained. Broader plugin approval policy/currency, questions,
worker cancellation acknowledgements and the remaining finite migration are still unfinished.

The Rust host now admits version1 `run_attempt_result` envelopes with captured thread, origin,
canonical reply, attempt and source-agent IDs. Under the native writer lease it validates the
actual issued owner, Accepted conversation, retained history, rewind/conflict and expiry evidence.
One reserved `worker-result:` journal operation per attempt preserves original final bytes and
host timestamp across retries/restarts; alternate outcome/text is refused. The final proof remains
independent of a failed Stop-status save. This operation does not retire metadata or remove FIFO
entries; the existing exact `run_attempt_finish` remains responsible for retirement.

Normal returned replies may use compatibility evidence while no Stop exists. A pending Stop needs
explicit successful provider-terminal evidence for completion, or provider-terminal/owned-process-exit
cessation for interruption; a settled promise is unconfirmed. Interrupted text comes only from
durable host partial text. An existing terminal Stop bars fresh publication. Boolean failure shape
is validated and failed replies cannot confirm successful completion after Stop. Native adapters and
Node result/Stop integration are still the next step; this API alone does not fix the active-worker
runtime path or complete the bounded worker contract.
Verification: 149 Rust tests passed; four focused result regressions and strict Clippy also passed
after final shape guards. Two new runtime regressions still reproduce the old Node false-Stop path
and remain uncommitted for the adapter integration. The result API is a preparatory finite item3/4 slice.

## Isolated alpha CI

Push CI now includes the exact `v0.6.0-alpha` branch and runs the existing full checks, including
Rust on Linux/macOS/Windows. Runtime tests use two workers to bound process/storage concurrency
while retaining individual deadlines. Automatic Release, Release Please and website deployment
still exclude the alpha branch. This enables verification only: no upload, publication, beta feed
change, native-gate exemption or installed-app replacement follows from an alpha CI push.
The native iOS 26.5 release gate and internal-only distribution remain required later steps.
The first alpha CI run passes Rust checks/tests on Linux and macOS, release checks, relay image,
website and iOS compilation/catalog checks. Windows strict Clippy exposed an existing admission
import used only by a Unix Stop test; that import is now local to its Unix fixture. Assertions and
lint rules remain intact. The follow-up CI at `43b3a569` passes Rust checks/tests on all three
platforms and the TypeScript suites, release checks, web, relay image and iOS compilation/catalog.
The shared Swift suite exposed a short-deadline sign-in fixture race: an explicitly delivered
failure could lose to the unrelated 100 ms timeout under full-suite load. The fixture now separates
actual short expiry from delivered legacy/failure replies using the production deadline. All original
draft, attachment, retry, correlation and failure assertions remain; production timing is unchanged.
The three focused readiness tests and all 455 shared Swift tests pass locally, including the relay
and reconnect harness. Temporary build products avoid generated Finder-metadata signing failures.
The local toolchain is Xcode 27, and CI latest-stable currently uses Xcode 26.6; neither proves the
required iOS 26.5 release gate. This is not proof of the still-unimplemented Windows local transport
or a standalone host. The signed `d8f244e` follow-up passes every CI job, including all three Rust
platforms, shared Swift, runtime/plugin suites and native iOS build/catalog checks.

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

The clarified permission direction is comprehensive initial setup for selected capabilities,
remembered preferences and explicit standing grants, so ordinary remote work avoids repeated dialogs.
Preferences can reduce clarification but do not infer authorization from annoyance or retrieved text.
Keep a foreground capability matrix, preflight and real smoke tests, stable application identity and
a native Swift capability broker separate from portable Rust. Passive runtime health checks never
trigger consent dialogs: report ready, needs permission, needs sign-in, unsupported or check failed,
pause only dependent tasks, and send a precise next step. Separate OS/browser access, service
OAuth/MFA and action scope. Do not automate OS security dialogs or grant actual permissions during
development. This supersedes a blanket consequential-action bypass interpretation of YOLO; central
policy reuses explicit grants and records decisions/execution with visible mode and Stop. Unknown
external outcomes remain explicit and need reconciliation; use provider-supported idempotency when
available and never claim universal exactly-once external effects. Voice remains deferred.

Normal conversation hides scripts, raw tool logs and execution traces. A native three-dot working
indicator reflects authoritative running task activity, with meaningful acknowledgements, milestones,
blockers and final results anchored to task/origin IDs and deduplicated after reconnect. Waiting,
queued, blocked, disconnected and failed states must not animate indefinitely or imply completion;
concurrent/background jobs aggregate sensibly with accessibility and reduced-motion support.
Advanced settings expose technical details/commands as an optional preference, off by default and
persisted per user. Both views redact secrets/sensitive credentials or tool arguments; neither shows
hidden chain-of-thought. Advanced settings also select the LLM behind the single Yorozu agent using
current capabilities/catalog/provider configuration. A model change retains conversation, PAIOS and
task identities, applies safely to subsequent turns and does not change an in-flight task's recorded
model. Unavailable models and interrupted changes need explicit recoverable states. These are pending
finite UI/orchestration requirements, not implemented behavior in the current compatibility host.

## Accepted account access priority (implementation pending)

Yorozu is initially a free open-source local tool: this checkout has the existing MIT license,
which remains unchanged. Users supply their own supported provider accounts and pay their providers.
Do not add Yorozu subscriptions, credits, inference resale or managed-model billing. ELM is a
separate managed service and this decision does not change its pricing or eligibility.

The primary connection is official Sign in with ChatGPT for an eligible open-source local client.
Use dynamic client registration and user authorization, without a partner API key/client secret
([official quickstart](https://developers.openai.com/siwc/quickstart)). Account/access source,
LLM selection and internal execution worker are separate identities behind one visible Yorozu agent.
Supported installed Codex/Claude Code routes are optional alternatives; API keys are the last
setup and implementation priority, in Advanced settings, not an alpha prerequisite or default.
No live authorization, new key or private credential extraction is authorized by this design.

Use the supported direct Responses route for Yorozu's own loop, or the official Codex app-server
connection with app-owned Sign in with ChatGPT credentials, avoiding a second Codex sign-in
([official app-server route](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server)).
Keep the portable Rust boundary on the supported JSON-lines protocol; do not claim an official
Rust SDK. App-managed conversation history remains required with streaming HTTP and `store:false`.
The preview permits custom local function tools but excludes hosted computer use, MCP connectors,
image generation, hosted file search/code interpreter/tool search, audio/video and Files uploads
([preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)).
Existing plan usage/quota is shared; never silently switch to billed API or opt into credits.
Check the current account-scoped catalog and actual eligibility, rather than treating cached model
names as entitlement proof.

Claude connection must use the provider-managed, unmodified installed Claude Code binary with its
built-in authentication options, and users authorize directly. Do not implement Yorozu-owned
claude.ai OAuth, collect/intermediate credentials or resell access
([official legal guidance](https://code.claude.com/docs/en/legal-and-compliance)). Validate these
contracts using synthetic credentials before any separately authorized live connection. Voice stays
deferred. During setup users may opt into automatic compatible updates of installed Codex and
Claude Code using the official installation route. Update only while idle, without interrupting
in-flight tasks; exclude competing updaters, smoke-test protocol/start/auth using synthetic data,
and retain the known working version for rollback on failure. Advanced settings retain manual
version control. This requirement does not authorize updating the user's installed CLIs now.
This priority belongs to finite worker/conversation items four and six, not a new feature
program, and none of these account flows is implemented by the relay extraction.

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
