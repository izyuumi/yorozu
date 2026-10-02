# Isolated native alpha IPC v1

Integration owner: `packages/host-core/src/alpha.rs`, `src/bin/yorozu-alpha-host.rs`,
`packages/runtime/src/alpha-worker.ts`, this contract. UI owns `YorozuAlpha` Swift target
and its composer; QA owns `scripts/alpha-*` and QA documentation/evidence.

Launch: `yorozu-alpha-host PROFILE_ROOT NODE_EXECUTABLE ABSOLUTE_ALPHA_WORKER_JS`.
PROFILE_ROOT must be beneath the OS temporary directory (also `/tmp` on Mac), explicitly
selected. New profile contains `state/` and `workspace/`; existing profiles need the
host-created `.yorozu-alpha-v1` marker. No installed profile, migration, pairing or updater.
Node worker uses existing `codexNativeRunner` official installed app-server configuration.
This is a temporary Node provider bridge, not a complete Rust migration.
The installed official client advertised `gpt-6-astra` as default but returned the exact
unsupported-ChatGPT-model failure on a harmless turn. The internal alpha explicitly uses
advertised `gpt-6-sol` (`YOROZU_ALPHA_MODEL` can choose another advertised model); it never
changes official client configuration or credentials. Catalog presence is checked before
invocation and does not itself prove successful inference. Model support is verified by
real QA results, and there is no automatic retry through other models.

Private child pipes use UTF-8 JSON lines, maximum 1 MiB per frame, protocol version 1.
Requests have `version:1`, `id` (UUID), `op`:
- `snapshot`: replay retained state; never starts/retries provider work.
- `submit`: additionally `runId` (UUID stable across same-message retry), `text` (1..16000
  UTF-8 bytes). One active worker; busy submission gets an error and remains unaccepted.
- `stop`: additionally `runId`. A durable request precedes cancellation; acknowledgement
  of request is not evidence of cessation.

Responses: `{version:1,id,result:{...}}`. Errors use `result.error` fixed code.
Snapshot result: `{profileRoot,workspace,events:[EVENT],activeRunId:STRING_OR_NULL}`.
Submit result: `{accepted:true,runId,replayed:BOOLEAN}` only after durable acceptance;
changed text for same runId is `conflicting-run`. Stop result: `{requested:true,runId}`
only after durable Stop intent; terminal/unknown returns `{requested:false,runId}`.

Events: `{version:1,event:{seq:INTEGER,runId,kind,text?,data?,ts:UNIX_MS}}`.
Snapshot `events` contains projected inner event objects, in seq order. Deduplicate by seq.
All user/final/control states are retained; snapshots keep only the latest partial update
for an active run and the latest two provider activities per run. Full ledger stays on disk.
Profiles accept at most 12 tasks (`profile-task-limit`); choose a fresh temporary profile
when full. Provider detail is bounded/truncated, and partial updates are throttled.
Kinds: `accepted` (original user text); `running` (provider invocation begun, not completion);
`update` (replace partial assistant text); `activity` (provider's existing typed payload in
`data`); `stop_requested`; `completed` (final text, real provider completed);
`stopped` (provider terminal or observed child exit, evidence in data);
`failed` (confirmed terminal provider failure); `unconfirmed` (connection/host failure,
completion/cessation unknown). `completed/stopped/failed/unconfirmed` are final UI states.
No percent estimates. Local sending/connecting is distinct from host acceptance/running.

Reconnect sends snapshot and reconciles retained seq/runId. UI keeps the same runId if an
acceptance response was lost. Restart never automatically re-executes accepted work;
unresolved retained runs become `unconfirmed`. Active requests cannot be replaced.
Safe demo: ask English/Japanese for a small text file and checksum in displayed temporary
workspace. No real accounts, email, purchases, private documents, or computer-use actions.
Permission requests needing escalation are declined by this initial bridge; show activity
and failure, never claim approval. No blanket TCC grants.
