# Relationship Schema

Use a dedicated relationship record when a link has its own evidence, confidence, role, or time range.

```yaml
id: relationship-01J...
type: relationship
schema_version: 1
status: current
from_id: entity-...
relationship_type: works_with
to_id: entity-...
valid_from:
valid_to:
confidence: 0.9
epistemic_status: user_report
source_refs: []
created: 2026-01-01T12:00:00+00:00
updated: 2026-01-01T12:00:00+00:00
```

Use directional names that read clearly from `from_id` to `to_id`. Preserve previous relationships as superseded or ended rather than deleting them.
