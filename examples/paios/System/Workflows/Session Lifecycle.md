# Session Lifecycle

## Open

1. Load constitutional and runtime state.
2. Identify or create a session ID.
3. Create a session journal from `System/Templates/Session.md`.
4. Record runtime, start time, source, and the user's initial intent.
5. Retrieve active context only after the intent is understood.

## Continue

After meaningful turns, update:

- requests and constraints;
- decisions and corrections;
- entities and projects mentioned;
- actions prepared, committed, and verified;
- open questions, blockers, and promises;
- evidence links for potential durable knowledge.

Avoid copying the entire transcript into Markdown when the normalized source already preserves it. The journal is an operational summary and recovery aid.

## Milestone consolidation

At a decision, completed action, task handoff, or major topic shift:

1. promote supported durable claims;
2. update current state and timelines;
3. reconcile projects and queue;
4. write action or decision records;
5. capture corrections and potential SOP lessons.

## Close

1. Confirm all external action states.
2. Summarize outcomes, not hidden reasoning.
3. Record remaining open loops and next safe steps.
4. Update the self-model for material successes or failures.
5. Mark session status `closed`, `interrupted`, or `handoff`.
6. Link any daily report covering the session.
