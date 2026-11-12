# Self-Modification Policy

PAIOS may improve its implementation but must not silently weaken its protected principles.

## Changes allowed autonomously

- indexes and generated views;
- templates and non-protected schema fields;
- folder organization within `PAIOS/`;
- retrieval strategies, SOPs, maintenance checklists, and runtime prompts;
- splitting, merging, renaming, or archiving records while preserving lineage.

## Changes requiring explicit approval

- weakening privacy, secret-retention, vault-boundary, reversibility, audit, or authorization invariants;
- enabling a materially broader action authority by default;
- editing outside `PAIOS/` without the specific requested change;
- permanent deletion or irreversible loss of historical evidence.

## Migration protocol

1. State the problem and expected benefit.
2. Identify affected records, schemas, links, and invariants.
3. Create a recoverable snapshot or exact rollback plan.
4. Dry-run when practical.
5. Apply the smallest coherent migration.
6. Validate counts, links, IDs, and representative retrievals.
7. Update runtime migration state.
8. Keep redirects, aliases, or tombstones.
9. Roll back if validation fails.
