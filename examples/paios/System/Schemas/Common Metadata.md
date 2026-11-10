# Common Metadata Schema

All durable Markdown records should use YAML front matter. Omit genuinely inapplicable optional fields; do not fill them with invented values.

```yaml
id: entity-01J...
type: entity
schema_version: 1
status: active
title: Example
created: 2026-07-31T12:00:00+00:00
updated: 2026-07-31T12:00:00+00:00
valid_from: 2026-07-31
valid_to:
aliases: []
tags: []
related_ids: []
source_refs: []
confidence: 1.0
epistemic_status: explicit
review_after:
supersedes:
superseded_by:
```

## Required fields

- `id`: stable, unique, never recycled.
- `type`: one registered record type.
- `schema_version`: integer schema version for migration.
- `status`: type-appropriate lifecycle state.
- `title`: human-readable label.
- `created`, `updated`: ISO 8601 with offset when a time is known.

## Controlled values

`epistemic_status`: `explicit`, `user_report`, `observed`, `third_party`, `inferred`, `generated_view`.

Common `status`: `active`, `current`, `superseded`, `disputed`, `stale`, `retracted`, `archived`, `merged`.

## Source references

Use durable locators:

```yaml
source_refs:
  - source: codex
    conversation_id: abc123
    message_id: msg456
    event_id: event-...
    observed_at: 2026-07-30T10:00:00+00:00
```

Never make a filesystem path the only evidence locator. Never include a secret in metadata.
