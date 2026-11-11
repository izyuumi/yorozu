# Timeline Event Schema

```yaml
id: event-01J...
type: timeline_event
schema_version: 1
status: recorded
title: Example state change
event_type: preference_changed
subject_ids: [user]
occurred_at: 2026-01-01T12:00:00+00:00
recorded_at: 2026-01-01T12:00:00+00:00
before_ref:
after_ref:
confidence: 1.0
epistemic_status: explicit
source_refs: []
created: 2026-01-01T12:00:00+00:00
updated: 2026-01-01T12:00:00+00:00
```

Timeline events preserve what changed, when it was true, when PAIOS learned it, and the evidence. If occurrence time is unknown, keep it unknown rather than substituting import time.
