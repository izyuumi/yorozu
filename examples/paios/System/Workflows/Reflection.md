# Reflection Workflow

Reflection converts outcomes into better models and procedures. It does not invent hidden reasoning records.

## Questions

- What did the system learn?
- What changed in current state?
- Which evidence strengthened or weakened a belief?
- What did the user correct, reject, or approve?
- Did an action achieve its intended outcome?
- Was authority matched correctly?
- Which prediction succeeded or failed?
- Which workflow caused unnecessary friction?
- Which SOP or capability note should change?
- Which project, goal, or queue priority moved?
- What retrieval was missing, stale, slow, or overbroad?
- What must be preserved for next time?

## Bounded preference-learning loop

For an owner-approved learning pilot or a relevant correction, use this loop before performing the next matching task. Pilot state and source limits live in [[Projects/Example Project]] (or a dedicated pilot project you create); this workflow owns the procedure, not a second preference store.

1. Establish the permitted source scope. In a shared conversation, use supplied group evidence or exact same-group history only when its scope is proven. Do not load private runtime state, personal records or cross-session memory to fill a gap. Record source locator, speaker, event time, quote versus supplied summary, and missing evidence.
2. Classify each signal as a durable preference, a task-local instruction, an execution failure, or unresolved. A repeated tool failure is not a user preference; diagnose the failed execution. Assistant examples are not owner preferences. An explicit preference can be supported by one direct statement, but a recurring correction requires at least two distinct corrective events with matching context, not duplicate imports or paraphrases of one event.
3. Find the existing matching owner within authorized scope before adding guidance. Consolidate the current rule in place, preserving prior evidence and exact rollback; current explicit instructions take precedence in genuine conflicts. If its owner cannot be accessed in this scope, keep a scoped candidate and record the unresolved ownership rather than searching private records or creating a competing global preference. Draft from the user's actual language; do not make the user rewrite preferences. Ask only for a material unresolved choice.
4. Encode each supported rule as Trigger / Do / Boundary with source references, classification, scope, confidence, review condition and history. A boundary states exceptions and what authority is not granted. Keep unsubstantiated pilot slots pending; never invent enough corrections to reach a quota.
5. Add a regression example grounded in the actual correction or approved procedure: input/context, expected action, prohibited action, evidence and pass criterion. Label constructed situations synthetic. Before the next relevant task, retrieve only the matching scoped rule, apply its Trigger / Do / Boundary, and verify the result rather than merely citing the saved file.
6. Track saved and behavior-verified separately. Saved means the canonical edit and retrieval link were checked. Synthetic checks establish only their named test property. Behavior evidence requires an actual later relevant task, its source/output locator, applied rule, observed result, correction or acceptance if available, and an explicit pass/fail/unknown verdict. Silence is not satisfaction; unknown stays unknown. Do not count implementation or synthetic tests among the next five tasks.
7. When the same correction recurs, diagnose whether the rule was missing, not retrieved, misclassified, out of scope, overridden, or retrieved but not executed; separately identify tool/execution failure and failed result verification. Patch the narrow cause and add the failing case without broadening authority or appending contradictory guidance. Re-test the changed procedure, preserve earlier failures, and update the one task row and minimal source journal.
8. After five observed relevant tasks, review outcomes and gaps with the owner. Report passes/failures/unknowns and any repeated correction; retain, narrow or propose retiring each candidate based on evidence, not quota completion. No five-task claim is valid without five distinct real-task records. This is instruction-based retrieval, not model-weight training or an automatic capture service.

## Outputs

Update only supported records. Link every model change to evidence. If a lesson is one-off, keep it in the session or action record rather than creating a universal rule.
