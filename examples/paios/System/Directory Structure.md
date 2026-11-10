# Directory Structure

```text
PAIOS/
├── README.md
├── System/
│   ├── Constitution.md
│   ├── Architecture.md
│   ├── Directory Structure.md
│   ├── Runtime Manual.md
│   ├── Mission Control.md
│   ├── Security & Privacy.md
│   ├── Change Log.md
│   ├── Shared assumptions.md
│   ├── Prompts/
│   ├── Policies/
│   ├── Workflows/
│   ├── SOPs/
│   ├── Schemas/
│   ├── Templates/
│   └── Scripts/
├── Runtime/
├── Knowledge/
├── World/
├── Projects/
├── Workspace/
├── Execution/
├── Sessions/
├── Learning/
├── History/
├── Reports/
├── Indexes/
├── Archive/
├── Attachments/
└── Handover/
```

## Placement rules

| Information | Canonical location | Notes |
|---|---|---|
| Stable principles | `System/Constitution.md` | Protected; explicit approval to weaken |
| Operating design | `System/` | Versioned and evolvable |
| Live runtime bookkeeping | `Runtime/` | Small, current, and machine-readable |
| Current facts and beliefs | `Knowledge/` | Evidence-backed |
| External people, organizations, places, products | `World/` or linked entity records | Anything may become first-class |
| Active initiatives | `Projects/` | May be created, merged, split, or archived |
| Incomplete analysis | `Workspace/` | Not treated as truth |
| Queued and completed actions | `Execution/` | Queue does not imply authority |
| Conversation journals | `Sessions/` | Normalized imports under `Imported/` |
| Learning process | `Learning/` | Corrections and prediction outcomes |
| Append-oriented event history | `History/` | Preserve past state |
| Periodic summaries | `Reports/` | Derived but reviewable |
| Generated lookup aids | `Indexes/` | Rebuildable |
| Retired material | `Archive/` | No permanent deletion |
| Non-secret binary artifacts | `Attachments/` | Use stable references and hashes |
| Work passed between agents | `Handover/` | One file per handoff; see `Handover/README.md` |
| Helper scripts | `System/Scripts/` | Paths come from environment variables, never hardcoded |

## Naming conventions

- Use human-readable filenames for browsing and stable `id` fields for identity.
- Prefer `Title.md`; avoid embedding transient statuses in filenames.
- Imported normalized files use `<source>-<conversation-id>.jsonl` with unsafe characters normalized.
- Daily reports use `YYYY-MM-DD.md`; weekly reports use `YYYY-Www.md`; monthly reports use `YYYY-MM.md`.
- Never encode secrets or exact private addresses in filenames, paths, or aliases.
- Merged records keep aliases and a tombstone pointing to the surviving ID.

## Growth rules

Folders are organizational views, not the domain model. New folders may be introduced through a logged migration when they improve retrieval. Large notes should be split by a meaningful stable seam; tiny duplicate notes should be merged while retaining provenance and aliases.
