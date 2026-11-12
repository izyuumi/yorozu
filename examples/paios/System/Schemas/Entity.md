# Entity Schema

An entity is a stable object in the user's world: person, organization, place, product, device, repository, book, restaurant, account metadata, concept, or other referent.

```yaml
id: entity-01J...
type: entity
schema_version: 1
status: active
title: Example Entity
entity_kind: person
aliases: []
current_summary: ""
source_refs: []
created: 2026-01-01T12:00:00+00:00
updated: 2026-01-01T12:00:00+00:00
```

## Body sections

- `## Current state` — compact present-tense claims with evidence links.
- `## Relationships` — typed links to related IDs.
- `## Timeline` — link to history rather than duplicating every event.
- `## Open questions` — unresolved identity or state issues.
- `## Provenance` — source coverage and major evidence.

Entity records must not store precise private addresses, secret values, or unsupported mental-model traits as objective facts.
