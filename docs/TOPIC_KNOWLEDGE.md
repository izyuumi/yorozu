> Historical Python-prototype record. Current approved Swift-native architecture and consolidated evidence: [NATIVE_R1.md](NATIVE_R1.md). Preserve the evidence below; it is not the final app runtime.

# Attributed, cross-topic knowledge memory — bounded review

Implements owner decisions at 2026-10-07 17:02 (retain useful topic knowledge) and 17:11 (memory is independent of topics).

## What changed

The semantic extractor now accepts conversation/pasted text and committed visible assistant/worker replies. Completion schedules extraction asynchronously after the original answer is committed, so memory work does not delay final delivery. Hidden reasoning and intermediate tool data are not extraction inputs.

Canonical Markdown headers and retrieval carry:
- `knowledge_type`: user_fact, user_preference, user_decision, user_belief, source_claim, generated_analysis, topic_synthesis, tentative_hypothesis.
- `attribution`: user, quoted_source or assistant.
- `epistemic_status`: user_stated, unverified or tentative. The model schema has no verified status.
- Original message IDs, exact supporting quotes, origin role/source kind, timestamps and correction lineage.

Useful hypotheses may be saved as tentative; uncertainty is not silently removed. Worker-generated claims cannot become personal user facts/beliefs. Known quotation/reported-speech markers block personal-user attribution of pasted content. Worker citations may retain quoted_source attribution with assistant origin. Contrasting source claims do not implicitly merge; cross-attribution/type replacement is refused. Nonpersonal replacement requires an explicit correction marker. Direct-user corrections can reuse stable semantic keys across topics. Prior value/source/attribution remains in lineage.

## Memory is not a topic silo

Worker conversational history is still selected by topic. Memory discovery is global across the project's Markdown directory. Current topic is only an optional ranking hint/provenance value, not a filter or ACL. Lexical title/summary relevance ranks candidates first; the topic hint breaks ties. The selected index paths are read from actual Markdown before supplying content and attribution. Existing 8-note/10 KB retrieval and 2.5 KB worker-memory budgets remain.

Notes can be written without any topic provenance and reindexed even if an old topic record no longer exists. The index schema remains discovery metadata (summary/path plus ID/title/optional provenance); no knowledge exists only in SQLite. No vectors, watcher, external import, suppression subsystem or global/private-vault search was added.

## Safety and limits

Exact source IDs/quotes and a closed schema gate writes; all proposals validate before write iteration. Known credential patterns are excluded from model input and proposed output. These are conservative checks, not complete secret detection or formal semantic entailment. Ambiguous/unmarked pasted material still depends on model classification, and broad secret-related filters can omit benign technical discussion. Large assistant outputs use marked first/last excerpts within the existing input budget; useful material in the omitted middle can be missed.

Lexical summary discovery can miss paraphrases or deep content not reflected in a summary. New/renamed/deleted files and changed discovery summaries need explicit Rebuild; no watcher. Actual selected Markdown contents are read even when summary metadata is stale.

Forget removes selected Markdown/index content only. Source conversation messages are never rewritten/deleted/redacted by memory maintenance. Processed extraction receipts prevent replay of forgotten material. No new live transport attempt was made: the explicit Gateway exec-attribution restriction remains controlling, and model extraction quality for this expanded prompt is not live-verified.

Subsequent worker-directed editing is implemented as an application-mediated scoped file contract; see WORKER_MEMORY_WRITES.md. This earlier knowledge-extraction review did not itself establish native tool registration or live worker write access.

## Test evidence

Full suite: **42 tests passed**. Added tests cover pasted-source retention without belief/verification promotion, useful generated synthesis, tentative hypotheses, worker-cited sources, contrasting claims, correction lineage, memory-only forgetting, credential exclusion, automatic completed-worker extraction and bounded long-output excerpts. Cross-topic tests prove relevant foreign-topic memory is retrieved while foreign-topic conversation history is excluded; topic-free tool queries, optional provenance, independence from topic records, and summary/path discovery followed by actual Markdown reads also pass.

The previous conversation-isolation test was renamed to distinguish isolated conversational history from selective global memory. Existing persistence, steering-race, event projection, origin-guard and no-replay tests continue to pass. These are synthetic local tests, not a new live Gateway/model evaluation.
