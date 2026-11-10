# Projects

```dataview
TABLE objective, status, priority, target_date, next_review
FROM "PAIOS/Projects"
WHERE type = "project"
SORT choice(status = "active", 0, 1) ASC, priority ASC, file.name ASC
```

Projects are first-class evolving entities for multi-session objectives. PAIOS may create, merge, split, archive, and retire them autonomously inside its boundary. Preserve lineage and write a retrospective when a meaningful project closes.

The query above needs the Obsidian Dataview plugin; without it, browse the folder directly.
