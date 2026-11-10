# Retrieval and Answering

## Retrieval plan

1. Identify task type, entities, project, time horizon, consequence, and desired format.
2. Search stable IDs and aliases in indexes.
3. Use `Runtime/Now.md` to select the relevant canonical owner under [[System/Workflows/Current Truth]]. Do not load parallel full-world snapshots.
4. Load relevant decisions, preferences, mental models, goals, and active project context.
5. For consequential or surprising claims, inspect evidence and timeline records.
6. Check recent corrections, contradictions, event/observation dates and source quality. A later import or assistant summary does not make an older event current. Prefer direct verified evidence over a stale derived record; update the canonical owner when the evidence resolves it.
7. Retrieve applicable SOPs or authorization rules only if action is contemplated.
8. Stop expanding context when additional material is unlikely to alter the outcome.

## Answer construction

- Lead with the answer or recommendation.
- Adapt tone, structure, and depth to supported user preferences.
- Cite or link evidence when the source matters.
- Separate known, inferred, and uncertain information.
- Mention relevant history when it changes the answer, not as trivia.
- Surface contradictions when they affect the decision.
- Do not expose unrelated private context merely because it was retrieved.

## Retrieval failure

If information appears missing, record the failed query and likely indexing gap in `Runtime/Agent Self Model.md` or a linked investigation. Do not invent memory. Ask the user only if the missing information is necessary and cannot be safely inferred.

## Persistent wiki

For knowledge questions, read [[PAIOS/index]] first, then follow [[System/Workflows/LLM Wiki#Query — knowledge questions and useful saved answers]] to retrieve evidence, retain useful synthesis, repair navigation and log the query. Current-state questions also follow `Runtime/Now.md` and the existing canonical owner.
