# Owner decisions log

Every owner decision in the order it was logged, including entries later superseded, kept as written; only chat message IDs were removed. Decisions logged after the fact carry their own date and are marked "logged late". The current decisions are in [OWNER_DECISIONS.md](../../OWNER_DECISIONS.md). Append new entries at the end.

## 2026-10-07 — Secretary orchestration
Source: direct owner message in PROJECTX Coding conversation.

- Ambiguous follow-ups default to the latest topic, with correction available (option 1).
- The main agent underlying the single visible timeline is a small model acting as a secretary.
- It categorizes the latest message using the last few messages and topic database search when necessary.
- It delegates instructions to smaller agents in sub-chats to execute tasks.
- Topic categorization and delegation should feel seamless.

This corrects any interpretation of v0 as a single task-executing agent with topic labels attached. The main/worker separation is core architecture, not a later enhancement.

Implementation proposals, not yet owner decisions: one worker per task initially; structured validated routing output; show worker answers in the main timeline without a mandatory secretary rewrite. Exact model IDs remain open.

## 2026-10-07 16:01 JST — Invisible categorization; inspect-only sub-chats
Source: direct owner message.

- Sub-chats are inspect-only for now; no direct conversation input in them.
- Topic categorization runs completely in the background. Do not show topic labels, IDs, or routing controls in the main chat timeline.
- This supersedes the assistant's earlier visible/editable topic-chip proposal in README and conversation. The user confirmed default-to-latest-topic behavior, not visible categorization.
- The main timeline remains the single conversational input surface.

Implementation proposal: ordinary-language corrections (e.g. 'I meant the trip') update internal routing without requiring category management. Optional technical inspection belongs outside the normal timeline.

## 2026-10-07 16:04 JST — Nonblocking secretary is essential
Source: direct owner message.

The secretary must continue discussing with the user while delegated agents work. The owner explicitly identified this as the purpose of sub-chats/agents, not an optional enhancement. This supersedes the provisional one-worker-at-a-time assumption if it blocks conversation or additional delegation.

Implementation implications: asynchronous worker execution; available main composer; durable task/result association; compact active-task awareness for secretary; bounded worker concurrency without locking the main conversation. These are engineering proposals implementing the owner requirement, not separately prescribed details.

## 2026-10-07 16:05 JST — Steer existing work
Source: direct owner message.

Follow-up changes to ongoing work must steer the existing task/agent. Do not create new, separate tasks for these amendments.

Engineering implications: preserve task ID and sub-chat; retain instruction revision history; distinguish steering accepted from applied; do not deliver an obsolete completion as satisfying revised instructions. If a harness lacks active steering support, report that limitation rather than silently duplicating work. Exact fallback UX remains unconfirmed.

## 2026-10-07 16:08 JST — User-owned persistent memory is central
Source: direct owner message.

Both working state and long-term memory must be remembered by the app. Owner calls persistent user-owned memory the most important part of PROJECTX; storage is managed/indexed Markdown files and database. In response to the explicit question, owner confirms automatic memory rather than requiring 'remember this'. This supersedes initial explicit-write-only proposal.

Engineering interpretation: canonical long-term memory in readable Markdown; SQLite memory index rebuildable from Markdown; canonical conversation/task state separately persisted in SQLite. Memory independent of harness; preserve source references and correction lineage, distinguish clear user statements from guesses/tentative discussion. Background extraction must not block conversation. Manual edit/reindex, export/backup, and forgetting semantics need explicit design; do not imply a memory-index rebuild restores operational records.

## 2026-10-07 16:12 JST — Minimal Markdown-first memory
Source: direct owner message.

Markdown is the single source of truth for memory. Initial storage: hierarchical Markdown files in a directory, with SQLite indexing content summaries and file paths for faster search. User owns data; memory must not depend on app/vendor/harness ownership. Future RAG/vector retrieval may extend this; avoid premature architectural rigidity. No filesystem watching required.

Implementation proposal: update index after app writes; explicit reindex for external edits; search summaries to locate files, then read authoritative Markdown. Index is disposable/rebuildable, not a separate authoritative memory store. Operational chat/task persistence is distinct from the memory index. Forgetting vs deleting remains undecided: user requested more explanation, not approval of the assistant's suggested commands.

## 2026-10-07 16:18 JST — Forget only from Markdown; preserve chat history
Source: direct owner message.

Forget requests delete the relevant memory from Markdown. Derived index entries must reflect the resulting files. The system must not delete, redact or rewrite original chat history as part of memory management. The user may delete their history later if they choose. This resolves the previously open forgetting question and rejects system-driven history erasure.

Implementation scope: simple targeted memory deletion with index refresh; preserve unrelated content and original messages. Reindex reads current Markdown, not old chat; do not re-extract already processed history on rebuild. No elaborate suppression ledger requested.

## 2026-10-07 16:21 JST — Escalate ambiguity, then clarify
Source: direct owner message, '2 then 1'.

When the small secretary cannot resolve intent/target after recent-context and topic/task retrieval, escalate internally to a stronger model. If ambiguity remains, ask the user a concise clarification instead of guessing. Stronger-model fallback is permitted; secretary is not strictly small-model-only. Routing remains invisible. This qualifies, rather than replaces, default-to-latest-topic behavior for ordinary clear follow-ups.

Implementation proposal: one bounded escalation with configurable model roles; no task dispatch or steering until ambiguity is resolved.

## 2026-10-07 16:23 JST — Immediate completion delivery
Source: direct owner message, '1 is enough for poc'.

Post completed work immediately in the main timeline, clearly introducing which work the result concerns. No separate quiet-ready notification workflow needed for POC. Accompanying implementation recommendation: keep originating task attribution and inspect-only details; a background completion does not itself switch the active user-discussion topic.

## 2026-10-07 16:25 JST — Release roadmap
Source: direct owner message.

- POC R1: thinking and knowledge work.
- R2: developing PROJECTX itself.
- R3: computer and browser use.

This supersedes the assistant's suggested coding-first acceptance scenario. R1 focuses on discussion, topic continuity, user-owned memory, background knowledge tasks and steering. Coding execution and computer/browser product capabilities are deferred, not part of R1 acceptance. Building the app itself remains the authorized implementation task. Input scope resolved below on 16:27 JST.

## 2026-10-07 16:27 JST — R1 input scope
Source: direct owner message, option 1.

R1 accepts conversation and pasted text only, plus accumulated app-owned memory. External Markdown/text/PDF document import is outside this initial scope. Hierarchical Markdown memory storage remains required; this decision concerns input/ingestion features, not removal of memory files.

## 2026-10-07 16:33 JST — Automatically delegate substantive thinking
Source: direct owner message, option 1.

Automatically delegate substantive thinking/analysis to a capable worker. The small secretary handles quick replies, clarification and coordination, remaining available while work proceeds. User need not explicitly request delegation or deeper thinking. Do not require the small model to try answering substantive questions first. Worker responses appear naturally in the main timeline. Exact model selections remain configurable/unconfirmed.

## 2026-10-07 16:45 JST — Same growing sub-chat session for POC
Source: direct owner message.

Choose option 1: retain the same growing model session for a sub-chat for now. Discuss how to compact chats later. Do not implement the assistant's proposed periodic context refresh/reconstruction as an owner requirement. No custom compaction subsystem for POC; underlying harness behavior remains distinct from future app-managed compaction. Preserve same-task steering and app-owned memory.

## 2026-10-07 16:49 JST — Message/progress streaming in sub-chats
Source: direct owner message.

Stream worker output at message/progress granularity, not necessarily per token. Workers should behave like harness subagents or Codex/Claude Code; their emitted output should appear in their inspect-only sub-chats. This is a behavior/interface analogy, not a request to add coding integrations to R1.

Implementation interpretation: surface actual public worker messages, progress and supported tool events as they arrive; retain ordered events and distinguish progress from completion. No fabricated progress, secret leakage or private reasoning exposure. Final results still arrive immediately in main timeline. Placement resolved by owner at 16:51 JST below.

## 2026-10-07 16:51 JST — Progress confined to sub-chats
Source: direct owner message, 'Yes' to proposed placement.

Intermediate worker activity stays in the inspect-only sub-chat. Main timeline shows a brief acknowledgment and final answer, without intermediate progress/tool-event flooding. User may inspect live work separately. This complements immediate final-result delivery and message/progress-level sub-chat streaming.

## 2026-10-07 17:02 JST — Automatically retain topic knowledge
Source: direct owner message, 'Automatically retain'.

Automatically retain useful topic knowledge from discussions as well as personal facts/preferences/decisions; memory is not restricted to explicitly endorsed user statements. Preserve attribution: pasted source claims and agent-generated analysis must not become user beliefs or verified facts by mere retention. Topic conclusions, proposals and user-endorsed decisions remain distinguishable in Markdown. This expands the initial conservative personal-memory extraction scope.

## 2026-10-07 17:11 JST — Memory independent of topics
Source: direct owner message.

Memory is a different layer from topics. Retrieve relevant memory across topics automatically; topic IDs must not act as memory-access partitions. Topics organize conversation/task context, while the user-owned Markdown memory layer supports shared relevant knowledge. Topic/source references may aid provenance or ranking, not enforce topic-only retrieval. Retrieve selectively rather than loading all memory.

## 2026-10-07 17:16 JST — Workers may edit memory
Source: direct owner message.

Workers can edit memory files directly. This rejects the assistant's proposed exclusive app-managed memory writer. Provide worker read/write access scoped to the PROJECTX memory directory; Markdown remains authoritative, with derived index refresh. No authority to modify original chat history or unrelated filesystem locations follows from this decision.

Engineering proposal, not a separate owner requirement: lightweight per-file conflict detection and atomic writes to prevent silent lost updates; no elaborate coordination subsystem for POC. Do not represent read-only tools or queued suggestions as implemented worker editing.

## 2026-10-07 17:18 JST — Topic visibility belongs in sub-chats
Source: direct owner message.

Correction: the ban on topic labels applies to the main chat timeline, where attaching a topic name/ID to every message would overload the UI. Sub-chats SHOULD expose their topic. Do not interpret background categorization as a blanket ban on topic visibility throughout the app. Topic-named sub-chat headers/navigation are appropriate; the exact navigation/side-panel design remains a proposal, not confirmed. Sub-chats remain inspect-only.

## 2026-10-07 17:21 JST — One persistent sub-chat per topic
Source: direct owner message, 'Yes' to the preceding proposal.

R1 uses one persistent sub-chat per topic, reused when returning to that topic for follow-ups or further thinking. Separate topics get separate sub-chats. Amendments to ongoing work steer the existing task; a later request after completion continues the existing topic sub-chat rather than creating a new sub-chat. Topic, sub-chat/session, and task/run identities remain distinct. Preserve growing sessions; custom compaction remains deferred.

## 2026-10-07 17:23 JST — Broad topics for R1
Source: direct owner message, 'Go with your recommendation'.

Prefer broad subject/goal-level topics (project-sized where appropriate). Reuse the existing topic while advancing the same subject or goal; create a new one for meaningful subject changes. PROJECTX UX and PROJECTX memory discussion remain under PROJECTX, not automatically split into separate sub-chats. Automatic topic merging/splitting is deferred beyond the POC. This is a routing bias, not permission to mix unrelated subjects or bypass ambiguity escalation/clarification.

## 2026-10-07 17:24 JST — Simple wrong-topic recovery
Source: direct owner message, 'Yes' to proposed recovery.

For a routing mistake, send the correction to the intended existing topic sub-chat and stop the mistaken work if still running. Preserve original chat history and do not migrate/rewrite the mistaken sub-chat history. The mistaken exchange remains in the record. This is distinct from an amendment within the correct topic, which still steers the same task. Cancellation requests must not be represented as confirmed cancellation until acknowledged; stale results should not be delivered as answers to the corrected request.

## 2026-10-07 17:27 JST — No in-app memory management UI for R1
Source: direct owner message.

No dedicated in-app memory view/browser/editor/delete/reindex controls are needed for R1. This rejects the proposed Memory view, not the underlying memory features. Keep user-owned Markdown accessible externally and conversational memory behavior; no dashboard or file-management UI required. Inspect-only worker sub-chats remain in scope.

## 2026-10-07 17:30 JST — Simple failure and user-requested retry
Source: direct owner message, 'Yes' to proposed failure behavior.

On worker failure or lost connection, briefly notify the user in the main timeline instead of appearing indefinitely busy. Preserve the existing sub-chat and completed work. User can say 'retry' to continue in that same sub-chat. No automatic recovery/retry subsystem for R1. A lost connection does not prove underlying execution stopped; reconcile actual run status before retrying to avoid duplicate active work.

## 2026-10-07 17:32 JST — Native Mac app for R1
Source: direct owner message.

R1 must be a native Mac app, not the assistant's proposed desktop-browser product. Existing local web UI is a prototype, not the accepted delivery surface. Native SwiftUI/AppKit frontend is the proposed implementation interpretation; reuse tested backend/orchestration/storage where suitable instead of rewriting unrelated logic. Do not silently substitute a webview wrapper for native UI. No mobile, remote access, App Store publishing or signing-account changes requested.

## 2026-10-07 18:04 JST — Native layout approved
Source: direct owner message, 'Good' to proposed layout.

Native R1 layout: central main conversation; collapsible sidebar listing topic-named sub-chats with simple running/completed indicators; selecting a sub-chat opens an inspect-only pane alongside the main conversation. Main composer remains available. No per-message main-timeline topic labels and no dedicated memory-management UI.

## 2026-10-07 18:07 JST — Discuss stack before further implementation
Source: direct owner message.

Owner requests tech-stack discussion as the final point before building. Parent requested active native worker pause at safe point and preserve existing work; read-only feasibility checks allowed. Native Mac delivery/layout remain approved, but backend language/package/framework selection is not settled by earlier assistant proposals. Await stack decision before continuing implementation.

## 2026-10-07 18:10 JST — Swift-native stack approved; resume building
Source: direct owner message, 'Sounds good' to stack recommendation.

Approved R1 stack: SwiftUI with selective AppKit; Swift core using structured concurrency; GRDB/SQLite operational storage; hierarchical Markdown authoritative memory; separate rebuildable summary/relative-path SQLite memory index with FTS5; Swift harness adapter, OpenClaw first. No Python sidecar/local HTTP server required in final native app. Reuse prototype design/tests/integration findings, not necessarily its runtime. No Electron/Tauri/web frontend, SwiftData/Core Data, agent orchestration framework, vector service or plugin loader for R1.

Stack discussion pause is resolved; continue implementation within approved local project scope. Standalone live Gateway integration remains unverified and explicit runtime restrictions remain controlling.

## 2026-10-07 20:01 JST — Stop tests for now
Source: direct owner message.

Owner says no need to run any tests right now; this is a POC. Stop further automated suites and UI test runs for now. Deliver the staged repair without making verification another immediate user chore. This does not establish live success: preserve the distinction between implemented repair and unverified live behavior. No active worker/testing process at this decision.

## 2026-10-07 20:03 JST — Resume computer-use check
Source: direct owner messages.

Owner explicitly requests computer-use testing to see whether the repaired app actually works. This supersedes the 20:01 testing pause for UI testing, not an instruction to rerun automated suites. Parent inspected current window/process: PID 51375 still runs the old PROJECTX-Live-R1.app, not the staged transport-fix bundle. Corrected-app owner launch remains prerequisite under existing attribution restriction.

Worker delivery/acceptance is not proof of implementation; see TASKS.md and test evidence for current status. [TASKS.md and docs/TEST_EVIDENCE.md were removed; current status is [docs/status.md](../status.md), and earlier versions are in git history, for example at f154d58.]

## 2026-10-07 — No Python; Rust for background processes
Source: direct owner message in Claude Code session.

PROJECTX is Swift. No Python anywhere in the product or repo. If a background process is ever needed, write it in Rust, not Python. The preserved Python/web prototype was removed from the `projectx` branch (still reachable in git history at commit 7269133).

## 2026-10-07 — Data locations
Source: direct owner messages in Claude Code session.

Private app state goes in `~/Library/Application Support/<bundle id>` (Apple guidance); the rebuildable memory index goes in `~/Library/Caches/<bundle id>`. The user-owned Markdown memory lives in the visible `~/Yorozu/memory`. No migration code in the app at this early stage; the owner's existing data was moved once by hand.

## 2026-10-08 — No boilerplate acknowledgments
Source: direct owner message in Claude Code session.

The main agent must not say things like "I'll work on that in the background" or "You can keep talking here". This supersedes the brief-acknowledgment part of the 2026-10-07 16:51 decision. Delegation posts no acknowledgment message; a native toolbar progress indicator shows running work and the final result still arrives in the timeline. Other app-generated notices (steer, stop, failure) are kept short and factual. App-generated acknowledgments and failures are not fed into the secretary's context.

## 2026-10-08 — The app does generic actions itself
Source: direct owner message in Claude Code session, after a worker answered "merge it and restart the app" with manual steps.

Workers do what the user asks end to end, including commit, merge, push, rebuild and restart the app, instead of handing manual steps back. Asking is reserved for what only the owner can do (logins, approvals, secrets). This refines the earlier "commit/merge/push only on explicit owner words" proposal: an explicit request in the chat is that permission. Unrequested destructive or outward-facing actions still are not taken, the owner's uncommitted work is never discarded, and tests/CI on the projectx branch stay on hold.

## 2026-10-08 — Roadmap after R2
Source: direct owner messages in Claude Code session.

Order: R2 coding workers (built, being live-tested) → iOS client: iOS devices as client interfaces to the host Mac over an end-to-end-encrypted relay on Cloudflare Workers, like Yorozu v0.4.0/v0.5.0-beta, with the old Yorozu chat input UI, shipped to internal TestFlight as v0.6.0 → R3: cua (https://cua.ai) integration so Yorozu can operate the user's computer. This refines the 2026-10-07 16:25 roadmap ("R3: computer and browser use").

## 2026-10-08 — iOS relay and version
Source: direct owner message in Claude Code session ("Reuse relay. Let's use v0.6.0.").

The iOS client reuses Yorozu v1's end-to-end-encrypted Cloudflare Workers relay as a deployed service; new client and host code on this branch stays Swift. The release version is v0.6.0 (version.txt), shipped to internal TestFlight with the next build number above the installed and published v1 builds.

## 2026-10-08 — Relay may be updated
Source: direct owner message in Claude Code session.

Reusing v1's relay is not a constraint: if updating the relay system is the better design, update it. Engineering guard (not an owner requirement): v1 stable/beta clients still depend on the deployed relay, so changes must stay backward compatible or ship on a separate v2 route/worker.

## 2026-10-08 — Low iOS build numbers
Source: direct owner messages in Claude Code session ("I need the ios build to stay low, starting from 4"; then chose to ship 0.6.1 (4) and expire 0.6.0 (10127)).

iOS TestFlight build numbers stay low: per version, starting at 1 (owner corrected from 4) and ascending (Apple requires ascending builds within a version and allows reuse across versions, TN2420). Version 0.6.0 had already received build 10127, so the release ships as 0.6.1 (4) (uploaded before the switch to 1; the owner chose to keep it) and 0.6.0 (10127) is expired in TestFlight. Builds start at 1 from the next version.

## 2026-10-07 — Tests and CI on hold (logged late)
Source: direct owner message in Claude Code session, right after the `projectx` branch was created: "do not run any tests or any CI yet".

No tests and no CI for the `projectx` branch until the owner lifts it: no test scripts, no opt-in live test, no GitHub Actions added or triggered. Verification is compiling and running the app. This extends the 20:01 "Stop tests for now" entry to CI and makes it standing.

## 2026-10-07 — One dev app, rebuilt in place (logged late)
Source: direct owner message in Claude Code session: "after r2 implementation is done, run the app here. do not create new apps, just replace the current one."

The Mac app is one bundle, `build/Yorozu.app`, built as a proper Xcode/Tuist app and refreshed in place by `scripts/build_native.sh`, then launched on the host. No extra or staged app bundles.

## 2026-10-07 — Topic workers at full permission (logged late)
Source: direct owner messages in Claude Code session: "give it all the tools available by default." / "it as in the workers." / "workers have fulll"; the owner then removed the `tools` override from the OpenClaw `projectx` agent entry. Implemented in d257d83.

Topic workers run at full permission with OpenClaw's default tools (shell, files, web) instead of a restricted tool list.

## 2026-10-07 — Approved cleanup deletes (logged late)
Source: direct owner message in Claude Code session: "delete instead of just moving to trash".

Approved cleanup of build outputs and stale app copies deletes them with `rm -rf` once the list is confirmed, rather than moving them to the Trash, because the point is to free disk space.

## 2026-10-08 — Each TestFlight upload is the owner's call (logged late)
Source: working rule adopted after 0.6.0 took build 10127, a number the owner did not want (see "Low iOS build numbers"); not an owner quote.

An upload uses up its build number for good, so each TestFlight upload happens only when the owner asks for it.

## 2026-10-08 — App icon (logged late)
Source: direct owner message in Claude Code session: "I need you to use the new logo for the app". Implemented in f154d58.

Mac and iOS use v1's saved Yorozu Icon Composer mark, copied byte for byte from 1e2f1fba.

## 2026-10-07 — Native SwiftUI and a sub-chat popup (logged late)
Source: direct owner message in Claude Code session: "make sure to use native swiftui components as much as possible, and bundle with xcode properly (so that it has liquid glass, no need to check them tho). the side chat and side chat timelines should be a popup. these UI fixes should be implemented minimally. no tests, no uitests, just code implementations."

Sub-chats and their timelines open as a popup instead of the sidebar from the "Native R1 layout" entry, which this supersedes for sub-chats. Native SwiftUI components wherever they fit; the app is a proper Xcode bundle so it gets Liquid Glass. Implemented in 2dbab14 (toolbar popover).

## 2026-10-07 — Tuist and v1's identity (logged late)
Source: direct owner message in Claude Code session: "implement the use of tuist, instead of a hand-written PROJECTX.xcodeproj. also, we would need to update all PROJECTX specific inner-detail with what Yorozu's app used. so that it can be updated seamlessly."

The Mac project is generated by Tuist; the hand-written Xcode project is gone (a968aad). The app takes v1's bundle id, signing team, entitlements and name, so v2 installs as an update of v1 (2dbab14).

## 2026-10-08 — R3 computer use: prompt rules first
Source: direct owner message in Claude Code session: "A first".

Workers operate the Mac through the cua-driver MCP tools under rules in their prompts (approach A). A dedicated computer executor with its own lane comes only if collisions or timeouts show up. Consent, phone requests and the worker model stay on the status.md defaults.

## 2026-10-08 — Yorozu owns the MCP server list
Source: direct owner messages in Claude Code session: "make it so that Yorozu manages a list of MCP servers the agents can use. This way, harness can be switched without having to move around these kind of external tools.", then "1: a", "2: both. coding workers might be asked to do things using the browser, like app store connect.", "3: go with recommendation".

Yorozu keeps the list as data and harness adapters apply it; Yorozu must not become a harness, so it never starts servers or runs tool calls. For OpenClaw the app may write its own `yorozu-<name>` entries into `mcp.servers` (off for other agents) and switch them on per session. Thinking and coding workers both get the list. CuaDriver stays a separately installed app that Yorozu neither bundles nor starts; the owner assumes CuaDriver.app is installed with no MCP server registered.

## 2026-10-08 — Computer-use concurrency and the Claude Code gap
Source: direct owner answers in Claude Code session: "1: Ok 2: ok 3: ok", clarified as "1+2 now, 3 later", and "(a) Leave it" for Claude Code.

CuaDriver serializes physical input one call at a time but not whole sequences, and has no app or window reservation. Workers therefore get a per-run cua session label and a rule to check the effect before retrying a timed-out call. The approved secretary rule (steer a request for an app that running work already operates into that work) was dropped after review: the Engine only steers within the target task's topic, so across topics it fails or files the request in the wrong topic, and within one topic and executor the code already allows one active task. Cross-topic collisions wait for a Yorozu code lane of one, added only if collisions or timeouts show up. Claude Code coding workers stay without Yorozu's MCP servers (OpenClaw does not pass session tool settings to Claude Code runs); new coding work that needs an app or a browser goes to Codex unless the user names Claude Code, and continuing work keeps its executor.

## 2026-10-08 — Context budgets
Source: owner decisions recorded in issue #310 ("projectx: context budgets — topic-session compaction, prompt caps and memory limits"), Decisions section.

1. Compaction of thinking topic sessions. Before each thinking task Yorozu reads the session's token count (`sessions.describe`, `totalTokens`). At about 50% of the usable window (about 129k of 258.4k), it calls `sessions.compact` as its own step, outside the 240 s task. This replaces the earlier "compaction later" decision.
2. Notices. A compaction is noted in that topic's sub-chat. A failed compaction posts a short failure notice in the main timeline.
3. Model window. Set `contextWindow: 272000` for `openai-pool/gpt-6-sol` and `openai-pool/gpt-6-astra` in the OpenClaw config (the owner's global file, approved).
4. Model roles. The secretary and memory extraction move to `gpt-6-sol`. Thinking workers stay on `gpt-6-sol`. The one stronger routing review moves to `gpt-6-astra`. This closes the "model per role" open item.
5. Coding sessions. Claude Code and Codex keep compacting their own sessions. Yorozu detects a compaction (the session id changes), notes it in the sub-chat, and gives overflow failures a clear error.
6. Note history. Past versions stay in the note until it would exceed its cap. Then the oldest move to a per-note history file (`<memory root>/history/<id>.md`) that search and rebuild skip. Nothing is lost.
7. Stale uncertain tasks. When a new request is blocked by an uncertain task, Yorozu reconciles its run. A run confirmed stopped is retired with a notice and the new work starts. A completed run delivers its result. A run that is still running or unknown keeps blocking, and the user is told why, so no run is duplicated. A dismiss action is for the UI work.
8. Message cap. It stays at 6,000 bytes. Long text is handled with attachments.
9. Untouched. OpenClaw's global `contextPruning` stays off.

Decision 1 supersedes the 2026-10-07 choice to keep growing sub-chat sessions and discuss compaction later.

## 2026-10-09 — Context budgets update
Source: owner comment on issue #310, 2026-10-09 (update from the owner's design session).

- No Yorozu-level size limit on worker output. Yorozu no longer caps or cuts what thinking and coding workers return. The UI renders any length, and long results travel to the phone in chunks. The secretary and memory extraction still get excerpts of results, sized by their own budgets. Removing the existing caps is batch 2 of issue #310, or the UI issue if batch 2 has not landed by then.
- Model roles get smart defaults, computed from the harness's model metadata with no hard-coded model ids, each overridable in Settings › Advanced: secretary and extraction take the cheapest allowed model with enough window and output cap; workers take the harness agent's primary model, else the most capable (highest-priced) one; the stronger review takes the most expensive allowed model that differs from the secretary's. This supersedes the fixed assignment in decision 4. Decision 3 stays. For batch 1, the stronger routing review gets its own model setting and today's default ids stay.
- Coding executors come from the harness. Where decision 5 and the coding items say Claude Code and Codex, read "the coding executors the active harness offers". The Hermes adapter issue renames the hard-coded executor values and applies decision 1's compaction to Hermes's own compaction, at the same threshold.
- The dismiss action for stale uncertain tasks (decision 7) is tracked in the future-topics issue, not in the UI work.
