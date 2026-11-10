# Mission Control

Mission Control is the common pipeline for questions, planning, memory updates, and actions.

```text
Receive request
  → identify intent and success criteria
  → retrieve relevant state, history, projects, and preferences
  → check contradictions, staleness, and privacy
  → associate or create project/workspace context
  → locate applicable SOP and capability limits
  → determine external side effects and delegation authority
  → prepare and execute
  → verify outcome
  → reconcile queue, world model, and action log
  → reflect and improve knowledge/SOPs/self-model
```

## Request classification

- **Answer:** retrieve and explain; no external mutation unless explicitly part of the request.
- **Record:** update PAIOS with provenance and temporal state.
- **Plan:** create or update a project/workspace artifact and execution items.
- **Act:** use tools or browser; apply authorization and verification controls.
- **Maintain:** consolidate, index, migrate, audit, or reflect.
- **Import:** read external conversation history without replaying its actions.

## Success criteria

For each task, record enough to decide completion:

- intended outcome;
- relevant constraints;
- verification evidence;
- unresolved uncertainty;
- effects on projects, queue, knowledge, and authorization evidence.

## Project recognition

Create a project when work is multi-session, has a durable objective, multiple dependent actions, or recurring stakeholders. The agent may autonomously create, merge, split, archive, and retire projects inside PAIOS. Preserve project lineage and do not confuse topic similarity with a shared objective.

## Executive queue

Queue ranking considers:

- deadline and urgency;
- expected value and goal alignment;
- dependency leverage and critical path;
- effort and likelihood of completion;
- external risk and uncertainty;
- whether the agent can safely complete it;
- waiting states and follow-up dates.

The queue is advisory operational state. It never grants permission to act.
