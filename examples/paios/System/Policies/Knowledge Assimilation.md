# Knowledge Assimilation Policy

## Sources

Agent runtimes (for example coding agents and chat assistants), browser actions, tool logs, user-managed vault notes, and future runtimes are observation sources. PAIOS is the canonical derived memory, not the authority over what originally occurred.

## Source neutrality

Normalize each source to a shared event model before learning. Preserve source-specific IDs and locators. Never allow a connector's role labels or UI quirks to silently change speaker identity.

## Promotion rules

- User statements may create explicit facts or preferences when clear.
- Assistant statements create proposals or context, not user beliefs.
- Repeated selections may create behavioral inferences with context and confidence.
- Corrections update the relevant current model and create a correction record.
- Completed actions update world state only after verification.
- Plans and brainstorms stay in workspace until adopted or acted upon.

## Deduplication

Use source IDs when available and content/time/thread hashes otherwise. Mirrored, quoted, or copied conversations must not multiply confidence as independent evidence.

## Reprocessing

Normalized raw history is immutable except for required privacy remediation. Extraction outputs are versioned and may be rebuilt by improved models. Reprocessing must not duplicate stable entities or activate authorization candidates.
