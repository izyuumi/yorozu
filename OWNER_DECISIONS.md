# Owner decisions

## 2026-10-07 — Secretary orchestration
Source: direct owner message 1791356341648 in PROJECTX Coding conversation.

- Ambiguous follow-ups default to the latest topic, with correction available (option 1).
- The main agent underlying the single visible timeline is a small model acting as a secretary.
- It categorizes the latest message using the last few messages and topic database search when necessary.
- It delegates instructions to smaller agents in sub-chats to execute tasks.
- Topic categorization and delegation should feel seamless.

This corrects any interpretation of v0 as a single task-executing agent with topic labels attached. The main/worker separation is core architecture, not a later enhancement.

Implementation proposals, not yet owner decisions: one worker per task initially; structured validated routing output; show worker answers in the main timeline without a mandatory secretary rewrite. Exact model IDs remain open.

## 2026-10-07 16:01 JST — Invisible categorization; inspect-only sub-chats
Source: direct owner message 1791356502132.

- Sub-chats are inspect-only for now; no direct conversation input in them.
- Topic categorization runs completely in the background. Do not show topic labels, IDs, or routing controls in the main chat timeline.
- This supersedes the assistant's earlier visible/editable topic-chip proposal in README and conversation. The user confirmed default-to-latest-topic behavior, not visible categorization.
- The main timeline remains the single conversational input surface.

Implementation proposal: ordinary-language corrections (e.g. 'I meant the trip') update internal routing without requiring category management. Optional technical inspection belongs outside the normal timeline.

## 2026-10-07 16:04 JST — Nonblocking secretary is essential
Source: direct owner message 1791356640289.

The secretary must continue discussing with the user while delegated agents work. The owner explicitly identified this as the purpose of sub-chats/agents, not an optional enhancement. This supersedes the provisional one-worker-at-a-time assumption if it blocks conversation or additional delegation.

Implementation implications: asynchronous worker execution; available main composer; durable task/result association; compact active-task awareness for secretary; bounded worker concurrency without locking the main conversation. These are engineering proposals implementing the owner requirement, not separately prescribed details.

## 2026-10-07 16:05 JST — Steer existing work
Source: direct owner message 1791356747945.

Follow-up changes to ongoing work must steer the existing task/agent. Do not create new, separate tasks for these amendments.

Engineering implications: preserve task ID and sub-chat; retain instruction revision history; distinguish steering accepted from applied; do not deliver an obsolete completion as satisfying revised instructions. If a harness lacks active steering support, report that limitation rather than silently duplicating work. Exact fallback UX remains unconfirmed.

## 2026-10-07 16:08 JST — User-owned persistent memory is central
Source: direct owner message 1791356887777.

Both working state and long-term memory must be remembered by the app. Owner calls persistent user-owned memory the most important part of PROJECTX; storage is managed/indexed Markdown files and database. In response to the explicit question, owner confirms automatic memory rather than requiring 'remember this'. This supersedes initial explicit-write-only proposal.

Engineering interpretation: canonical long-term memory in readable Markdown; SQLite memory index rebuildable from Markdown; canonical conversation/task state separately persisted in SQLite. Memory independent of harness; preserve source references and correction lineage, distinguish clear user statements from guesses/tentative discussion. Background extraction must not block conversation. Manual edit/reindex, export/backup, and forgetting semantics need explicit design; do not imply a memory-index rebuild restores operational records.

## 2026-10-07 16:12 JST — Minimal Markdown-first memory
Source: direct owner message 1791357168732.

Markdown is the single source of truth for memory. Initial storage: hierarchical Markdown files in a directory, with SQLite indexing content summaries and file paths for faster search. User owns data; memory must not depend on app/vendor/harness ownership. Future RAG/vector retrieval may extend this; avoid premature architectural rigidity. No filesystem watching required.

Implementation proposal: update index after app writes; explicit reindex for external edits; search summaries to locate files, then read authoritative Markdown. Index is disposable/rebuildable, not a separate authoritative memory store. Operational chat/task persistence is distinct from the memory index. Forgetting vs deleting remains undecided: user requested more explanation, not approval of the assistant's suggested commands.

## 2026-10-07 16:18 JST — Forget only from Markdown; preserve chat history
Source: direct owner message 1791357491335.

Forget requests delete the relevant memory from Markdown. Derived index entries must reflect the resulting files. The system must not delete, redact or rewrite original chat history as part of memory management. The user may delete their history later if they choose. This resolves the previously open forgetting question and rejects system-driven history erasure.

Implementation scope: simple targeted memory deletion with index refresh; preserve unrelated content and original messages. Reindex reads current Markdown, not old chat; do not re-extract already processed history on rebuild. No elaborate suppression ledger requested.

## 2026-10-07 16:21 JST — Escalate ambiguity, then clarify
Source: direct owner message 1791357666853, '2 then 1'.

When the small secretary cannot resolve intent/target after recent-context and topic/task retrieval, escalate internally to a stronger model. If ambiguity remains, ask the user a concise clarification instead of guessing. Stronger-model fallback is permitted; secretary is not strictly small-model-only. Routing remains invisible. This qualifies, rather than replaces, default-to-latest-topic behavior for ordinary clear follow-ups.

Implementation proposal: one bounded escalation with configurable model roles; no task dispatch or steering until ambiguity is resolved.

## 2026-10-07 16:23 JST — Immediate completion delivery
Source: direct owner message 1791357801783, '1 is enough for poc'.

Post completed work immediately in the main timeline, clearly introducing which work the result concerns. No separate quiet-ready notification workflow needed for POC. Accompanying implementation recommendation: keep originating task attribution and inspect-only details; a background completion does not itself switch the active user-discussion topic.

## 2026-10-07 16:25 JST — Release roadmap
Source: direct owner message 1791357901724.

- POC R1: thinking and knowledge work.
- R2: developing PROJECTX itself.
- R3: computer and browser use.

This supersedes the assistant's suggested coding-first acceptance scenario. R1 focuses on discussion, topic continuity, user-owned memory, background knowledge tasks and steering. Coding execution and computer/browser product capabilities are deferred, not part of R1 acceptance. Building the app itself remains the authorized implementation task. Input scope resolved below on 16:27 JST.

## 2026-10-07 16:27 JST — R1 input scope
Source: direct owner message 1791358038027, option 1.

R1 accepts conversation and pasted text only, plus accumulated app-owned memory. External Markdown/text/PDF document import is outside this initial scope. Hierarchical Markdown memory storage remains required; this decision concerns input/ingestion features, not removal of memory files.

## 2026-10-07 16:33 JST — Automatically delegate substantive thinking
Source: direct owner message 1791358385774, option 1.

Automatically delegate substantive thinking/analysis to a capable worker. The small secretary handles quick replies, clarification and coordination, remaining available while work proceeds. User need not explicitly request delegation or deeper thinking. Do not require the small model to try answering substantive questions first. Worker responses appear naturally in the main timeline. Exact model selections remain configurable/unconfirmed.

## 2026-10-07 16:45 JST — Same growing sub-chat session for POC
Source: direct owner message 1791359116993.

Choose option 1: retain the same growing model session for a sub-chat for now. Discuss how to compact chats later. Do not implement the assistant's proposed periodic context refresh/reconstruction as an owner requirement. No custom compaction subsystem for POC; underlying harness behavior remains distinct from future app-managed compaction. Preserve same-task steering and app-owned memory.

## 2026-10-07 16:49 JST — Message/progress streaming in sub-chats
Source: direct owner message 1791359354135.

Stream worker output at message/progress granularity, not necessarily per token. Workers should behave like harness subagents or Codex/Claude Code; their emitted output should appear in their inspect-only sub-chats. This is a behavior/interface analogy, not a request to add coding integrations to R1.

Implementation interpretation: surface actual public worker messages, progress and supported tool events as they arrive; retain ordered events and distinguish progress from completion. No fabricated progress, secret leakage or private reasoning exposure. Final results still arrive immediately in main timeline. Placement resolved by owner at 16:51 JST below.

## 2026-10-07 16:51 JST — Progress confined to sub-chats
Source: direct owner message 1791359488930, 'Yes' to proposed placement.

Intermediate worker activity stays in the inspect-only sub-chat. Main timeline shows a brief acknowledgment and final answer, without intermediate progress/tool-event flooding. User may inspect live work separately. This complements immediate final-result delivery and message/progress-level sub-chat streaming.

## 2026-10-07 17:02 JST — Automatically retain topic knowledge
Source: direct owner message 1791360145884, 'Automatically retain'.

Automatically retain useful topic knowledge from discussions as well as personal facts/preferences/decisions; memory is not restricted to explicitly endorsed user statements. Preserve attribution: pasted source claims and agent-generated analysis must not become user beliefs or verified facts by mere retention. Topic conclusions, proposals and user-endorsed decisions remain distinguishable in Markdown. This expands the initial conservative personal-memory extraction scope.

## 2026-10-07 17:11 JST — Memory independent of topics
Source: direct owner message 1791360699749.

Memory is a different layer from topics. Retrieve relevant memory across topics automatically; topic IDs must not act as memory-access partitions. Topics organize conversation/task context, while the user-owned Markdown memory layer supports shared relevant knowledge. Topic/source references may aid provenance or ranking, not enforce topic-only retrieval. Retrieve selectively rather than loading all memory.

## 2026-10-07 17:16 JST — Workers may edit memory
Source: direct owner message 1791360969719.

Workers can edit memory files directly. This rejects the assistant's proposed exclusive app-managed memory writer. Provide worker read/write access scoped to the PROJECTX memory directory; Markdown remains authoritative, with derived index refresh. No authority to modify original chat history or unrelated filesystem locations follows from this decision.

Engineering proposal, not a separate owner requirement: lightweight per-file conflict detection and atomic writes to prevent silent lost updates; no elaborate coordination subsystem for POC. Do not represent read-only tools or queued suggestions as implemented worker editing.

## 2026-10-07 17:18 JST — Topic visibility belongs in sub-chats
Source: direct owner message 1791361132273.

Correction: the ban on topic labels applies to the main chat timeline, where attaching a topic name/ID to every message would overload the UI. Sub-chats SHOULD expose their topic. Do not interpret background categorization as a blanket ban on topic visibility throughout the app. Topic-named sub-chat headers/navigation are appropriate; the exact navigation/side-panel design remains a proposal, not confirmed. Sub-chats remain inspect-only.

## 2026-10-07 17:21 JST — One persistent sub-chat per topic
Source: direct owner message 1791361273761, 'Yes' to the preceding proposal.

R1 uses one persistent sub-chat per topic, reused when returning to that topic for follow-ups or further thinking. Separate topics get separate sub-chats. Amendments to ongoing work steer the existing task; a later request after completion continues the existing topic sub-chat rather than creating a new sub-chat. Topic, sub-chat/session, and task/run identities remain distinct. Preserve growing sessions; custom compaction remains deferred.

## 2026-10-07 17:23 JST — Broad topics for R1
Source: direct owner message 1791361418345, 'Go with your recommendation'.

Prefer broad subject/goal-level topics (project-sized where appropriate). Reuse the existing topic while advancing the same subject or goal; create a new one for meaningful subject changes. PROJECTX UX and PROJECTX memory discussion remain under PROJECTX, not automatically split into separate sub-chats. Automatic topic merging/splitting is deferred beyond the POC. This is a routing bias, not permission to mix unrelated subjects or bypass ambiguity escalation/clarification.

## 2026-10-07 17:24 JST — Simple wrong-topic recovery
Source: direct owner message 1791361496411, 'Yes' to proposed recovery.

For a routing mistake, send the correction to the intended existing topic sub-chat and stop the mistaken work if still running. Preserve original chat history and do not migrate/rewrite the mistaken sub-chat history. The mistaken exchange remains in the record. This is distinct from an amendment within the correct topic, which still steers the same task. Cancellation requests must not be represented as confirmed cancellation until acknowledged; stale results should not be delivered as answers to the corrected request.

## 2026-10-07 17:27 JST — No in-app memory management UI for R1
Source: direct owner message 1791361668005.

No dedicated in-app memory view/browser/editor/delete/reindex controls are needed for R1. This rejects the proposed Memory view, not the underlying memory features. Keep user-owned Markdown accessible externally and conversational memory behavior; no dashboard or file-management UI required. Inspect-only worker sub-chats remain in scope.

## 2026-10-07 17:30 JST — Simple failure and user-requested retry
Source: direct owner message 1791361808459, 'Yes' to proposed failure behavior.

On worker failure or lost connection, briefly notify the user in the main timeline instead of appearing indefinitely busy. Preserve the existing sub-chat and completed work. User can say 'retry' to continue in that same sub-chat. No automatic recovery/retry subsystem for R1. A lost connection does not prove underlying execution stopped; reconcile actual run status before retrying to avoid duplicate active work.

## 2026-10-07 17:32 JST — Native Mac app for R1
Source: direct owner message 1791361942504.

R1 must be a native Mac app, not the assistant's proposed desktop-browser product. Existing local web UI is a prototype, not the accepted delivery surface. Native SwiftUI/AppKit frontend is the proposed implementation interpretation; reuse tested backend/orchestration/storage where suitable instead of rewriting unrelated logic. Do not silently substitute a webview wrapper for native UI. No mobile, remote access, App Store publishing or signing-account changes requested.

## 2026-10-07 18:04 JST — Native layout approved
Source: direct owner message 1791363857346, 'Good' to proposed layout.

Native R1 layout: central main conversation; collapsible sidebar listing topic-named sub-chats with simple running/completed indicators; selecting a sub-chat opens an inspect-only pane alongside the main conversation. Main composer remains available. No per-message main-timeline topic labels and no dedicated memory-management UI.

## 2026-10-07 18:07 JST — Discuss stack before further implementation
Source: direct owner message 1791364048913.

Owner requests tech-stack discussion as the final point before building. Parent requested active native worker pause at safe point and preserve existing work; read-only feasibility checks allowed. Native Mac delivery/layout remain approved, but backend language/package/framework selection is not settled by earlier assistant proposals. Await stack decision before continuing implementation.

## 2026-10-07 18:10 JST — Swift-native stack approved; resume building
Source: direct owner message 1791364241989, 'Sounds good' to stack recommendation.

Approved R1 stack: SwiftUI with selective AppKit; Swift core using structured concurrency; GRDB/SQLite operational storage; hierarchical Markdown authoritative memory; separate rebuildable summary/relative-path SQLite memory index with FTS5; Swift harness adapter, OpenClaw first. No Python sidecar/local HTTP server required in final native app. Reuse prototype design/tests/integration findings, not necessarily its runtime. No Electron/Tauri/web frontend, SwiftData/Core Data, agent orchestration framework, vector service or plugin loader for R1.

Stack discussion pause is resolved; continue implementation within approved local project scope. Standalone live Gateway integration remains unverified and explicit runtime restrictions remain controlling.

## 2026-10-07 20:01 JST — Stop tests for now
Source: direct owner message 1791370874480.

Owner says no need to run any tests right now; this is a POC. Stop further automated suites and UI test runs for now. Deliver the staged repair without making verification another immediate user chore. This does not establish live success: preserve the distinction between implemented repair and unverified live behavior. No active worker/testing process at this decision.

## 2026-10-07 20:03 JST — Resume computer-use check
Source: direct owner messages 1791370993319 and 1791371002033.

Owner explicitly requests computer-use testing to see whether the repaired app actually works. This supersedes the 20:01 testing pause for UI testing, not an instruction to rerun automated suites. Parent inspected current window/process: PID 51375 still runs the old PROJECTX-Live-R1.app, not the staged transport-fix bundle. Corrected-app owner launch remains prerequisite under existing attribution restriction.

Worker delivery/acceptance is not proof of implementation; see TASKS.md and test evidence for current status.

## 2026-10-07 — No Python; Rust for background processes
Source: direct owner message in Claude Code session.

PROJECTX is Swift. No Python anywhere in the product or repo. If a background process is ever needed, write it in Rust, not Python. The preserved Python/web prototype was removed from the `projectx` branch (still reachable in git history at commit 7269133).

## 2026-10-07 — Data locations
Source: direct owner messages in Claude Code session.

Private app state goes in `~/Library/Application Support/<bundle id>` (Apple guidance); the rebuildable memory index goes in `~/Library/Caches/<bundle id>`. The user-owned Markdown memory lives in the visible `~/Yorozu/memory`. No migration code in the app at this early stage; the owner's existing data was moved once by hand.
