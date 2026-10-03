# Explicit preference journal: isolated 0.6 component

Status: independently testable component, based on released source
`9681ecfb105ae46017a1d930f72803d6d806194b`. **Not integrated, installed, or released.**
The integration/install owner retains those responsibilities. This slice adds only
`packages/host-core/src/preferences.rs`, its test, and this document; no coordinator,
crate export, dependency, lockfile, legacy storage, or vault changes.

## Ownership and persistence

`Preferences::open(root: &Path, owner: &Owner) -> Result<Preferences, Error>` opens an
explicit absolute NEW dedicated private directory, such as `<synthetic-state>/preferences-v1`.
The parent must already exist and be trusted. Never pass a vault or existing legacy
state root. There is no path discovery or history import. On Unix the component
creates a 0700 directory and 0600 files; existing public directories and final-path
symlinks are refused. Windows ACL provisioning remains the host's responsibility.

The directory contains `preferences.sqlite` and `.preferences-owner.lock`. One
OS-held writer lock lasts until the store is dropped. The SQLite application ID,
schema version 1, and immutable user/host owner must match on reopen. Unknown stores
are refused without schema migration. Owner IDs partition data; they do not
authenticate the caller. Use already authenticated user/host identities at admission.

Existing `rusqlite`, `serde`, `serde_json`, `sha2`, and Unix `libc` dependencies suffice.
SQLite DELETE journaling, EXTRA synchronous commits, and `fullfsync=ON` own
transaction durability; the newly created database and containing directory are
synced before use. These settings follow SQLite's
[synchronous](https://www.sqlite.org/pragma.html#pragma_synchronous) and
[fullfsync](https://www.sqlite.org/pragma.html#pragma_fullfsync) contracts. Hardware
power-loss testing was not performed.
`latest` is a SQL view over the same event table, so no separate projection cache can
retain an obsolete value. Provider context compaction cannot alter this store.
The ordinary-change ceiling is 4,096 events. After that ceiling, a delete of an
active key still has one reserved tombstone; new keys, repeated tombstones, and
restorations are refused. Because there can be at most 4,096 active keys and no new
ones after the ceiling, the journal remains bounded at 8,192 events. The database
ceiling is 16,384 SQLite pages (approximately 64 MiB with the default 4 KiB page size).
Actual disk/I/O failures still return an error without acknowledging deletion.
There is no automatic pruning, compaction, migration, or eviction.

## Exact component API

| API | Contract |
| --- | --- |
| `apply(&mut self, change: &Change) -> Result<Receipt, Error>` | Atomic admitted user change. Returns the durable record and whether an identical event was replayed. |
| `latest(&self, scope: &Scope, key: Key) -> Result<Option<Record>, Error>` | Latest exact-scope revision, including deletion tombstones. |
| `history(&self, scope: &Scope, key: Key, limit: usize) -> Result<Vec<Record>, Error>` | Newest-first exact-scope audit records, limit 1–100. |
| `retrieve(&self, context: &Context, budget: Budget) -> Result<Retrieval, Error>` | Applicable active values, whole-record omission counts, byte count, and journal invalidation sequence. |
| `Retrieval::markdown(&self) -> String` | Readable derived snapshot with scope, revision, source message, and observation time. Does not write a file. |

`Owner` carries `user_id` and `host_id`. `Scope` is `Global`, `Project(id)`, or
`Task(id)`. Task/project IDs must be unique within this owning user/host namespace,
including across projects. `Source` requires an originating user `message_id`, optional `task_id`,
positive authoritative `accepted_sequence`, and `observed_at_ms`. IDs are bounded
ASCII identifiers (1–128 bytes, letters/digits/`-_.:`); host integrations may map
their existing IDs to this namespace. Sequences/times fit JSON's safe integer range.

`Change` includes a stable `event_id`, exact scope/key, `expected_revision`, source,
and action. New declarations use expected revision 0. Each committed change gets
a global journal sequence, per-scope/key revision, and `supersedes` pointing at the
previous event's journal sequence. Accepted user-message order decides freshness;
wall-clock time and unrelated task completion order cannot override a correction.

The only typed values in this slice are `ReplyBulletCount(1..=12)`,
`ReplyLanguage(English|Japanese)`, and
`ClarificationStyle(NecessaryOnly|OfferChoices)`. These are presentation data.
There are no permissions, executable instructions, arbitrary strings, tool actions,
or authorization updates. Necessary approval and clarification questions still apply.

## Corrections, deletion, and retrieval

- `Set(value)` declares an absent preference or explicitly restores a tombstone.
  It cannot overwrite an active value; use `Correct` with the current revision.
- `Correct(value)` requires an active value, matching expected revision, and a
  strictly newer accepted user-message sequence for that exact scope/key. A stale
  revision/source fails; the caller must resolve against the current admitted request,
  never automatically retry a stale correction as a new request.
- `Delete` writes a tombstone even for a previously absent exact-scope key. In the
  same transaction, prior values for that scope/key are redacted from audit records.
  A scoped tombstone masks inherited values, so a task deletion cannot silently
  resurrect the global preference. Resetting an override to inherit is separate
  future behavior. Restoration requires an explicit newer `Set` naming the tombstone
  revision.
- Reusing an active event ID with an identical change is idempotent. Conflicting
  payloads fail. Deleted/redacted events retain no value-dependent fingerprint;
  replays compare scope, key, expected revision, source, and action kind only and
  return the same redacted receipt for any valid value. This deliberately cannot
  distinguish forgotten values. An old replay returns its original audit receipt;
  it does not become current. Consumers must retrieve current state for context.
- Retrieval resolves task > project > global, newest event first within each scope.
  Only the requested project/task and global values are eligible. A newer global
  setting does not erase an explicit scoped setting. Optional context IDs are passed
  by the owning host after access checks; they are not inferred by this component.
- Budgets accept 0–32 records and 2–32,768 bytes. The byte limit applies to compact
  JSON of the records array, including delimiters. Metadata and Markdown are outside
  that limit. Records never truncate; an omitted scoped override never falls back to
  an older/global value. `omitted` must be handled by the host before dispatch if a
  necessary preference cannot fit. `StateConflict` distinguishes an invalid lifecycle
  action from malformed input; `RevisionConflict` supplies the current revision.
  The current allowlist permits at most three
  effective records. `journal_sequence` invalidates cached snapshots after any change.

Deletion is logical redaction in this store, with SQLite `secure_delete=ON`.
Provenance IDs, revisions, and tombstones remain; hashes of redacted changes are
removed. This is **not** a
promise of forensic erasure: unlinked pre-deletion SQLite rollback journals, external
backups, previous Markdown exports, provider
contexts, host caches, filesystem snapshots, and other copies require a retention
and invalidation policy at integration. The database is not encrypted here.

## Secretary integration

The feature branch now exports the public Rust module and adds a separate, bounded
host endpoint. It changes no existing conversation, admission, task or vault data
format, installs nothing, and leaves the production release branch untouched.

`yorozu-alpha-host --preferences ABSOLUTE_ROOT USER_ID HOST_ID` accepts exactly one
JSON request on stdin (at most 8,192 bytes), then exits. Its operations are:

- `{"op":"apply","change":Change}` → `Receipt`.
- `{"op":"latest","scope":Scope,"key":Key}` → `Record | null`.
- `{"op":"receipt","eventId":"id"}` → `Record | null` for authenticated retry.
- `{"op":"retrieve","context":{"taskId":"optional-id","projectId":"optional-id"},"budget":{"maxRecords":3,"maxBytes":4096}}`
  → `{snapshot: Retrieval, markdown: string}`.

Responses are `{version:1, ok:true, value:...}` or
`{version:1, ok:false, error:...}`. Invalid framing/owner/schema exits unsuccessfully.
This endpoint trusts its private local host caller; it is not a public network API.
Worker packet dispatch cannot reach these operations. Existing sandbox/account/OS
controls remain the authorization boundary for tools and access to host state.

`secretary-preferences.ts` exposes `parsePreference(text)` and
`secretaryPreferences(dir, owner).accept(source, tasks)` / `.context(taskId?)`.
Only the production host supplies the source: a persisted parentless main-thread
user message must match its existing accepted-message identity map. The hook waits
for synchronous admission to finish, then takes its ordinal and timestamp from the
first physical user admission, before display-order corrections. Model/tool output,
attachments, task instruction derivatives, quoted documents and provider summaries
are never passed to the parser. No historical preference import is performed.

The private store is `<stateDir>/preferences-v1`, with a stable profile signing
public key as host identity and `local-profile-owner` as the single local user's
identity. Paired devices share that profile owner. A foreign profile fails closed.
The coordinator confirms successful writes after the separate Rust process exits;
no model decides whether persistence succeeded. A duplicate/redacted receipt
reconstructs the original revision/operation without resurrecting deleted values.
Delayed changes retain their original admission sequence and are refused.

Before every main planning turn and newly dispatched specialist, Rust retrieves
three records within 4,096 bytes. An allowlisted renderer turns each typed value
into a fixed presentation directive alongside its evidence; arbitrary text is never
rendered as a preference instruction. Fresh records carry evidence, revisions and a
journal sequence; the context expressly invalidates old remembered values for the
three absent keys. Task tombstones mask global inheritance. Required approvals and
permission decisions remain independent. No projection cache or Markdown export is
used as an owner. `Show my saved presentation preferences` and
`保存済みの返信設定を表示して` return a current readable Markdown view without
writing knowledge files or accessing a vault.

The anchored EN/JA grammar deliberately supports only three presentation keys.
Examples accepted as complete messages:

- `From now on reply with three bullets` → `Actually use two bullets` →
  `Forget my bullet count preference`.
- `今後は箇条書き3つにして` → `訂正、箇条書き2つにして` →
  `箇条書き数の設定を忘れて`.
- `Always reply in Japanese`, `今後は英語で返答して`.
- `From now on ask clarification questions only when necessary`,
  `今後は確認質問では選択肢を提示して`.
- Prefix `For task "Exact existing title", ` or `タスク「既存の名前」では、`
  to select exactly one existing task; unknown/ambiguous titles are not stored.

A correction requires an active saved key. A fresh explicit declaration can restore
one after deletion. Other phrasing remains normal conversation: it is not silently
persisted or represented as comprehensive natural-language memory support.

## Integration patch guidance and remaining limits

Apply this branch's commits atop released source `9681ecfb`, then run
`scripts/stage-internal-alpha.py` on the clean committed source. The staging overlay
now includes `secretary-preferences.ts`; the pinned production patch supplies only
the owner/source callbacks alongside the existing coordinator hooks. Do not replace
the production host with the development `serve.ts` or port paused recovery work.
The Rust binary and runtime must ship together; an old host cannot service the new
endpoint. This work does not merge, install or publish that build.

Project scope is tested and available through Rust retrieval, but the continuing
secretary currently has no stable project association, so ordinary-language project
selection is unsupported. Existing named task preferences affect future retrieval;
a running specialist is not automatically interrupted or steered when one changes.
Preference-only acknowledgements use fixed EN/JA copy and factual dispatch receipts
remain host-owned. Provider compaction is covered by discarding the main session and
starting independent specialists; no live provider compaction RPC is claimed.

The original host user admission log must retain first-admission order. A future
physical log compactor needs an immutable admission sequence before deleting that
log; this feature introduces no such migration. Provider/session compaction alone
does not alter it. Recognition runs when the queued secretary turn begins, not at
initial transport receipt, and follows existing shutdown/held-turn semantics.
Deletion clears the learned store and future projections, not original conversation
messages, prior provider contexts, task snapshots or external exports. The component
is unencrypted and has the documented bounded event ceiling. Broader user memory,
unrestricted phrasing, question-behavior evaluation and installed native acceptance
remain separate work; do not label the whole user-memory feature complete.

## Contract proof and test-authoring gate

Run `cargo +1.92.0 test --offline --locked --manifest-path packages/host-core/Cargo.toml --test preferences`.
Eight Rust tests own distinct public storage risks, rather than mirroring functions:

| Test | Observable regression caught |
| --- | --- |
| EN/JA fresh-process restart | A corrected 3→2 preference disappears with provider history/summary or a process restart; unrelated topic data leaks into a new worker's context. |
| Revision/order/idempotency | A delayed user change or duplicate event reverses an acknowledged correction; conflicting IDs silently overwrite it. |
| Scope/deletion/restoration | An unrelated task preference leaks; deletion falls back to a global value; a correction implicitly restores forgotten data. |
| Deletion history/restart | Superseded values remain retrievable/guessable through hashes or replay after deletion; redaction erases another scope or loses attribution. |
| Retrieval budget/token | Context exceeds its independent byte/record budget, silently truncates, or lacks cache invalidation after a change. |
| Trust boundary/owner | Free-form authority enters typed preference data, invalid values are committed, or a foreign owner/store is accepted or rewritten. |
| Writer/rollback | Two writers acquire ownership; a failed delete redacts acknowledged data before its tombstone commits. |
| Full journal deletion | The 4,096-event ceiling blocks deletion, or unbounded tombstones/restore operations consume reserved headroom. This test uses real acknowledged API writes. |

Existing host tests cover conversation/operational stores, not this preference owner.
The restart test launches the same test executable as a fresh process; no provider,
native UI, real profile, private history, or vault is accessed. SQLite itself injects
the rollback test's insert failure via a synthetic trigger. No production injection
hook, file-open interposition, FIFO, recovery experiment, or dependency change is used.

Two additional runtime tests own parser provenance and real Rust protocol risks.
The existing production socket/official-adapter suite adds EN/JA scenarios for queued
3→2 correction, exact original admission order, unrelated-topic continuation, host
restart with the provider session removed, new specialist snapshots, injected website
and worker output, and deletion invalidation. All fixtures use disposable profiles
and synthetic content; they do not modify installed applications or private history.

Live disposable acceptance also passed for EN and JA: acknowledged 3→2, an
unrelated banana question, host close/reopen with the main provider session removed,
and an actual independent specialist listing four fruits. Both the ordinary reply
and each specialist result used exactly two bullets. Every observed `turn/start`
carried `serviceTierForTurn: "default"` (standard speed), the current revision 2, and
the original correction message ID. The harness used the installed CLI's supported
default model, synthetic statements, no tools, and separate temporary state, project
and provider directories. All temporary profiles and copied authentication were
deleted. This is backend acceptance; no native UI, installed profile, release or
vault was accessed. Language and clarification settings have typed storage/parser/
retrieval coverage; broad model question behavior is not claimed tested.
