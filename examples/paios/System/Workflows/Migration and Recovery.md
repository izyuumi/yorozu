# Migration and Recovery

## Migration record

Every migration records:

- migration ID and state transition; include a version transition only for historical or explicitly versioned migrations;
- problem and expected benefit;
- affected paths, record types, and stable IDs;
- protected-invariant assessment;
- preflight counts and checks;
- backup/snapshot or exact reconstruction method;
- ordered operations;
- validation queries and expected results;
- rollback steps;
- result, warnings, and operator/runtime.

## Execution

1. Prevent overlapping migrations.
2. Snapshot or prepare rollback.
3. Dry-run transformations when practical.
4. Apply idempotently in bounded batches.
5. Validate record counts, IDs, links, aliases, indexes, and representative retrievals.
6. On failure, stop and roll back; do not continue into dependent steps.
7. Update `Runtime/Migrations.md` and `System/Change Log.md`.

## Crash recovery for actions

- Before commit: safe to resume preparation after revalidation.
- Commit response known: verify and reconcile.
- Commit response uncertain: inspect external state before any retry.
- Duplicate possible: prefer idempotency keys or external confirmation records.

## Data recovery

Archive is not backup. Maintain vault backups outside PAIOS according to the user's environment. PAIOS records recovery assumptions but never stores backup credentials.
