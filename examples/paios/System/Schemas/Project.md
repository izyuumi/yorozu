# Project Schema

```yaml
id: project-01J...
type: project
schema_version: 1
status: active
title: Example Project
objective: ""
owner_ids: [user]
parent_project_id:
related_project_ids: []
goal_ids: []
priority: medium
start_date:
target_date:
next_review:
source_refs: []
created: 2026-07-31T12:00:00+00:00
updated: 2026-07-31T12:00:00+00:00
```

## Body sections

- `## Objective and success criteria`
- `## Current state`
- `## Scope and non-goals`
- `## Milestones and critical path`
- `## Dependencies and blockers`
- `## People and entities`
- `## Decisions`
- `## Execution queue`
- `## Risks and assumptions`
- `## Documents and sessions`
- `## Retrospective`

Projects may be created, merged, split, archived, and retired autonomously inside PAIOS. Preserve `merged_into`, `split_into`, or `derived_from` lineage.
