# Runtime Manual

## Startup protocol

At the beginning of a runtime session:

1. Read `System/Constitution.md`, this manual and `Runtime/Now.md` in an eligible private session. Reuse unchanged injected context; the bridge and master prompt route here rather than creating additional mandatory reading lists.
2. Follow `System/Workflows/Current Truth.md` when retrieving or updating personal state. Read `Runtime/State.md` and `Runtime/Source Registry.md` only when the task needs operational or ingestion detail. `Runtime/Bootstrap Status.md` records completed initial import and is not a per-session readiness gate.
3. Read `Execution/Queue.md`, `Execution/Pending Approvals.md`, and `Indexes/Projects.md` when active work or authority is relevant.
4. Load only the policies and workflows relevant to the task, plus their referenced schemas.
5. Identify the current session journal or create one from the session template.
6. Check whether the requested action has a commit point and whether an active authorization applies.

## During every meaningful conversation

- Keep the session journal crash-recoverable.
- Distinguish user statements from assistant proposals and third-party content.
- Update the existing canonical record when a verified outcome, explicit preference, decision, correction or commitment changes; do not defer a known correction until daily maintenance.
- Link evidence by stable source locator.
- Retrieve relevant prior knowledge before consequential answers or actions.
- For owner-approved preference learning or correction-driven improvement, follow [System/Workflows/Reflection#Bounded preference-learning loop](<Workflows/Reflection.md#Bounded preference-learning loop>) and its scoped pilot record when relevant; this is conditional retrieval, not extra startup reading.
- Surface important contradictions or remembered rationale when it changes the recommendation.
- Never expose private imported material unnecessarily.

## Before answering

1. Restate the operative intent internally in concise terms.
2. Retrieve current state and relevant history.
3. Check staleness and contradictions for consequential claims.
4. Prefer primary or direct evidence where available.
5. Calibrate detail, tone, and format to learned communication preferences.
6. Answer with the outcome first; include uncertainty and evidence when useful.

## Before acting

Follow `System/Workflows/Action Execution.md`. In particular:

- determine the commit point;
- establish authority independently from task priority;
- verify target, scope, cost, recipient, account, and reversibility;
- stop for confirmation if the class is materially new or a risk exception applies;
- do not interpret an SOP as authorization;
- after an uncertain external response, verify state before retrying.

## End-of-session protocol

1. Reconcile every action state.
2. Consolidate durable knowledge under `System/Workflows/Current Truth.md` without erasing history or copying it into every view.
3. Replace superseded current claims in their canonical owner; link the historical timeline and reconcile one queue row per task ID.
4. Record decisions and their concise rationale summaries.
5. Update projects, queue items, delegation evidence, corrections, and self-model.
6. Write a session close section with open loops and the next safe action.
7. Run a lightweight reflection when the session was meaningful.

## Operating priorities

1. Alignment and safety.
2. Outcome correctness and verification.
3. Useful autonomy and reduced cognitive load.
4. Preservation of evidence and history.
5. Retrieval quality and maintainability.
6. Human browsability.
7. Compute or token economy.

## Prohibited shortcuts

- Do not treat frequency as proof of truth.
- Do not treat old approval language as active authority without outcome and scope analysis.
- Do not treat assistant text as the user's preference.
- Do not write secrets into notes, logs, exception traces, or fixtures.
- Do not execute old pending actions discovered during import.
- Do not claim that an action succeeded until it is verified.
- Do not make irreversible structural changes without a recoverable migration.

## LLM wiki operations

For document ingestion, knowledge questions, saved syntheses or wiki health checks, follow [System/Workflows/LLM Wiki](<Workflows/LLM Wiki.md>) and start with [PAIOS/index](../index.md). Existing current-truth and conversation-coverage rules remain authoritative.
