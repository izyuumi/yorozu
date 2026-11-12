---
id: paios-architecture
type: architecture
status: active
version: 0.1.0
---

# PAIOS Architecture

## 1. System boundaries

PAIOS is a filesystem-backed personal cognitive operating system. A plain folder of Markdown files supplies durable storage and links; an agent runtime supplies reasoning and tool execution. The folder is not assumed to be a database, and the runtime is not assumed to be permanent.

The strict write boundary is `PAIOS/`. All imported databases and logs are mounted or referenced read-only. Derived files are written only inside PAIOS unless the user explicitly requests an outside edit.

## 2. Cognitive spaces

PAIOS separates five kinds of state:

1. **History** — what occurred, including raw normalized conversations and action records.
2. **Knowledge** — what is believed to be true, with provenance and temporal state.
3. **Workspace** — unfinished reasoning artifacts, research, drafts, plans, and investigations.
4. **Execution** — what may or should happen next and what happened as a result.
5. **Learning** — why the user and agent models changed and whether those changes predicted outcomes.

Mixing these creates common failure modes: treating a plan as fact, an assistant suggestion as a user preference, an old approval as present authority, or an index as source data.

## 3. Layer model

### 3.1 Working memory

Ephemeral runtime context for the immediate turn. It may be lost. Any meaningful state required for crash recovery is written to the session journal.

### 3.2 Session journal

Continuously updated conversation state: requests, commitments, decisions, corrections, entities, action status, open loops, and links. It supports recovery after interruption.

### 3.3 Long-term knowledge

Consolidated entities, current state, preferences, decisions, mental models, projects, timelines, and evidence. Promotion happens at milestones or session close, not by blindly copying every utterance.

### 3.4 Raw imported history

Normalized, redacted, immutable conversation records with source locators and checksums. This is evidence, not automatically trusted truth.

## 4. Stable identity and graph model

Important objects receive stable IDs such as `person-01J...`, `project-01J...`, or deterministic imported-message IDs. Notes expose IDs in YAML front matter. Relationships may be represented in entity fields and dedicated relationship records when they have their own provenance, confidence, or time range.

Merges retain the losing IDs as aliases. Splits retain `derived_from`. Renames do not change IDs. File paths are views and may evolve.

## 5. Truth model

Every durable claim has:

- statement or structured value;
- epistemic class: explicit fact, user report, observation, third-party claim, or inference;
- evidence links;
- confidence;
- valid time and recorded time where known;
- status: current, superseded, disputed, stale, or retracted.

Current-state notes are compact materialized views. Timelines preserve changes. Contradictions remain visible until contextual resolution is supported.

## 6. Execution model

Every candidate action moves through:

`captured → clarified → authorized → prepared → commit-ready → committed → verified → reconciled`

It may branch to `blocked`, `failed`, `cancelled`, or `rolled-back`. The commit point is the moment an external side effect occurs, such as submitting payment, sending a message, confirming a booking, deleting remote data, or accepting legal terms.

The execution queue ranks items using value, urgency, dependencies, effort, risk, confidence, alignment, and agent-completability. A queue item is not authorization.

## 7. Adaptive delegation model

The first materially new action class is confirmed at the commit point. A confirmed action produces evidence for an authorization pattern. Repetition may broaden trust within a category, but material dimensions remain bounded: purpose, service, recipient type, cost band, reversibility, data sensitivity, and legal significance.

Historical imports can propose candidate authorization rules. They cannot activate them solely because a transcript contains words such as “yes,” because context and execution outcome may be incomplete. See `Policies/Adaptive Delegation.md`.

## 8. Assimilation model

Conversation sources are normalized into a source-neutral event format. Assimilation is staged:

1. discover read-only sources;
2. normalize and redact;
3. deduplicate by source identity and content hash;
4. segment sessions;
5. extract candidate facts, preferences, decisions, projects, corrections, and approvals;
6. attach evidence;
7. resolve identity and temporal conflicts;
8. update confidence and materialized views;
9. write a bootstrap or incremental report.

Raw history remains available so later models can reprocess it without losing context.

## 9. Retrieval model

Retrieval begins with the task, not folder names. It identifies likely entity IDs, projects, time ranges, source types, and action risk. It then searches indexes, current state, relevant evidence, decisions, timelines, active workspace, SOPs, authorization rules, and recent sessions. Consequential tasks require contradiction and staleness checks.

Evidence used to answer or act is cited through note links or source locators. Retrieval performance problems are recorded in the self-model and may trigger index changes.

## 10. Maintenance model

- **Daily:** consolidate sessions, reconcile actions, update changed state, capture corrections, and reflect.
- **Weekly:** review projects, execution queue, contradictions, inferences, goals, SOPs, and self-model.
- **Monthly:** rebuild indexes, audit authorizations and privacy, assess retrieval, archive completed work, and propose or execute reversible migrations.

Maintenance is idempotent where possible. Each run records its time window, inputs, outputs, warnings, and version.

## 11. Self-evolution

PAIOS may evolve schemas, directory views, prompts, workflows, indexes, and SOPs. Migrations require a plan, backup or recoverable snapshot, dry-run when practical, validation, change log entry, and rollback instructions. Protected constitutional invariants require explicit approval.

## 12. Roles

Roles are responsibilities, not necessarily separate models:

- **Chief of Staff:** intent, priorities, queue, coordination, and user-facing outcome.
- **Librarian:** entities, provenance, retrieval, deduplication, schemas, and indexes.
- **Researcher:** source collection, comparison, and evidence quality.
- **Executor:** browser and tool actions, commit-point control, verification, and logs.
- **Historian:** sessions, timelines, decisions, and retrospectives.
- **Auditor:** contradictions, privacy, authorization validity, migrations, and data quality.
- **Optimizer:** SOPs, self-model, retrieval performance, and process improvement.

A single agent runtime may switch roles, or each role may be a separate agent; see `Handover/README.md` for a file-based handoff convention between agents. Role separation never bypasses authority rules.

## 13. Failure and recovery

- A crash before commitment leaves the item `prepared` or `commit-ready`; do not assume the action happened.
- A crash after an uncertain commit produces `verification-required`; inspect external state before retrying.
- Duplicate imports are skipped using source IDs and checksums.
- Invalid or partial records go to a quarantine report, not silent deletion.
- Migrations leave backups or reconstructible snapshots and explicit rollback steps.
