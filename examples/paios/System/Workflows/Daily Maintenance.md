# Daily Maintenance

## Inputs

- sessions and actions since the last successful daily run;
- changed projects and queue items;
- corrections and new evidence;
- failed or uncertain tool operations.

## Checklist

1. Follow [[System/Workflows/Current Truth]]. Fix the review upper bound at an observed source cutoff no later than run start. Enumerate each configured personal source's events/conversations after the last successful semantic cursor, using a completed import plus a read-only check for any later source tail. Record source counts, reviewed conversations, deliberately excluded transport/duplicate records, and remaining gaps in the report. Consolidate direct user changes and verified outcomes into existing canonical records; do not promote repeated prompts, mirrored messages or assistant proposals as user facts. A same-day session note or importer candidate list does not establish coverage of unreviewed conversations.
2. Write one dated report of material changes, evidence and remaining gaps. Keep `Runtime/Now.md` as navigation/attention, `Runtime/State.md` as system/coverage state, and `Knowledge/Current State/README.md` as a pointer. Do not create a second full-world daily snapshot or duplicate unchanged project narratives.
3. Reconcile committed, verified, failed, and uncertain actions.
4. Reconcile project current sections and exactly one queue row per task ID. Check canceled appointments, completed releases, lapsed dates and changed blockers against the latest relevant evidence; do not overwrite newer verified records with older imported summaries.
5. Capture explicit preferences, decisions, corrections, and goal changes.
6. Refresh evidence-backed inferences and mental models without overreacting to one event.
7. Record delegation observations; do not silently activate imported candidates.
8. Update SOPs only when a lesson generalizes.
9. Review redaction warnings and unresolved import failures.
10. Update `Runtime/Source Registry.md` with exact source/cursor state and coverage gaps, preserving per-run narrative in the dated report. Advance `Runtime/Last Maintenance.md`'s successful semantic cursor only through an interval whose source inventory is fully accounted for by review or documented exclusions. The cursor may advance to the boundary of any fully-accounted sub-interval even when it does not reach the current run's cutoff — do not withhold an earned advance merely because older, unrelated backlog remains further out; that backlog stays visible as the next gap instead of silently blocking progress already proven. If review is partial, record the attempt and useful corrections, retain the previous successful cursor, and state the uncovered interval. Scheduler success and completed import are separate outcomes. Confirm every configured conversation source is covered by an import mapping.

## Completion definition (bounded run)

A scheduled run is **complete** when integrity checks pass, the dated report, integrity receipt, Source Registry and Last Maintenance row are saved, and the cursor is advanced through every fully-accounted sub-interval or correctly retained with the uncovered interval stated. Remaining older backlog is the next gap, not a failure; a retrieval-check miss is a report warning, not a failure. Only an integrity failure, a privacy/security incident, unsaved receipts, or zero source IDs accounted for make a run a failure. Reason: treating "partial" as failure makes a scheduler retry and eventually disable a job that is making real progress on a large backlog.

## Daily reflection

- What changed today?
- What did the user correct?
- What action outcome remains unverified?
- Which belief strengthened, weakened, or became stale?
- Which project or commitment now needs attention?
- What should be easier or more accurate next time?

## Wiki integration

For sources or reusable answers processed during this review, complete [[System/Workflows/LLM Wiki]]: reconcile source receipts, affected canonical pages, navigation and append-only [[PAIOS/log]]. Record pending/partial sources and scoped lint gaps in [[Runtime/Wiki Review Queue]]. Document-source processing never advances conversation semantic cursors.

