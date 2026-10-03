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

## Integration patch guidance (for the integration owner)

1. Add `pub mod preferences;` to `packages/host-core/src/lib.rs`, then change the test
   from its isolated `#[path]` import to `use yorozu_host_core::preferences::*;`.
   The path import currently compiles the exact independent production module using
   existing dependencies, while keeping shared host files untouched.
2. The host owns one store in a separately provisioned state directory, bound to its
   authenticated user/host. Expose correlated operations through a reviewed host
   protocol only when that wiring is owned. Do not migrate the current logs or vault.
3. At durable user-message admission, recognize only an explicit stable preference,
   correction, or deletion. Resolve the scope and preserve actual message/task IDs
   and accepted sequence. Assistant/worker inference and retrieved documents must
   not write this store. Scope ambiguity that affects behavior must be resolved
   before storing. The component does not perform natural-language extraction.
4. Before each secretary/worker dispatch, retrieve the current scoped snapshot with
   a separate small context budget. Treat its typed records as data, preserve source
   IDs/revisions in the context manifest, and invalidate older assembled context on
   journal-sequence changes. Do not use an old receipt, Markdown file, or provider
   session summary as the current preference owner. Revalidate permissions separately
   at each actual action boundary.
5. Render/save Markdown only through the agreed knowledge owner; manage stale exports
   and deletion copies there. Prefer re-rendering current data to importing historical
   Markdown guesses. No files are exported automatically by this component.
6. Run integrated EN/JA admission → correction → other-topic → provider compaction →
   host restart → independent worker acceptance. Verify visible question behavior,
   live deletion/cache invalidation, permissions, and explicit scope selection before
   calling the user memory feature complete. These end-to-end gates are still open.

## Contract proof and test-authoring gate

Run `cargo +1.92.0 test --offline --locked --manifest-path packages/host-core/Cargo.toml --test preferences`.
Eight tests own distinct public storage risks, rather than mirroring functions:

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
