# Conversation Ingestion

## Discover and register

For each conversation source (chat assistant, coding agent, or other runtime), record format, read-only path, schema mapping, time zone, known coverage, and last cursor in `Runtime/Source Registry.md`.

## Normalize

Use your importer of choice (this example ships none; see `README.md`). Normalized output is source-neutral JSONL. Redaction occurs before output. Do not store raw database rows in PAIOS.

Malformed records and invalid timestamps are recorded in metadata-only quarantine JSONL. Do not copy a failed raw row into the quarantine report.

## Deduplicate

Prefer stable source conversation/message IDs. Fall back to a hash of normalized source, conversation, role, timestamp, and content. Treat mirrored exports as correlated evidence.

## Extract

Extract candidate facts, preferences, decisions, corrections, projects, action events, and authorization observations. Keep candidates linked to exact evidence and extraction version. The bootstrap importer emits conservative phrase-based preference, correction, and authorization observations as `observed`, low-confidence records for later assimilation.

## Assimilate

- resolve entity aliases;
- update current state and timelines;
- preserve contradictions;
- score evidence;
- keep imported authorization patterns proposed/observed;
- update bootstrap or incremental reports.

## Validate

Sample earliest, latest, long, short, multi-modal, failed-parse, redacted, and action-containing sessions from every source. Trace derived claims back to evidence.

## Incremental runs

Use recorded cursors and checksums. Re-reading the same data must not duplicate normalized events, inflate confidence, or reactivate retired knowledge.
