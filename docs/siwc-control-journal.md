# SIWC account command admission journal

`SiwcControlJournal` is a host-only restart fence for explicitly requested account commands. The host must validate the typed command and trusted native sender **before** calling it. It must also capture the same immutable, normalized command in the dispatch closure. This module grants no provider, account, file, network, or browser authority and is never a generic tool endpoint.

```ts
const journal = new SiwcControlJournal(hostStateDir);
const result = await journal.execute(event.id, normalizedCommand, () => coordinator.dispatch(event.id, normalizedCommand));
const latest = journal.lastResult;
journal.close();
```

The root is fixed beneath the supplied trusted host state directory as `siwc-account-controls-v1`; the snapshot is `operations.json`. Production retains the shared Rust sync writer at `lease` and checks the exact original `bridge_pid` before saving and dispatching. Replacement children cannot silently re-authorize an existing in-memory journal. Same-process ownership is also exclusive. Tests inject a fake `retainWriter` or mock the entire Rust dependency; no Rust or native account helper is launched.

## Accepted commands and receipts

Only these normalized scalar command shapes are accepted:

- `{version:1, method:'sign-in', bindingId, returning:boolean}`
- `{version:1, method:'cancel', attemptId}`
- `{version:1, method:'verify-pending'|'select'|'sign-out', bindingId}`
- `{version:1, method:'status'}`

The host supplies missing sign-in fields before admission; it does not infer credential identity. Operation/binding IDs are bounded local opaque identifiers, and attempt IDs are 64 lowercase hex characters. Unknown fields, accessors, symbols, credentials, URLs, raw paths, and custom transport/client authority fields are refused before admission. The journal stores a canonical command digest rather than the command or its binding. Operation keys are SHA-256 digests of operation IDs.

Receipts contain only `operationId`, `status:'pending'|'completed'|'rejected'|'unknown'`, optional opaque `attemptId`, and optional shared reason code: `unsupported|invalid|identity|permission|conflict|unknown|signed-out|local-sign-in-required|busy`. Arbitrary dispatch descriptions are discarded. A thrown dispatch, wrong operation ID, or malformed receipt becomes a consumed unknown. Receipt copies and `lastResult` cannot mutate journal state. Read-only status may bypass this journal in the host, avoiding needless operation consumption.

## Admission, restart and uncertainty

Before dispatch, an unknown receipt is written durably. Writes use a new exclusive 0600 file, file fsync, atomic rename, and parent-directory fsync. Existing root/file ownership, private modes, symlinks, file type, and hard links are checked. Pending sign-in is recorded once and remains pending in its live owner. The journal does not update it when an asynchronous sign-in later settles; the live account coordinator may publish a newer result separately.

An exact repeated operation returns its recorded safe receipt without dispatch. A changed command under the same operation ID is rejected as conflict without changing the original evidence. Reconstruction turns pending receipts into unknown and removes obsolete in-memory attempt IDs. Unknown admissions, including a crash gap between admission and dispatch, are never replayed. A new explicit operation can be independently admitted; this journal does not invent automatic recovery or token retries.

A save or writer-ownership uncertainty fences further mutations for that owner and returns unknown. No completion is claimed without a durable receipt. Deduplication evidence is never evicted: 2048 operations, a 2 MiB snapshot/read bound, and 32 queued submissions fail before dispatch. Invalid, over-budget, mismatched, closed, and other unadmitted rejections are not new durable operations. `lastResult` reflects the latest in-memory safe observation; after reconstruction it reflects the latest durable admission/result.

`close()` synchronously prevents new admissions. If dispatch is in flight, writer ownership stays retained until it settles and its safe receipt is saved or becomes unknown; queued unadmitted commands are refused. The host should then close its account coordinator so bounded dispatch can settle. An indefinitely stalled dispatch deliberately keeps ownership instead of admitting another writer.

The tests use synthetic IDs, fake dispatch, temporary journal files, fake writer retention, and mocked writer identity probes. They establish source behavior for admission, deduplication, restart, uncertainty, limits, validation, and cleanup. They provide no evidence of actual OAuth, Keychain protection, native locks, provider access, account eligibility, or distributed execution cessation. Native/live readiness remains false until separately authorized verification.
