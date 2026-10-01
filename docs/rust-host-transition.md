# Portable Rust host transition

The product direction is a Swift/SwiftUI native interface with an independent Rust host core.
The core must be usable on Linux and Windows without depending on Swift. The default experience
should eventually be one continuous conversation, while retaining an explicit way to create
separate conversations. These are migration requirements, not claims about the current release.

## Current boundaries

- `apps/mac` and `apps/ios` provide Swift/SwiftUI interfaces. The shared Swift `ChatModel` and
  `ThreadCache` own encrypted client drafts, attachments, saved-draft recovery and pending sends.
- The Mac launches the bundled Node executable and `packages/runtime/dist/serve.js`. The
  TypeScript host currently owns relay/local/channel transport, admission, sequencing, approvals,
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
thread/admission state, approval currency, agent execution and channel outboxes remain TypeScript
until their individual compatibility and recovery tests pass. The existing native UI slices are
preserved, including separate conversations. Actual schedules, PAIOS ownership and the future
continuous-conversation task store remain unimplemented.

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

No speed claim follows from the language choice. Measure cold launch, request latency, streaming
under large history/attachments, memory and recovery time on comparable builds. Maintain bounded
queues and measure fsync cost. Reliability must be demonstrated with crash, duplicate, concurrent,
timeout, disconnected and upgraded/rolled-back workflows.

The requested 0.6.0 alpha must not enter the existing 0.5.0 beta update path. The published
0.5.0 Mac updater follows `/beta/appcast.xml` and permits the beta channel; the live redirect still
points to `v0.5.0-beta`. The canonical main release path would replace that beta. Release-branch
candidate titles are excluded by the existing website's beta discovery. Merely setting GitHub's
prerelease flag is insufficient.

The canonical iOS workflow currently adds every candidate to the existing Public TestFlight
group. An isolated alpha destination and its effect on existing external/internal testers must be
verified before uploading or publishing. No release has been dispatched, and no version or tag
has been overwritten. Gateway authorization remains pending; no gateway connection or credential
issuance/rotation is part of this migration.
