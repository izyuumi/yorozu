# Execution Item Schema

```yaml
id: task-01J...
type: execution_item
schema_version: 1
status: captured
title: Example action
objective: ""
project_ids: []
priority: medium
value: 3
urgency: 3
effort: 2
risk: 2
alignment: 3
agent_completable: unknown
authorization_required: unknown
authorization_id:
dependencies: []
blocked_by: []
deadline:
follow_up_at:
created: 2026-01-01T12:00:00+00:00
updated: 2026-01-01T12:00:00+00:00
```

## Lifecycle

`captured → clarified → authorized → prepared → commit-ready → committed → verified → reconciled`

Alternative states: `blocked`, `waiting`, `failed`, `cancelled`, `rolled_back`, `verification_required`, `archived`.

Body sections: success criteria, material parameters, dependencies, authority analysis, preparation, verification evidence, result, and follow-up. Ranking fields never grant authority.
