---
id: schema-wiki-page
type: schema
schema_version: 1
status: active
title: Wiki Page
created: 2026-01-01T00:00:00+00:00
updated: 2026-01-01T00:00:00+00:00
---

# Wiki Page

Extends [System/Schemas/Common Metadata](<Common Metadata.md>) with registered types `source_summary`, `concept`, and `synthesis`. Existing entity, project, decision and preference schemas remain canonical.

Use common required metadata: stable `id`, `type`, `schema_version`, `status`, `title`, `created`, `updated`. Add `epistemic_status`, `source_refs`, and `review_after` when relevant. `source_refs` identify a source ID plus checksum/section or original conversation/message/event IDs; filesystem path alone is insufficient.

| Type | Location | Required body |
|---|---|---|
| `source_summary` | `Knowledge/Sources/` | Source identity and locator, key claims with section/page references, limitations, affected pages. |
| `concept` | `Knowledge/Concepts/` | Definition, evidence-backed claims, scope/limits, related pages and source references. |
| `synthesis` | `Knowledge/Syntheses/` | Question, as-of date, conclusion, claim-level evidence, assumptions/contrary evidence, open questions. |

Source ledger states: `pending` = known but unread; `partial` = bounded review with remaining gaps; `ingested` = complete source read and relevant integration verified; `blocked` = identified access/format/privacy obstacle. These are processing states, not truth or confidence scores.

Keep one owner per claim. Source summaries describe what a source says; synthesis describes an interpretation; neither becomes a new independent source. Reuse IDs on updates. Distinguish document publication/event time from observation/ingestion time; omit unknown author and publication dates rather than invent them.
