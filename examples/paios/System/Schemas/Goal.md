# Goal Schema

```yaml
id: goal-01J...
type: goal
schema_version: 1
status: active
title: Example goal
owner_id: user
goal_class: explicit
horizon: long_term
priority: high
confidence: 1.0
success_criteria: []
project_ids: []
source_refs: []
created: 2026-07-31T12:00:00+00:00
updated: 2026-07-31T12:00:00+00:00
review_after: 2026-10-31
```

`goal_class` is `explicit`, `inferred`, or `agent_objective`. Inferred goals require evidence and never override explicit goals. Agent objectives remain subordinate to user intent and the Constitution.

Body sections: motivation, success criteria, constraints, progress signals, conflicts, and review history.
