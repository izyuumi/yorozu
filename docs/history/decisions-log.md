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

Worker delivery/acceptance is not proof of implementation; see TASKS.md and test evidence for current status. [TASKS.md and docs/TEST_EVIDENCE.md were removed; current status is [docs/status.md](secretary-status.md), and earlier versions are in git history, for example at f154d58.]

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

## 2026-10-09 — Context budgets batch 2: implementer readings (not owner decisions)
Source: the batch 2 plan comment on issue #310, taking the three open questions of the 2026-10-09 owner update at their proposed defaults. The owner has not answered them; [status.md](secretary-status.md#open-items) keeps them as open items, marked as defaults taken.

- The "Worker contract" item is split: the tool-output rules (offset and limit for file reads, head, tail or grep for long output, `list_windows` / `get_window_state` for the named app) stay in both worker contracts, and the answer-length rule goes. They limit session growth, not answer size.
- Today's model ids stay until the Settings issue, with no interim assignment, although the secretary's 8,192-token output cap can still cut extraction JSON (finding 13).
- Final answers are read whole, but not by raising `chat.history` `maxChars` to its 500,000 maximum as the update's checklist says. The Gateway drops a message over 128 KiB from `chat.history` whatever `maxChars` is, and keeps only the newest messages within 512 KiB per response, so a 500,000 read can lose exactly the long answers this decision is about. Yorozu reads small previews and fetches a truncated reply whole with `chat.message.get` (up to 1,000,000 characters per text field). Past that method's own limits the Gateway's marker shows as is, which is the proposed default's intent.

With batch 2 the "no Yorozu-level size limit on worker output" decision is implemented: the 64,000-byte answer checks and the 60,000-character coding cut are gone.

## 2026-10-09 — UI: menu-bar host and the UI pass
Source: owner decisions recorded in issue #311 ("projectx: UI — menu-bar host, Claude Design pass, …"), Decisions section.

- Host: the Mac app is menu-bar-only. Its icon opens a compact popover with the main timeline and the composer; the Mac has no sub-chats. The iPhone is the main full client (sub-chats, controls, jobs). The Mac stays the single source of truth, is assumed always running and keeps running when its UI closes. Settings is a standard macOS Settings window (SwiftUI `Settings` scene, ⌘, and the menu-bar menu); its contents are #312. This supersedes the 2026-10-07 window layout with a toolbar sub-chat popup, and the 2026-10-08 toolbar progress indicator moves to the menu-bar icon and the popover header.
- Look: the system look on both apps (native backgrounds, Liquid Glass bars, the vermilion accent, bubbles in system materials), designed in Claude Design, mockups first, before UI code.
- Results: stored without the `Regarding “…”:` prefix; a quoted, tappable reply header is drawn from `replyTo` at display time; Copy copies only the answer; old results keep their prefix. This replaces "names the request it answers" from 2026-10-07.
- Notices: compact system rows with an icon, visibly distinct from answers; failures in plain language with a Details disclosure (also in Copy diagnostics, #312); new notices stored as a code plus parameters and rendered in the user's language.
- Time: day separators, the exact time on hover (Mac) or long-press (phone), and "sent … · delivered …" on delayed messages.
- Search everything on both devices: ⌘F in the popover, a search field on the phone; the Mac searches its full history with an SQLite FTS index and the phone sends queries over the relay; a hit jumps to the message in context.
- Scrolling: the view stays put while reading, a "↓ N new" pill appears, and sending jumps to the bottom.
- Length: no size limit on worker output, rendered in full with code blocks (horizontal scroll, Copy), real tables, rules and inline images, no "Show more", lazy layout for very long text; long results travel to the phone in chunks; the secretary and extraction keep excerpts. This reverses the #310 batch-2 items "output caps stated to workers" and "coding results cut by bytes".
- Live progress: the native WebSocket transport becomes the default, with a one-time device enrollment during onboarding (#317). Tool rows show the real tool behind `tool_call` (tool id and target, never arguments), for example "cua: type_text in TextEdit".
- Mac attention: a menu-bar dot plus macOS notifications for results, failures and questions; a tap opens the popover at that message; both can be switched off in Settings; a destination setting chooses this Mac, phones, or later a Mac client.
- Global shortcut: opens the popover, preset ⌥Space, off by default, set in Settings › General.
- Phone: a long-press menu with Copy, Share and Show details; a draft over 6,000 bytes shows a hint and offers "Send as text file" (also on the Mac); an empty state with an example; Send always works (outbox).
- Smart Enter is the default: Enter sends a single-line draft; with more than one line Enter adds a newline and ⌘Enter sends; a "⌘Enter to send" setting makes Enter always add a newline. Mac popover and hardware keyboards on iPhone and iPad; the on-screen keyboard keeps its Send button.
- Languages: interface text in English and Japanese on both apps; the Mac gets a string catalog.

## 2026-10-09 — UI phase A: implementer readings (not owner decisions)
Source: the plan comment on issue #311, taking three of its open questions at their proposed defaults. The owner has not answered them; [status.md](secretary-status.md#open-items) keeps them as open items, marked as defaults taken.

- Sub-chat gap (open question 1): the Mac sub-chat UI is removed now, although phone sub-chats arrive only with #313; the data stays in the store.
- Native transport not enrolled or not reachable (open question 2): that launch falls back to the CLI transport with a one-line notice and "Connect…"; the composer is never blocked for it.
- What counts as a question (open question 5): routing questions are stored as kind `question` with a question notice code instead of `failure`; the secretary's `clarify` replies stay `conversation` with notice code `question`.

## 2026-10-09 — Settings window and config.toml
Source: owner decisions recorded in issue #312 ("projectx: Settings window and config.toml …"), Decisions section.

- Layered settings: sections for everyone, plus an Advanced section behind a toggle.
- Settings file: settings live in `config.toml` in Yorozu's data folder (Application Support), which keeps them separate from v1 by construction. Environment variables still override for development. TOML comes from a small SwiftPM dependency (the default) or a minimal parser.
- MCP servers: the list moves into `config.toml` as `[mcp_servers.<name>]` tables (`command`, `args`) and replaces `mcp-servers.json`.
- Models per role: editable in Settings › Advanced, with pickers filled from the harness's allowed models. Smart defaults are computed from harness metadata with no hard-coded model ids: secretary and extraction take the cheapest allowed model with enough window and output cap; workers take the harness agent's primary model, else the most capable (highest-priced) one; the stronger review takes the most expensive allowed model that differs from the secretary's. Defaults are recomputed at launch when there is no explicit choice; the rule inputs are configurable in `config.toml`, and explicit choices always win. This supersedes the fixed role assignment in #310 decision 4; that issue's `contextWindow: 272000` change stays.
- Self-configuration by chat: workers edit `config.toml` directly and the app watches and reloads it. An invalid edit keeps the last valid config and posts a notice. Security-relevant settings need the user's yes in the chat first (a prompt rule): the MCP servers, relay URL, direct connection, harness choice and Advanced items.
- Storage section: the memory folder and the files folder, with Show in Finder and sizes. No in-app memory view.
- Settings window: a standard macOS Settings window (SwiftUI `Settings` scene), opened with ⌘, and from the menu-bar menu, with tabs General (start at login, keep Mac awake, notifications, appearance, YOLO, send key, global shortcut), Devices (paired phones with names, online or last seen, remove; Pair iPhone lives here and mints a code only when pressed), Connection (relay status, relay URL, direct-path diagnostics), Storage and Advanced.
- Relay URL: editable in Settings › Connection, with a warning that all phones must pair again.
- Advanced: transport, Gateway URL (loopback only) and dev repo path are editable; run mode, data folder and agent id are read-only; native-transport enrollment lives here.
- YOLO mode: off by default, offered during onboarding and switchable in General. It lifts the "ask first" rules for outward-facing steps the user requested in apps and for the risky cua tools. Settings changes and unrequested actions still need the user's word. Hard limits always hold: no secrets, never take focus, never touch other agents' sessions.
- iPhone Settings gains a Connection section: Direct connection toggle, diagnostics (path, last error), relay host, Mac key fingerprint, paired since, Mac and phone versions, and Copy diagnostics. Remove host and Repair also remove the old record on the Mac.
- Owner-specific values move into `config.toml` with generic defaults in code: the routing hints (`personal_knowledge`, `self_topic`), the dev repo path and the relay URL. This generalizes the 2026-10-07 rule that the app's own work stays under one PROJECTX topic to the topic `self_topic` names. The Mac signing identity becomes a local, gitignored build setting; git history is left as it is.
- Start at login is on by default, and onboarding says so.
- Notification destination: the user chooses where notifications appear: this Mac, phones, or later a Mac client.
- Phone names (default): phones are named by model ("iPhone 17 Pro") and can be renamed on the Mac; iOS hides the user-assigned device name without a special entitlement.
- Ownership of later pieces: the YOLO choice and start at login are onboarding steps in #317. Device management is #312's, not #313's.

## 2026-10-09 — Settings phase A: implementer readings (not owner decisions)
Source: the plan comment on issue #312, which splits it into phase A (`config.toml`, core, harness, app wiring, signing and the devices backend) and phase B (the Settings tabs, the iPhone Settings › Connection section and Copy diagnostics, after the owner approves the Claude Design mockups), and takes the issue's open questions 1–13 at their proposed defaults. The owner has not answered them; [status.md](secretary-status.md#open-items) keeps the ones that matter as open items, marked as defaults taken.

1. `config.toml` sits in the data root in use, so fixture and `PROJECTX_DATA` runs get their own file.
2. Yorozu rewrites the whole file in a canonical layout with its own comment per key; hand-written comments are not kept, unknown keys are kept as data, and Settings writes are read-modify-write.
3. A model without a price or output cap is left out of the cheapest and most-expensive picks; with no priced model every role falls back to the agent's primary model. Price and output cap come from the read-only `config.get` (`models.providers.<provider>.models[]`), because `models.list` carries neither.
4. Rule inputs: `min_context_tokens = 32000` and `min_output_tokens = 16000`; a model's price is input plus output price per million tokens.
5. Each coding executor's automatic model follows the worker rule among allowed models its runtime can run.
6. A changed model reaches existing topic, controller and coding sessions at their next use through `sessions.patch`, never by re-creating them.
7. The worker default on the owner's machine would move to the agent's primary model; the owner checks the computed values. Meanwhile the owner's local `config.toml` sets the model ids in use before #312.
8. `yolo` counts as security-relevant, and every security-relevant change written to `config.toml` posts "Settings changed: <keys>".
9. The Advanced tab appears only while "Show Advanced settings" is on, and shows the MCP list read-only with Show `config.toml` in Finder (phase B).
10. Generic routing defaults: `personal_knowledge = ""`, which drops the clause, and `self_topic = "Yorozu"`; the relay URL default stays the hosted relay.
11. An empty `dev_repo` ends coding work with a plain notice ("Set a repository in Settings › Advanced"); the owner's local file sets it.
12. The phone sends its model name in the existing optional `computerName` of its peer-info claim, so 0.6.x stays wire-compatible and old phones show as "iPhone".
13. A phone is online while it has an authenticated session on the current relay connection; last seen is the time of its last authenticated frame.

Added in implementation: a model whose cost is 0 for input and output, as a local proxy may declare, counts as unknown price, not free, so it never wins the cheapest pick by accident.

## 2026-10-09 — Phone sync and control over contract 0.7
Source: owner decisions recorded in issue #313 ("projectx: phone sync and control over the 0.7 relay contract"), Decisions section.

- Fix both the reliability gaps and the missing capabilities, reliability first.
- The phone is a mirror with control. The Mac is the only source of truth. The phone sees what the Mac knows (sub-chats, worker progress, topic status) and can control work.
- Clean break to contract 0.7 for v2's own phones. The Mac speaks only 0.7; a 0.6.x phone gets a clear "Update Yorozu" through the peer-info handshake. New events travel inside the existing end-to-end-encrypted envelope, so the deployed relay does not change. Keep the thread id field and never hard-wire `"main"`, because multiple threads come later.
- Encrypted phone cache of recent history: the last ~500 messages or 30 days, protected by iOS file protection. Catch-up continues from the cursor. Older history may load from the Mac on scroll later.
- A newly paired phone gets the same recent window, not the whole history.
- Sub-chats on the phone, like the Mac popover before #311: the topic list shows each topic's status, and each topic opens an inspect-only timeline (messages, each task's instruction, executor and state, amendments, worker events and results) with iPhone navigation and activity collapsible per task.
- Per-task Stop (running) and Retry (failed or uncertain) buttons in the phone's sub-chat, acting directly through the Engine without the secretary. This amends "sub-chats are inspect-only" (2026-10-07), but there is still no typing in sub-chats. The Mac loses its sub-chats in #311, so the buttons exist only on the phone; on the Mac work is stopped by typing. The long-term goal is typed control reliable enough that the buttons become unnecessary.
- "Thinking" indicator: a typing-style bubble in the main timeline while the secretary routes, on both devices. The global working spinner stays. Per-topic status lives in the sub-chat list. While disconnected, the phone shows "status unknown", never "idle".
- Read state synced: one "last seen message" cursor held by the Mac, and an unread marker or divider. Reading on one device clears it on the other. The cursor also feeds a future push badge (#320).
- Device management moves to the Settings issue (#312).
- Workers always treat the Mac as unattended: they never take focus and never use foreground input, whichever device the request came from. No model ever learns which device a message came from: secretary and worker inputs carry no origin. This replaces the earlier worker prompt rule that allowed a focus-taking step the user approved.
- The menu-bar host keeps running when its window closes. Start at login and keep-awake live in Settings (#311, #312).
- Connection status: after a return from the background, and on a fresh launch, show the last known status for 3 seconds while reconnecting (relay or direct), then the real status. Message marks are never faked.
- Must-fix bugs: (1) the Mac must keep and process relay-replayed frames that it acked but dropped; (2) messages stored but never routed before a quit are processed on the next launch, if they are less than 24 h old.
- Decided in #312, built here: Remove host and Repair on the iPhone also remove the old record on the Mac.
- Decided in #311, phone side built here: search everything on both devices; the phone searches the main timeline and sub-chats over the relay and the Mac runs the query over its full history. Notices render as system rows from a code and parameters in the user's language, and results get a reply header drawn from `replyTo`. The menu-bar dot follows the synced read cursor.

## 2026-10-09 — Phone sync PR A: implementer readings (not owner decisions)
Source: the plan comment on issue #313, which splits it by whether a change touches the wire, because a 0.7 Mac stops the owner's 0.6.1 phone: PR A (reliability and core, still on the 0.6 wire, branch `sync-reliability`), PR B (contract 0.7 and iOS, left open until the owner chooses when the Mac moves to 0.7) and PR C (the visual parts, after the owner approves the #311 mockups). It takes the issue's open questions 1–7 at their proposed defaults. The owner has not answered them; [status.md](secretary-status.md#open-items) keeps them as open items, marked as defaults taken where PR A uses them.

1. History window bound: the union, that is the newest 500 messages plus anything younger than 30 days (`Store.changes`).
2. A stored, unrouted message older than 24 h at launch is not routed. It gets one short failure notice (`closed_too_long`) that replies to it and says Yorozu was closed for more than 24 hours, so the user should send it again if it still applies.
3. A message whose routing started but did not finish before a quit is left alone; only never-started messages (`readAt` unset) are routed at launch.
4. Stop and Retry controls post the same acknowledgments and failures a typed stop or retry produces, filed in the task's topic and replying to the task's original message. No user message is created. The phone's buttons work only while connected and their events are never queued or resent (PR B).
5. What counts as seen: on the phone, the newest message on screen while the app is active and the chat is shown; on the Mac, the newest message shown while the popover is open. The user's own messages never count as unread, and the cursor only moves forward (`Store.markRead`; the devices' part is PR B and C).
6. Loading older history on scroll is not in #313. A search hit outside the cache still loads its surrounding page (`Store.page(around:)`).
7. Remove host or Repair while the phone cannot reach the relay: the phone removes its pairing anyway, and the Mac's record stays until it is removed in Mac Settings (#312).

Added in implementation:
- Messages from builds before `readAt` that already got a reply, a topic or work count as routed even when `readAt` is unset, so a downgrade and upgrade never routes them again.
- A failed Stop or Retry control that has no notice code of its own posts `task_control_failed` with the raw error in `params.error`.
- The 0.6 wire has no error page, so a `sync_request` the Mac cannot answer gets an empty final page: the phone's catch-up ends, its cursor stays, and its next `.paired` asks again.
- A failed snapshot read no longer ends the poll loop: the status line says so and the poll backs off from 0.7 s, doubling to 30 s, until a read succeeds.

## 2026-10-09 — Hermes Agent harness and harness-provided coding executors
Source: owner decisions recorded in issue #318 ("projectx: Hermes Agent harness adapter and harness-provided coding executors"), Decisions section.

- Stack (H1): Hermes Agent (Nous Research, MIT, Python) is allowed as an external, separately installed harness, like OpenClaw (Node). The adapter is Swift inside Yorozu and talks HTTP: no Python in the repo, no Rust and no separate Yorozu process. The stack decision is reworded to "a Swift client that drives separately installed harnesses (OpenClaw, Hermes Agent)". Yorozu still never becomes an agent harness: it never runs MCP servers or tool calls itself.
- One main harness (H2): one at a time, detected and chosen in onboarding (#317) and switchable in Settings. Switching keeps Yorozu's data; topic workers start fresh on the other harness. Several harnesses at once is future work (#322), linked to multiple threads, where a thread is bound to a harness.
- Interface (H3): Hermes's gateway HTTP API (`127.0.0.1:8642`, an API key of at least 16 characters, `/api/sessions`, `/v1/runs` with stop, steer and approval, SSE events, idempotency keys). Runs survive Yorozu restarts and are reconciled. ACP is a candidate for a future generic adapter. Each harness and each integration declares its own detection. Remote harnesses (e.g. over SSH) are future work.
- Coding executors (H4): each harness decides how coding is done and its adapter advertises its coding executors: Claude Code and Codex for OpenClaw, whatever Hermes is configured to do for Hermes. The secretary's policy is built from that list, so "use Codex" works only if Codex is offered. Harness-specific rules move into the adapters: "coding that needs an app goes to Codex" becomes an OpenClaw-adapter rule, because OpenClaw does not pass Yorozu's MCP servers to Claude Code. The coding contract stays Yorozu's. The `claude`/`codex` values baked into Engine, Store and UI become names the harness provides.
- Profiles (H5): Yorozu owns two dedicated Hermes profiles and writes only their config: `yorozu-worker` (default tools, Yorozu's MCP servers, a working folder) and `yorozu-roles` (secretary and extraction, no tools). Hermes's own memory, background self-review, skill creation and cron are off in both. The user's own profiles stay untouched; the user installs Hermes and configures providers.
- Defaults (H6, accepted):
  1. Roles run in `yorozu-roles` as fresh one-shot runs. The routing replay (21 real messages) is redone on Hermes before Hermes can be main. The serving model is verified on every run, and a fallback model fails closed.
  2. One session per topic (`yorozu-<topic id>`). Runs are keyed by Yorozu run ids. Live progress comes from SSE, and steering is live.
  3. Workers run at full permission. Hermes's per-step approvals are off in `yorozu-worker`. The "ask first" rules and YOLO mode stay in Yorozu's prompts.
  4. Providers and keys are configured in Hermes. The gateway API key is generated at setup, written to Yorozu's profile config and kept in the Keychain.
  5. Integrations' MCP servers are written into the `yorozu-worker` config.
  6. #310 compaction maps onto Hermes's compaction at the same threshold, and the same session id continues.
  7. OpenClaw and Hermes may both be installed. Yorozu records the Hermes versions it was tested with and warns on untested ones. Yorozu never updates Hermes.
- Binding from related issues: the harness choice and the MCP list live in `config.toml`; changing the harness is security-relevant, so a worker asks for the user's yes first; role models get smart defaults from harness metadata (#312). Assisted setup writes only Yorozu's own entries; installs and logins stay manual (#317). Yorozu sets no output caps of its own (#311). Yorozu runs scheduled jobs itself, through the active harness (#319).

## 2026-10-09 — Hermes adapter: implementer readings (not owner decisions)
Source: the plan comment on issue #318, which builds the harness seam, the Hermes adapter and the profile writer on branch `hermes-adapter`, against Hermes's documented API at v0.21.6, verified by compiling only because Hermes is not installed on the host. It takes the issue's open questions 1–9 at their proposed defaults. The owner has not answered them; [status.md](secretary-status.md#open-items) keeps them as open items, marked as defaults taken.

1. Serving the profiles: Yorozu's profiles are served under multiplexing at `/p/yorozu-worker/` and `/p/yorozu-roles/`, which needs the default profile's API server on. Setup checks this read-only and shows the exact commands; Yorozu never edits the default profile.
2. Coding on Hermes: one executor, `hermes` ("Hermes"), Hermes's own agent loop in `yorozu-worker`. With no per-session working folder, the coding contract has the worker create its own worktree and branch from the dev repo's base branch and work only there. Claude Code and Codex are not offered through Hermes's bundled skills or its Codex runtime.
3. `terminal.cwd` of `yorozu-worker` is `dev_repo` when set, otherwise the home folder.
4. Profile keys are written with Hermes's own `hermes -p <profile> config set`; `SOUL.md` and `.env` are written directly. No YAML library.
5. Both profiles get `auth.adopt_external_logins: false`; no MCP server is marked `trust: untrusted`; the setup docs recommend installing Hermes with `--skip-computer-use`.
6. An unexpected `approval.request` is answered `deny`, the run is stopped and the step fails with a plain error.
7. A crash between `POST /v1/runs` and its response stores no body: the work becomes `uncertain` and the watch and reconcile path takes over.
8. No coding diffstat under Hermes.
9. A harness switch applies only when no work is active or uncertain; until then the app stays on the previous harness and says so. Switching back to a harness used before resumes its earlier topic sessions.

Added in implementation:
- A Hermes run's controller key is `hermes:<Yorozu run id>:<server run id>` once Hermes answers, or `hermes:<Yorozu run id>:refused` when Hermes refused the run outright, so nothing ran and reconcile reports it stopped. Yorozu's run id is the `Idempotency-Key`.
- The `skills` toolset is disabled in both profiles together with `cronjob`, because Hermes 0.21.6 has no separate switch for skill writes; the curator is off too.
- Sessions are created with `source: "yorozu"`, which Hermes 0.21.6 stores as `api_server`, since it keeps only its own source names.
- The serving-model check is an exact match of `runtime.provider` and `runtime.model` against the pair requested.
- `GET /api/model/options` carries prices but no context window or input kinds, so Hermes models have no window for the automatic choice and the compaction threshold falls back to 129,200 tokens.
- The data folder is bound to the run mode (live, fixture) instead of the harness's display name; the old OpenClaw and fixture names read as their mode, so existing data opens without a migration.

## 2026-10-09 — Scheduled jobs run by Yorozu
Source: owner decisions recorded in issue #319 ("projectx: Cron jobs run by Yorozu (jobs.toml, one topic per job, scripts and AI steps)"), Decisions section.

- Runner: Yorozu is the runner, with its own scheduler in the Mac app. Work runs through whichever harness is active. Users create, edit, customize and remove jobs in natural language.
- Storage: job definitions are data in `jobs.toml`, next to `config.toml`. The file can be edited by hand, by a worker, or through Settings and the UI. The app watches the file and validates it.
- One topic per job: each job has its own topic, a sub-chat plus a persistent worker session, so runs build on each other. When the user talks about a job in the main chat, the message is routed to that job's agent.
- Schedules are time-based: intervals, calendar rules and one-shots. A one-shot retires after it runs. All are stored as cron expressions and evaluated by Yorozu's own scheduler, never by the system `cron`. The time zone follows the Mac. Condition watchers come later.
- Always running: the Mac app is assumed always running. There is no missed-run handling.
- Posting: the user decides per job whether results always go to the main timeline or only when they are notable; if the user did not say so when creating the job, the job's agent asks. The full output of every run stays in the job's sub-chat.
- Three forms: a pure script (no AI), an AI task, or a script whose output goes to an AI step (for example only when the output changed or matches a condition). AI is always optional.
- Scripts: Yorozu runs them itself as child processes, like cron, as the user's account, in `~/Yorozu/jobs/<job>/`, with a timeout, their output captured to the sub-chat. Script runs do not depend on the harness. A new or changed script needs the user's yes in chat, even in YOLO mode.
- Jobs list: the phone and Mac Settings each get one. Each row shows the name, the schedule in plain words, the next run and the last result, with Pause/Resume, Run now and Delete. Tapping a job opens its sub-chat.
- Spec and summary: each job has an exact spec in `jobs.toml` (schedule, script, instruction, posting mode); a user-facing summary is generated from it and kept in sync.
- Job input: each job's screen has an input that talks directly to that job's agent, with no secretary routing; the conversation stays in the job's sub-chat. Sub-chats of other topics stay inspect-only. This is an exception to "one main timeline is the only place to type".
- Defaults (accepted): AI runs use the job topic's thinking worker on the worker model, and a job can be told to use another model or executor. Runs never overlap: while the previous run is still going, the next slot is skipped and a note is added. Failed runs count as notable. The script timeout is 10 minutes by default and can be changed per job.
- OpenClaw automations (`openclaw automations` / `cron`) are reference material only; Yorozu does not use them.

## 2026-10-09 — Jobs phase A: implementer readings (not owner decisions)
Source: the plan comment on issue #319, which builds phase A (core, scheduler and app wiring) on branch `jobs` now, because it does not need contract 0.7: the job wire events (`job_list`, `job_control`, a message to a job) follow #329, and the Jobs list and job screens on the Mac and the phone follow the #311 design approval. It takes the issue's open questions 1–16 at their proposed defaults. The owner has not answered them; [status.md](secretary-status.md#open-items) keeps them as open items, marked as defaults taken.

1. A yes to a script is recorded by Yorozu against the script's SHA-256 in its own database, never by a worker. The request is a message in the main timeline and the job's sub-chat; pending approvals go to the secretary as data; the secretary action `approve` (with the approval id) counts only for a user message sent after the request and only for that exact hash. In a job's own input, one raw secretary-model check runs while an approval for that job is pending.
2. A new job's topic: the secretary delegates "create a job" with `newTopic` set to the job's name, and the worker writes `topic = "<its topic id>"` into the new entry. An entry without `topic` gets a new topic named after the job. The binding lives in Yorozu's database.
3. Notable without AI: a script-only run is notable when it failed (non-zero exit, timeout, launch error) or its output differs from the previous run's. An AI run is notable when its answer says so (it is asked to mark answers that ask the user something or report a failure), or when it failed.
4. The gate before an AI step: `ai_when` is `always`, `changed` or a regular expression the output must match; closed, the run ends after the script.
5. Posting before the user answers: `always`.
6. Script environment: `HOME`, `USER`, `LANG`, `TZ`, `YOROZU_JOB`, `YOROZU_JOB_DIR` and `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`; never `PROJECTX_*` or app secrets.
7. Intervals one cron line cannot express: `schedule` is a list of cron expressions, and a slot fires when any matches.
8. Late slots: a slot reached more than 60 s late is skipped silently and the next one is computed from now. A local time a daylight-saving change skips is skipped; one that repeats runs once.
9. A run left `uncertain` by a restart blocks later slots, which are skipped with a note until the user retries or stops it; the Jobs list will show "Needs attention".
10. Work the user sends goes ahead of queued job runs in the lanes. Job runs do not count toward the 32-item send cap and do not turn on the main working indicator.
11. Only job results posted to the main timeline go through memory extraction.
12. A message typed in the job input while the job's AI run is active waits, then runs as the next turn in the same session.
13. Delete removes the entry from `jobs.toml`; the topic, its history and the job folder stay. The confirmation belongs to the UI (not yet built).
14. The job sub-chat on the Mac will be the detail pane of a Settings › Jobs tab, with the job input (UI not yet built).
15. The summary lives in Yorozu's database, keyed by the spec's hash; a changed spec gets one raw run on the secretary model. "Next run" is computed exactly.
16. The scheduler runs in live and fixture mode, each on its own data root; fixture AI steps get scripted replies; offline mode lists jobs and runs none.

Added in implementation:
- A message typed in a job's input is stored as kind `job_input`, not `conversation`, so the main timeline, phones, the secretary's context, `latestTopic` and memory extraction never see it; the job's worker gets it in its history like a conversation message. Its answer is a `job_result` that stays in the sub-chat.
- The hidden kinds `job_run`, `job_input`, `job_result` and `job_note` are filtered out where the main timeline is built: the Mac's main chat and, since contract 0.7 (PR B of #313), every record `EngineBridge` sends to phones (live updates, catch-up and page replies; the skipped ones leave gaps in `seq`, which the cursor passes) and phone search. Skipped-slot notes and a `jobs.toml` problem that one job's entry causes are `job_note`s in that job's sub-chat.
- The working indicator (Mac spinner, menu-bar icon, the phones' working flag) leaves out work in job topics, recognised by the topic ids bound in the `jobs` table, deleted jobs included. On 0.6 phones got no job-topic work; on 0.7 the task records of job topics travel like any topic's, and only the flag leaves them out.
- Scripts run with `/bin/zsh -f`, so `~/.zshenv` cannot add to the environment of open question 6.
- `model` is parsed and validated but not yet applied to the AI step, which runs on the worker model; per-job models are a TODO. A job's `executor` is used when the active harness offers it ready.
- Approval requests are their own message kind, `approval_request`, filed in the job's topic and shown in the main timeline.
- A one-shot retires only once a run actually starts; a slot skipped for approval or overlap leaves it armed.
- The skipped-slot note is posted once per streak with the same reason, so a job skipped every minute does not flood its sub-chat.
- The output hash is the SHA-256 of the two streams' own hashes, so stdout and stderr interleaving never makes a run look changed.
- At quit, running scripts get SIGTERM and 2 s before SIGKILL (the timeout and Stop keep 5 s), so the app can exit promptly.
- A script still running when the app quits ends as interrupted, never failed: its work and run are left for the next launch.
- A script run ends when its leader process exits, not when its output pipes close; the rest of its group is then killed, and a child that left the group is abandoned after 2 s. A timeout counts only when it fired before the leader exited.
- The sub-chat gets the first 2 MB of a run's output; the log keeps all of it.
- One topic per job: an entry's `topic` already bound to another job is ignored.
- A slot runs the Engine's current definition of the job; a scheduler copy that differs from it skips the slot.
- A coding executor's answer is notable only when it carries `"notable": true`.
- A queued script step found at launch is failed, not started; a stamped one becomes `uncertain`, is never re-run and gets a `job_interrupted` notice. Retrying it starts a new run of its job.

## 2026-10-09 — Phone sync PR B: implementer readings (not owner decisions)
Source: PR B of issue #313 (contract 0.7 and iOS, branch `sync-07`). These are readings of the owner's #313 decisions and the plan comment where they leave a detail open; the wire is in [ios-relay-contract.md](../ios-relay-contract.md).

- Versioning: 0.7 is protocol 2 and `version.txt` 0.7.0. A protocol mismatch names the side to update: the Mac tells a 0.6.x phone "Update Yorozu on this iPhone to talk to this Mac.", and a phone that computes the mismatch itself reads "Update Yorozu on the Mac to talk to this iPhone.". Existing pairings carry over without pairing again.
- `device_remove` goes out on Remove host and on confirming any new pairing, which covers Repair and also a code for a different Mac: the old Mac forgets the phone either way. It is sent only while the link is `.paired`, gets no reply, and the phone wipes its pairing and cache whether or not it went.
- Records too large for 256 chunks are not skipped: the Mac keeps the head of their long text fields with "…(truncated; the full text is on the Mac)", leaving 64 KiB for the page around them. A page reply that would still not fit is an error page ("That part of the chat is too large to send.").
- The Mac always answers `sync_request` and `page_request`: an unreadable store or an unknown thread gets an error page, and the phone keeps its cursor and asks again. A live update whose store read fails sends nothing; the next poll retries from the same sequence with the flags unchanged. The first poll after launch only sets the starting sequence; phones catch up through `sync_request`.
- Pacing is one token bucket for all phones: 1 MiB of sealed frames (16/9 of the encoded event) and 30 frames a second, applied to chunk frames only. Anything else for a phone with frames waiting queues behind them so its order holds. Waiting frames are dropped when the relay socket drops or the phone is removed, since the phone catches up after it redials.
- Phone cache: one JSON file, `Application Support/Mirror/mirror.json`, with file protection `completeUntilFirstUserAuthentication` (the class of the pairing's Keychain item, so it can be written while the phone is locked in the background), excluded from backup, format version 1, keyed to the pairing's session key. It is written at most once a second and on going to the background, trimmed to the window by the phone's clock, and wiped with the pairing. Sent messages without a stored copy are not cached.
- Catch-up: a request without a reply page is sent again after 15 s while paired. A live update that skips past the cursor starts a catch-up at once instead of waiting for the next `.paired`. A `reset` page keeps sent bubbles that are still waiting for their stored copy.
- Connection status grace: the status shown on going to the background is saved in `UserDefaults` (`lastConnectionStatus`, the status and its time, no chat content) and shown for up to 3 s on return and on launch, or until the link is connected or failed. A link still `.paired` on return is not redialed.
- "Status unknown": off `.paired` the working and routing flags are unknown (nil), and the chat's status line reads "<status> · Status unknown". A Mac that refuses the phone shows "Update required: <reason>" in that line instead.
- The phone's `task_control`, `search_request`, `page_request` and `read_state` calls exist in `PhoneModel` for PR C and are sent only while `.paired`, never queued.

## 2026-10-09 — UI design approved
Source: owner approval recorded in issue #311 (the phase B plan comment).

- The owner approved the Claude Design mockups for #311, with one change: the menu-bar icon is the Yorozu logo, not the placeholder speech bubble. This approves the ten proposals in the mockup comment: one popover size of 420×744 pt; vermilion user bubbles, full-width answer cards and question cards with a "Question" label; amber, not red, for failures; no inline time on rows (hover or long-press); a header menu with Search, Settings… and Quit; the Settings tab list with "Notify on" defaulting to this Mac; the iPhone layout for sub-chats, jobs and search; newest-first sub-chat tasks with Stop and Retry capsules; and notification text without message content.

## 2026-10-09 — UI phase B: implementer readings (not owner decisions)
Source: the phase B plan comment on issue #311. The remaining open questions were taken at their proposed defaults; [status.md](secretary-status.md#open-items) keeps them as open items.

- Open questions taken at their defaults: notification text is fixed and carries no message content ("Yorozu replied", "A task failed", "Yorozu has a question"; 3); permission is asked the first time a notification would be posted, and nothing is posted while the popover is open and scrolled to the newest message (4); the progress and transport limits stay (6, 7); only local image files are drawn, remote ones stay links (9); ⌘F on the Mac searches the main timeline only (10); the issue closes when Part 1 is merged (11).
- The menu-bar icon draws the newer Yorozu mark, the two crossed loops around a center dot from the app icon (`apps/ios/Resources/AppIcon.icon`), as an 18-point template image. Working dims the center dot; attention cuts a notch in the top-right for a vermilion dot drawn over the template, so the logo still adapts to light and dark menu bars.
- The reply header looks up `replyTo` across all messages, not only the main timeline: a job result replies to its hidden `job_run` trigger, which stays in the sub-chat, and its header quotes that trigger ("Scheduled run of “…” for …"). Phones do not hold job triggers, so on the phone a job result has no header.
- The dot follows what the open popover has shown (from launch; older messages never raise it), not yet the synced read cursor of #313. Offline-mode failures raise neither the dot nor a notification.
- Notifications post only when `[notifications] enabled` is true and `destination` is `"mac"`; with `"phones"` the Mac posts none until push (#320). The dot has no switch.
- The global shortcut is a Carbon hot key, which needs no Accessibility permission. It is re-read from the config every 2 s, and an unrecognized or taken shortcut is reported in the status line.
- Job results drop the `Regarding “<job name>”:` header too, so `Store.finish` takes only the result kind.
- Native as the default: the native client holds only `operator.read` and `operator.write`, so each call that needs `operator.admin` (`config.patch`, `sessions.compact`, `sessions.create` or `sessions.patch` with `permissionMode: "full"` or `toolOverrides`, an `agent` run of `/new` or `/reset`) goes through the CLI, and everything else stays native so live events stream. The list mirrors OpenClaw's scope tables.
- "Send as text file" is not built: the over-limit hint asks the user to shorten the draft.

## 2026-10-09 — Settings phase B: implementer readings (not owner decisions)
Source: the phase B plan comment on issue #312, built on the approved #311 mockups.

- Copy diagnostics on the iPhone is plain English text whatever the interface language, so a bug report reads the same for anyone; the Settings screen around it is localized.
- The Jobs tab the mockups show is left to #319, with the job screens; jobs stay in the chat and `jobs.toml` until then.
- The General setup status row ("Run setup again…") and the coding opt-in switch are left to #317; Settings › Advanced has the dev repo picker, and an empty one still ends coding work with a notice. The harness choice is a read-only row for the same reason.
- The Settings window is 560 points wide (the shell was 500), so the grouped forms' subtitles fit without crowding; it is the one size the window owns.
- Design items not built: the Connection tab's direct-path diagnostics and the iPhone Direct connection toggle (#315), the Phones notification destination (shown, disabled, until #320), and a shortcut recorder: the global shortcut is a text field with the same syntax as `config.toml`.

## 2026-10-09 — Phone sync PR C: implementer readings (not owner decisions)
Source: the PR C plan comment on issue #313 (branch `mirror-ui`), built on the approved #311 mockups. These are readings where the decisions, the plan or the mockups leave a detail open; the UI is in [architecture.md](secretary-architecture.md#ios-app).

- Timeline order: a topic's messages and task cards run oldest first and open at the bottom, like the main timeline, rather than the mockups' newest-first tasks, so amendments, results and follow-up turns read in the order they happened.
- Duplicate results: a `result` message whose task card already shows that result is hidden in the topic, so the answer appears once; a result message without a matching card stays.
- A search hit outside the phone's cache opens a separate read-only "In context" screen with the Mac's page around the message (`page_request`), not a jump inside the cached timeline, since those messages are not in the mirror.
- Scope counts: All shows the Mac's `total`; Main and Sub-chats filter the hits loaded so far on the phone and count those, since the Mac returns one combined result per query.
- Retry stays 再試行 in Japanese, the catalog's existing translation.
- The unread divider stays where it was drawn while the user reads: on the Mac until the popover opens again, on the phone until another device moves the cursor or the app returns to the foreground. Reading moves the cursor right away; only the divider waits.
- The Mac's menu-bar dot follows the synced read cursor as well as what the open popover shows, forward only, so a phone reading a result clears the dot and its delivered notification.

## 2026-10-09 — Delivery marks and offline sending
Source: owner decisions recorded in issue #314 ("projectx: delivery marks, outbox and offline sending"), Decisions section.

- Marks on every user message, on the phone and in the Mac's chat: **Delivered** means the relay (or the Mac) has the phone's message; **Read** means the host Mac received it and started processing it, that is, routing started (`Engine.route`). A message typed on the Mac shows Delivered once stored and Read once routing starts.
- States only move forward: Sending, then Delivered, then Read. Not delivered follows the 24-hour deadline or a rejection; Resend moves Not delivered back to Sending.
- SF Symbols in the text colour (no blue), icon only: Sending `circle.dotted` (spins while a frame is in flight, still while waiting for a connection; the details say "Waiting for connection" or "Sending"), Delivered `checkmark.circle`, Read `checkmark.circle.fill`, Not delivered a red `exclamationmark.circle` with the reason, Resend and Delete. Tapping the mark opens details with each state's time. Final visuals come from the Claude Design pass in #311.
- The Mac records a read time per message in one new column; existing history is marked Read.
- Copy Signal's system, not its icon files (AGPL-3.0). VoiceOver reads the state as part of the bubble.
- While the Mac is unreachable the relay buffers messages (24 hours, 5 MiB per room, drained on Mac reconnect until acked); the phone does not need to stay connected. Late messages are delivered normally; the Mac timeline shows the delay ("sent 02:14 from phone, delivered 09:30") and the secretary is told the message's age, never its device. After 24 hours without delivery a message becomes Not delivered, with Resend.
- The phone keeps a persistent outbox. Going to the background with a non-empty outbox, it uses iOS background time to keep trying, then posts a local notification ("1 message waiting to send") for what is still unsent. When a message is delivered, the phone schedules a local notification for 24 hours later ("A message to your Mac expired without being read"); Read cancels it. Permission is asked the first time a message is queued. The draft clears as soon as Send is tapped.
- The relay replies `{"type":"accepted","sig":<frame sig>,"buffered":true|false}` after forwarding or durably buffering a phone frame. The owner reviews and deploys it after confirming the deployed relay matches `main`. A new phone on an old relay gets Delivered from the Mac's receipt instead.
- Shared with #313, built there: relay-replayed messages are never dropped and acked; messages stored but never routed before a quit are routed at launch when under 24 hours old; the 3-second last-known connection status.

## 2026-10-09 — Delivery marks: implementer readings (not owner decisions)
Source: the app-side plan comment on issue #314 (branch `receipts`, built as `rc-mac`, `rc-wire` and `rc-ios`), after the relay part merged on `main` in #332 and was deployed. The open questions were taken at their proposed defaults; the owner has not answered them, and [status.md](secretary-status.md#open-items) keeps them as open items.

1. The phone's send time is a second nullable column, `messages.sentAt`, in its own migration `receipts-sent-at`, set from the phone event's `ts` only for messages that arrive from a phone, and synced to the phone as the optional `MessageData.sentAt`.
2. A message is delayed when the Mac stored it more than 60 s after `sentAt` (`Message.delay`); the same rule drives the delay line and the secretary's age.
3. The secretary gets an optional `RoutingInput.messageAge` ("7 h 16 min", or "16 min" under an hour), only for a delayed message, plus one policy sentence: read "now", "today" and similar words from when it was sent, and mention the delay only if it changes the answer. It counts against the routing trim like the rest of the input. `sentAt` and `readAt` are stripped from extraction prompts and never reach a worker.
4. Notification permission (`.alert`, `.sound`, `.badge` in one request) is asked the first time a message has to wait in the outbox: sent while the relay is out of reach, or a send that fails.
5. The expiry notification runs 24 hours from Delivered, as decided, though the Mac's deadline runs from the send time.
6. A stored, unrouted message older than 24 hours at launch keeps #313's `closed_too_long` notice; the phone keeps showing Delivered.
7. #313's fix (a replayed frame is acked only once the Engine stored or refused it) is unchanged; the live checks cover it.
8. The Node relay mirrors `accepted`, with a conformance scenario, in the same PR on `main` (#332).
9. `readAt` and `sentAt` ship inside contract 0.7, since 0.7 had not reached a phone yet.

Added in implementation:
- An outbox item's mark is not stored in the item: marks live in a separate id -> state map, persisted in the same file, which applies the forward-only rule, because `merge()` replaces bubbles wholesale. Items hold the event, its send time, the relay's `accepted` time, `buffered`, whether the Mac has stored it and a refusal reason.
- A stored copy lifts Not delivered back to Delivered or Read without a Resend, since it proves the Mac has the message.
- On a relay without `accepted`, the Sending mark spins for at most 10 s after a frame leaves, then stays still on Sending until the Mac's receipt.
- On the phone the delay line ("Sent … · delivered …", without "from phone") is shown only in the message's details, not under the bubble; the Mac draws it under the bubble.
- Resend gives the message a new `ts`, so the Mac's `sentAt` and the delay line count from the last resend.
- A message the phone never got `accepted` for and whose deadline passed turns Not delivered on the phone with "This iPhone couldn't send it within 24 hours."; one that was accepted waits for the Mac's answer on `.paired`.
- A stored outbox item whose message leaves the history window is dropped with its times.

## 2026-10-09 — Direct phone ⇄ Mac path
Source: owner decisions recorded in issue #315 ("projectx: direct phone ⇄ Mac connection over LAN and Tailscale, with automatic path selection"), Decisions section.

- Add a direct path; the relay stays the fallback. Direct means the same LAN **or** a private VPN (Tailscale/WireGuard).
- The path in use is shown only in Settings diagnostics, never in the chat.
- Discovery: the Mac sends its LAN and Tailscale addresses inside the sealed peer info over the relay. The phone stores them with the pairing. The listener port is fixed. Bonjour later, only if needed.
- No wake-on-LAN. Instead a **Keep Mac awake** toggle in Mac Settings, off by default.
- The iPhone has a **"Direct connection (LAN / Tailscale)"** setting, **off by default**. Turning it on is when iOS asks for Local Network permission. Until then the phone uses the relay only. If permission is denied, Settings points to Privacy › Local Network.
- Mac listener: inside the Mac app's relay host actor, in Swift, `NWListener` + WebSocket, fixed port, LAN and `utun` interfaces only. Each device has a route (relay | direct); a new hello moves the route. `deliver()` works per route, so LAN keeps working during relay outages.
- Both paths carry the same sealed envelope and the same per-device sequence counter.
- Direct handshake is mutual and domain-separated: the phone signs `yorozu-direct-v2|room|nonce`, and the Mac proves it holds the paired key. This replaces v1's undomain-separated join.
- Staggered race: direct candidates at t=0, relay about 300 ms later; the first authenticated `joined` wins. Race only up to `joined`, never through hello. LAN candidates only on Wi-Fi/Ethernet; Tailscale candidates only when a VPN is up.
- Re-race on foreground, network path change or failure. Make-before-break upgrade from relay to direct. Per-candidate backoff 30 s doubling to 10 min, reset on a real path change. No downgrade while the direct heartbeat is healthy. Do not port v1's `skipDirect`.
- Liveness: the phone pings every 10 s with a 5 s deadline. The Mac drops direct links silent for more than 30 s and closes them when it sleeps. The menu-bar host holds a `ProcessInfo` activity against App Nap.
- Dedupe by event id plus sequence. The outbox is resent after every new session. Direct never buffers: when the Mac is offline the phone uses the relay and its buffer.
- v1 is untouched; the relay needs no deploy for the direct path.

## 2026-10-09 — Direct path: implementer readings (not owner decisions)
Source: the wire spec and plan comments on issue #315 (branch `direct`, built as `dp-phone` and `dp-mac`). The open questions were taken at their proposed defaults; the owner has not answered them, and [status.md](secretary-status.md#open-items) keeps them as an open item.

1. Port: 8738 by default (not 8443, v1's `tailscale serve` rule), overridable as `[direct] port` in `config.toml`, 1024–65535.
2. The Mac listener has its own switch, `[direct] enabled = true`; both `[direct]` keys are security-relevant. A phone still dials directly only once its own toggle is on. With `enabled = false` the Mac leaves `direct-v1` and the candidates out of its peer info.
3. The Mac signs `yorozu-direct-v2-host|<room>|<phone nonce>` in `joined`; the phone accepts it only when base64url sha256 of the Mac's key equals the QR's `roomId`.
4. Generic WireGuard: any private address (RFC 1918, 100.64.0.0/10, ULA) on a `utun` interface is advertised as kind `vpn`; diagnostics call it "Tailscale" only inside 100.64.0.0/10 or fd7a:115c:a1e0::/48.

Added in implementation:
- A direct `frame` message wraps the relay's signed frame as an object, `{"type":"frame","frame":{"payload":…,"sig":…}}`, one frame per message, rather than the relay's flat `payload`/`sig` fields or its batches.
- A race the relay wins first still upgrades: direct legs keep running beside the relay session, and the first to authenticate takes it over make-before-break.
- A `hello` the relay replays from its buffer never takes the route from a live direct link: it is older than the link.
- After the join, any message the Mac cannot decode, an unknown `type` included, closes the link with 4001 (unauthorized); before the join, anything other than a valid join is refused the same way.
- The phone's candidates refresh only at the next peer-info exchange: a Mac whose addresses change publishes them in its own diagnostics at once but sends nothing until a phone's next session.
- Close codes 4000 sleeping, 4001 unauthorized, 4002 superseded, 4003 over 1 MiB; at most 8 connections wait for a join on the Mac, each for 10 s; a failed listener restarts from 2 s, doubling to 60 s.
- The phone's toggle uses the new `UserDefaults` key `directPathEnabledV2`, never v1's `directConnectionEnabled`; its candidates live in the Keychain pairing record.

## 2026-10-09 — Attachments in both directions
Source: owner decisions recorded in issue #316 ("projectx: attachments in both directions"), Decisions section. This supersedes the 2026-10-07 16:27 JST R1 input scope ("conversation and pasted text only"; document import outside scope).

- Any file type. Both directions in one issue, built in this order: user → agents, then workers → user. Phone and Mac together, in the 0.7 contract.
- Limits: 50 MB per file, 10 files per message. Photos are downscaled to 2048 px by default, with a "Send original" option.
- Mac offline: text uses the relay buffer. Attachments wait on the phone and upload when the Mac is reachable (the buffer is only 5 MiB).
- Files reach workers as paths: one line `Attached document: <path>` per file in the worker input. Images also go in as direct model input when the worker's model supports images; the per-call `models.list` `input` check is the source of truth, otherwise the path alone.
- Storage: visible, at `~/Yorozu/files/<YYYY-MM>/<YYYY-MM-DD_HHMMSS>_<sanitized original name>`, with a `_2` suffix on a clash. Never in the repo checkout or in worktrees.
- Workers return files flexibly, in any of three forms: a `files` array in the thinking worker's final JSON, a `Files:` section in a coding reply, or OpenClaw `MEDIA:<path>` lines. Any readable path is accepted. Yorozu copies each file into `~/Yorozu/files/` with the dated name and attaches it to the result, under the same limits.
- Phone downloads: previews (thumbnails, file rows) download automatically. Full files download on tap and open in Quick Look or the share sheet. Opened files stay in the phone cache.
- Secretary: sees only a description (name, type, size, path), never contents. Attachment-only messages are allowed; the secretary acts when the context is clear, or asks one short question.
- Privacy: no extra step. Attachments are treated like typed text.
- Memory: only through the conversation. Extraction reads message text; a note may cite an attached file as its source.
- Retention: files are kept forever and deleted by hand in Finder. A missing file shows "File no longer available".
- Sub-chat images: a sub-chat may show intermediate images that workers choose to share, synced to the phone. Screen content never goes into memory. This amends the cua rule that kept screen content out of progress messages; accessibility-tree dumps and clipboard contents stay out.
- OpenClaw's own media copies are left alone (no `attachments.ttlHours`).
- Composer methods now: on the Mac, drag-and-drop, paste and a file picker; on the phone, photo library, camera, Files and paste. The iPhone share sheet is a separate future issue (#322).
- Long text: the 6,000-byte message cap stays. A longer draft offers "Send as text file" (#311 Q12).

## 2026-10-09 — Attachments: implementer readings (not owner decisions)
Source: the plan comment on issue #316 (branch `attachments`, built as `at-store`, `at-harness`, `at-wire`, `at-macui` and `at-ios`). The open questions were taken at their proposed defaults; the owner has not answered them, and [status.md](secretary-status.md#open-items) keeps them as an open item.

1. The text of a message with files waits on the phone with its files, as one unit, so the secretary never routes a caption without its file. It goes as `attachment_commit` once the files are uploaded, never as a `message` through the relay buffer; a later text-only message may go first.
2. No per-message total beyond 10 files of 50 MB each.
3. The 2048 px downscale applies to every image, picked from Files or Finder or dropped as well as photos, camera shots and pasted images, each with its own "Send original". PNG, JPEG, GIF and WebP within 2048 px go as they are; anything larger, and HEIC or TIFF at any size, becomes a JPEG at quality 0.85 with the EXIF orientation applied.
4. Workers write files they make for the user in a scratch folder outside any repo, `$TMPDIR/yorozu-scratch/<topic id>/` (the app's temporary folder, named as an absolute path in both contracts), because a Codex `workspace` sandbox can write only its worktree and the temporary folders. Yorozu copies returned files into its store, so nothing there needs to last.
5. `~/Yorozu/files` is not added to OpenClaw's allowed media roots; workers get inline images plus the path, and a thinking worker's shell reads any path.
6. Intermediate sub-chat images are standalone `MEDIA:<absolute path>` lines in a worker's committed progress messages, images only; the lines leave the event body ("Shared an image." when nothing else is left) and the images are attached to that worker event.

Added in implementation:
- 50 MB is decimal (50,000,000 bytes, as Finder counts), the same on both devices and on the wire.
- The file store refuses a root that resolves inside a git checkout or worktree; attachments are then off for that launch and the status line says why. Directories are 0700 and files 0600. `PROJECTX_DATA` and fixture runs keep files in `<data root>/files/`.
- A returned file past the 10th, over 50 MB, missing or unreadable is skipped with a one-line note at the end of the result. Returned-file references are stripped from the stored text ("See the attached file." when nothing else is left); URLs stay text, and a relative path in a coding reply resolves against its worktree. A result superseded by a follow-up turn keeps its files on the `superseded_result` event.
- Images go inline only as PNG, JPEG, GIF or WebP of at most 6 MiB, within an encoded-params budget of 7,600,000 bytes on the native transport and 600,000 on the CLI transport; memory steps send none. Hermes gets paths only.
- A steer's files are linked to the work and their `Attached document:` lines ride in the amendment text, so a live steer and a follow-up turn both get them. A correction moves the mistaken work's files to the intended work.
- The wire adds capability `attachments-v1` inside contract 0.7, with no protocol change; a phone or Mac without it never sees an `attachment_*` kind, and a phone message with files waits until the Mac advertises it. A 0.7 `message` with inline v1 attachments is refused with "Update Yorozu on this iPhone to send attachments."
- Mac upload staging holds at most 1 GB (two complete messages) and 64 messages, prunes folders untouched for 48 h, and keeps a refused commit's staging so Resend commits without uploading again.
- Phone previews are the Mac's own 512 px JPEG thumbnails; downloads go 160 KiB a chunk, at most two requests in flight per phone. A `worker_event` record becomes an upsert by `seq`, since attaching shared images re-stamps it.
- The Mac stores sub-chat images but shows none: it has no sub-chat UI.
- On 2026-10-09 `models.list` for agent `projectx` listed `image` in the input of every configured model, the worker default `openai-pool/gpt-6-astra` included ([setup.md](secretary-setup.md#models)).

- Worker-returned files: `FileStore.adopt` refuses private folders (`~/.ssh`, `~/.gnupg`, `~/Library/Keychains`, `~/.appstoreconnect`, `~/.openclaw`, `~/.hermes`, `~/.aws`, `~/.config/gh`, the app support folder and data root) and key-like names (`*.pem`, `*.p8`, `*.key`, extensionless `id_*`). A narrowing of "any readable path is accepted" for safety: a prompt-injected worker could otherwise name a secret that then syncs to the phone. Files the user attaches are not filtered.

## 2026-10-09 — Onboarding, readiness and integrations
Source: owner decisions recorded in issue #317 ("projectx: onboarding"), Decisions section.

- Audience: onboarding is designed for a new person. The owner and existing v1 users use the same flow, which skips what is already in place. Owner specifics come from `config.toml`.
- Assisted setup: when the user clicks, Yorozu writes only its own entries into the harness config. For OpenClaw these are its agent entry, its model allow-list entries and its `yorozu-*` MCP entries, all through `config.patch`. It never touches other agents' entries, providers or logins. Installing software and logging in to providers stay manual, and Yorozu gives instructions.
- Agent id: a new person gets the generic `yorozu`. The owner keeps `projectx` through `config.toml`.
- Setup CLI: a Swift subcommand of the app binary (`Yorozu.app/Contents/MacOS/Yorozu setup …`), with an optional `yorozu` link on PATH. `yorozu setup --json` prints the next step: what it checked, plus any question with id, text, choices and default. The agent asks the user, then runs `yorozu setup answer <id> <value>`; the CLI applies the step and prints the next one. The website hosts a short message users paste into their existing agent (Claude Code, Codex, OpenClaw…), which then drives the CLI and asks the questions; #317 writes it in docs/setup.md and #321 publishes it. One step engine backs the CLI and the in-app window. The app-download step joins once Mac distribution (notarization) exists.
- Declarative integrations: a plugin system without code loading; "no plugin loaders" stays. Each integration is data: its MCP servers, its worker rules, its setup steps and readiness checks, its settings and an on/off switch. CuaDriver becomes an optional integration. New integrations are added as data, shipped with the app or written in `config.toml`.
- Harness choice: Yorozu detects the harnesses installed on the host, and each adapter declares its own read-only detection. Onboarding asks which harness is the main one; the user can switch later in Settings, a security-relevant change.
- Block or warn: block the composer only when nothing could answer (no harness at all), with a plain reason and a "Fix…" button. Partial problems show a warning banner with "Fix…". Errors become plain language. The phone shows the same Mac readiness (0.7 contract).
- First-launch setup window: welcome → harness → models → integrations → YOLO → start at login → pair iPhone → done. Completed steps are skipped. It reopens from Settings › General ("Run setup again…"), next to a status row ("Ready" / "N items need attention").
- Pairing: v2 claims the https pairing link again (`applinks:yorozu.yumi.to`), so the system Camera opens Yorozu; v1 and v2 share the iOS bundle id, so the website's AASA already covers v2. The Mac shows the key fingerprint and the code as text. Wording matches on both devices.
- Integration checks: each integration declares read-only checks the app may run: a file or app exists, a socket answers, or a status command explicitly marked read-only (such as `cua-driver permissions status --json`). Checks run only during setup, while Settings is open, and on "Check again". Grants stay manual, with a copy button for `cua-driver permissions grant`.
- Migration of v1 users to v2 is a separate future issue (#322); onboarding assumes a fresh install.
- Coding workers: opt-in under Settings › Advanced, on one configured repository (`dev_repo` in `config.toml`, empty by default), with today's contract. Settings › Advanced also shows the harness's coding executors and their readiness. Coding on any repository is a future issue.
- YOLO and start at login are onboarding steps; the settings themselves come from #312.
- Setup completion is stored in `config.toml`, never in v1's `onboardingCompleted` UserDefaults key.

## 2026-10-09 — Onboarding: implementer readings (not owner decisions)
Source: the plan comment on issue #317 (branch `onboarding`, built as `ob-agent`, `ob-integrations`, `ob-ios`, then the setup core). The open questions were taken at their proposed defaults; the owner has not answered them, and [status.md](secretary-status.md#open-items) keeps them as an open item.

1. Role models: usable means listed by `models.list {agentId, view: "configured"}` and not `available: false`. A role model OpenClaw knows but the agent's policy does not allow is added to Yorozu's own `agents.entries.<agent>.modelPolicy.allow`, seeded from the policy in force (the entry's own list, else `agents.defaults.modelPolicy.allow`), since an explicit per-agent list replaces the defaults for that agent. An empty policy, which allows every model, gets no list. `agents.defaults` is never written. Whether `sessions.create` with each role model passes on the running build has not been checked live.
2. The agent workspace while coding is off: an empty Yorozu-owned folder, `<data root>/openclaw-workspace` (mode 0700, created just before the write). Once `dev_repo` is set, the workspace is that repository.
3. The base branch: `[harness] dev_base`, set to `projectx` in the owner's file; empty means the branch checked out in `dev_repo` when the coding work starts.
4. Coding requests while coding is off: the routing policy offers no executor and tells the secretary to reply that coding is off and can be turned on in Settings › Advanced; a coding decision is refused with that notice.
5. An installed harness whose Gateway is down warns rather than blocks: the message is still stored, and the failure shows in plain language.
6. Readiness timing: the main harness's detection plus Gateway `health`, once at launch and again after any Gateway call fails. Integration checks run only during setup, while Settings is open, and on "Check again".
7. The phone composer while the Mac is Blocked follows the Mac rule: off.
8. CLI steps that need the Gateway while the OpenClaw exec markers are set: the CLI does not attempt them and reports "finish this in the Yorozu app" with where. The markers are never worked around.
9. The PATH link is `~/.local/bin/yorozu` (user-writable, no sudo, the folder CuaDriver uses), created only after the user says yes.
10. User-defined integrations in `config.toml` get file and socket checks only; command checks stay limited to built-in integrations.
11. Executor readiness: "found" or "not found" for each binary from the launch PATH plus `~/.local/bin` and the Homebrew folders, provider auth from `models.authStatus`, and the sign-in commands with copy buttons. An executor is never called "logged in".

Added in implementation:
- The pairing code is the full pairing link (`https://yorozu.yumi.to/pair#…`, the QR's own content), which the phone's manual entry takes; there is no short-code protocol.
- The Mac key fingerprint (`QrPayload.fingerprint`) is the Mac key's first 8 bytes in uppercase hex, in groups of two bytes (`3F9A 1C07 B2E4 55D0`), the same on both devices.
- Roster ownership: OpenClaw accepts a second agent entry only in an explicit agent list. When Yorozu's entry is missing and the list is not explicit (`agents.ownership` is not `"explicit"` and no entry has `default: true`), Yorozu writes nothing, never writes `agents.ownership`, and offers `openclaw agents add <agent> --non-interactive --workspace <folder>` to copy.
- Integrations and `[mcp_servers]` coexist: workers get `[mcp_servers]` minus the servers of disabled integrations, plus the servers of enabled integrations, with `[mcp_servers]` winning on a name clash. A legacy `config.toml` whose `[mcp_servers]` has no `cua-driver` entry and that sets no `[integrations.cua] enabled` loads with cua off, since removing that entry used to mean computer use off.
- An existing agent entry that differs from the expected shape is shown as a list of changes and written only after the user confirms; the write is refused if OpenClaw's config changed since the user saw it.
- The setup CLI exits 2 for usage, an unknown id, an invalid value or an app-only step, and 1 for other failures, with `{"error": …}` under `--json`.

## 2026-10-09 — Hermes profile setup
Source: the plan comment on issue #318 for the remaining code after #317 (branch `hermes-setup`).

- Yorozu writes its two Hermes profiles only after an explicit action: a click in the setup window, or `setup answer hermes_setup apply:<plan_digest>` naming the changes the caller reviewed. The digest and stale rule is the one `openclaw_setup` uses.
- The default Hermes profile is never edited; when its API server is off, readiness shows the commands to copy.
- When `[mcp_servers]`, an integration or `dev_repo` changes, the profiles are not rewritten automatically. Readiness warns "Hermes profiles need updating" with Fix… at the harness step, where the user applies the changes.

## 2026-10-09 — Jobs lists, job screens and wire: implementer readings (not owner decisions)
Source: the plan comment on issue #319 for the rest of the issue after phase A (#331), built on contract 0.7 (#329) and the approved #311 mockups (branches `jb-wire`, `jb-mac`, merged in `jobs-ui`).

- The owner decisions are those of "Scheduled jobs run by Yorozu" above, unchanged: Yorozu as the runner, `jobs.toml`, one topic per job, time-based schedules, always running, per-job posting, three forms, scripts with the yes even in YOLO, the Jobs lists, spec and summary, the job input as the one exception to typing only in the main timeline, the accepted defaults, and OpenClaw automations as reference only.
- Open questions 1–16 stay at their proposed defaults, as listed in "Jobs phase A: implementer readings" above; the owner has not answered them. This part builds the two that waited for the UI: 13, Delete asks for a confirmation on both devices before it removes the entry; 14, the Mac's job sub-chat is the detail pane of Settings › Jobs, with the job input.

Added in implementation:
- A job run's trigger (`job_run`) is never sent to phones, with or without `jobs-v1`; the phone sees a run through its task and worker events.
- The other job-only messages (`job_input`, `job_result`, `job_note`) go only to phones that negotiated `jobs-v1`. `EngineBridge` builds one page for every phone and `RelayHost` strips them per phone from each `sync_delta`, so a phone without `jobs-v1` never shows them in its main chat.
- A phone cache filled without `jobs-v1` has its cursor past the job-only messages, so the first `jobs-v1` handshake drops the cursor once and catch-up refills the window; the cache records that it holds them.
- The job input is text only on both devices: no attachments and no Send as Text File.
- The job sub-chat on the Mac shows the run's worker events (a script's output, the lifecycle lines) as compact monospaced rows between the messages, and the `job_run` trigger as a system row.
- `job_control` refusals (`admission_status rejected`) carry the Mac's English text, as other admission refusals do; the phone shows them as they arrive.

## 2026-10-09 — Push notifications
Source: owner decisions recorded in issue #320 ("projectx: push notifications for the phone"), Decisions section.

- Push is its own issue, linked from the sync issue (#313).
- The lock screen shows only content-free text ("Yorozu replied"), never message content. No sealed previews.
- Triggers: a result arrived, a failure, a result that asks the user a question, and the Mac coming back online.
- The app badge shows an unread count taken from the synced read state (#313's one "last seen message" cursor through the Mac).
- The notification destination setting decides where notifications appear: this Mac, phones, and later a Mac client (#311, #312). #320 makes "phones" work.
- Scope: the APNs entitlement and the background mode in the iOS app, calling the existing `RelayClient.registerPush`, the relay's `notify` path, the triggers, the badge and the destination setting.
- The outbox notification after the background flush and the 24 h expiry alert stay local notifications from #314; they need no push.
- Standing rules: no model learns which device a message came from (#313); v1 keeps working for its existing users; v2 iOS builds stay internal-only.

## 2026-10-09 — Push notifications: implementer readings (not owner decisions)
Source: the plan comment on issue #320 (branch `push`, built as `pu-mac` and `pu-ios`). The open questions were taken at their proposed defaults; the owner has not answered them, and [status.md](secretary-status.md#open-items) keeps them as an open item. The flow is in [architecture.md](secretary-architecture.md#push-notifications), the wire in [ios-relay-contract.md](ios-relay-contract-v2.md#push).

1. No relay change: the Mac sends only the four classes the deployed relay accepts, result → `reply`, failure → `failed`, question → `approval`, Mac back online → `done`. The phone's string catalog words each fixed relay `loc-key` for v2 in English and Japanese ("Yorozu needs your approval." → "Yorozu has a question for you.", "Yorozu finished." → "Your Mac is back online."). v1 phones are never in a v2 Mac's room.
2. A result is a `result` message (worker results and job results posted to the main timeline), a secretary reply (assistant `conversation`) or an `amendment_unconfirmed_*` notice. Acknowledgments, memory receipts, routing notices and job-only kinds do not count, and messages that existed at launch never notify.
3. A question is #311's signal (kind `question`, notice `question`, `question_topic` or `question_task`); no `asksUser` field was added to the worker contracts.
4. "Mac back online" fires once, when a relay registration follows at least 10 minutes offline, counting time the app was not running, at most once an hour, persisted in `relay-online.json`.
5. The phone sets the badge itself (`setBadgeCount`) after every sync and silent wake; no count goes through the relay, so a read on the Mac clears it at the phone's next wake or foreground. When the cursor passes a message, its delivered pushes are removed (matched by the `event` ref).
6. No banner while the app shows the main timeline; a banner elsewhere in the app. A tap opens the main timeline at the message the `event` ref names, found by hashing held message ids after catch-up, else at the bottom.
7. One permission request (alert, sound, badge) shared with #314, keeping #314's first-queued-message moment.
8. The destination stays one choice, `mac` or `phones`. Pushes, back online included, go out only with notifications on and destination `phones`.

Added in implementation:
- "Seen" for the back-online rule is the last time the Mac was online at the relay: written on each registration, on each pong of the 30 s heartbeat and on stop while registered, so a quit, a quick restart or a short drop stays silent. A Mac with no `relay-online.json` yet sends none.
- `approval_request` (a job script waiting for a yes) counts as a question. The classifier is shared, so this, and counting secretary replies and unconfirmed-change notices as results, changes the Mac's notifications and menu-bar dot too.
- The phone cannot see the Mac's destination, so instead of open question 7's default (ask when Phones is selected) it asks for permission at a foreground launch when it is paired and has never been asked, besides #314's moments; a background launch (a silent push) asks nothing, and iOS shows the prompt once. This is the chosen behaviour.
- The badge counts from the later of the phone's own last read and the Mac's cursor; with neither in the phone's timeline it counts every Yorozu message there. Back-online alerts are removed when the app comes to the foreground.
- The failure key ("Yorozu needs attention.") reads "A task failed." (ja "タスクが失敗しました。"), as on the Mac, and all four keys have es, ko and zh-Hans with the v2 meaning.
- Turning notifications off, or the destination to This Mac, drops the held notifies.
- Held notifies live in memory (the latest 20, sent on registration when under 24 h old, collapsed to the newest per class); a quit loses them. Notifies sent since the last pong are sent again on the next registration, for a socket left half-open by sleep.
- The back-online push names a random event ref, so its tap opens the main timeline at the bottom.
- With the direct path, a phone whose current token the relay has not heard opens one extra relay socket to register it (`RelayClient.registerPush(deviceToken:relayKnows:)`), and stores the token the relay heard per pairing.

## 2026-10-09 — Website for 0.7.0
Source: owner decisions recorded in issue #321 ("projectx: website update for 0.7.0"), Decisions section.

- The site (https://yorozu.yumi.to, `apps/web` on `main`) describes only what has shipped by the 0.7.0 release.
- Every claim that no longer holds for 0.7.0 is rewritten, not left in place.
- The site's "Set it up with one prompt" section and `Start.md` carry the 0.7.0 paste-in message verbatim from docs/setup.md (#317); #321 publishes it and writes no second version.
- v1 keeps working for its existing users: `/pair`, the AASA file, and the privacy and terms pages keep working for both v1 and v2 links.
- The public TestFlight link stays on the v1 build until v2 is released to that group.
- No personal data on the site, in screenshots or in `Start.md`.
- Screenshots are regenerated from the 0.7.0 UI.
- Process: a branch off `main` and a PR to `main`, with `Start.md` in the same PR. Merging deploys, so the owner merges it at the 0.7.0 release.

## 2026-10-09 — Website: open questions at their defaults (not owner decisions)
Source: the plan comment on issue #321. The open questions were taken at their proposed defaults; the owner may override them, and [status.md](secretary-status.md#open-items) keeps them as an open item.

1. Downloads: `/mac`, `/beta` and `/iphone` stay on v1, each labelled with what it installs. 0.7.0 builds from source.
2. Prompt URL: stays the raw `Start.md` on `main`, which becomes a short 0.7.0 guide with the paste-in message copied verbatim from docs/setup.md.
3. Third parties: Hermes Agent and CuaDriver are added to the terms, the privacy page and the footer, and both effective dates change. The owner approves the legal wording.
4. Screenshots: Mac shots from the 0.7.0 dev app in a throwaway fixture-mode data folder, with the relay pointed at a dead address so it never joins the owner's room, and an invented conversation. Phone shots wait for an internal build on an owner device; the v1 phone shots come off the page until then.

## 2026-10-09 — Hermes providers
Source: owner decision in issue #318 ("Hermes uses Codex or Claude Code, never Copilot").

- Hermes runs Yorozu's work on Codex or Claude Code, never GitHub Copilot. Copilot was removed from both Yorozu profiles.
- Codex is the route: Hermes's own device-code login (`hermes auth login openai-codex`, answering N to importing the Codex CLI's tokens), borrowed by Yorozu's profiles from the default profile, so one sign-in covers both.
- `auth.adopt_external_logins` stays false in Yorozu's profiles: a refresh of a borrowed Codex CLI or Claude Code token can sign that tool out. The Anthropic route exists only as that borrowing, so Codex is the safe choice.
- Implemented: readiness blocks on a `copilot*` provider ("Hermes uses GitHub Copilot, which Yorozu doesn't use") with the `config set model.provider openai-codex` commands to copy; the no-provider warning copies the Codex route; the run path refuses a Copilot provider before sending, and the model list drops Copilot rows.

## 2026-10-09 — Topic routing: small talk, new sub-chats, attach
Source: owner decisions in issue #348.

- Small talk is never filed: a message that isn't categorizable, such as "hello", gets a reply from the secretary and no topic.
- Not enough context to categorize a prompt: Yorozu starts a completely new sub-chat and the discussion begins there.
- Once that conversation turns out to belong to a topic that already exists, the new sub-chat's context is attached to the original topic and the discussion continues there, keeping topics separate and properly categorized.
- This replaces "No automatic topic merging or splitting" for this case.
- Implementer readings (not owner decisions): `attachTo` on `delegate`/`steer`, with `topicID` naming the sub-chat (never guessed from the latest topic); the link is recorded only once the work or steer is accepted; only a topic created in the last 7 days, not a job topic, not the `self_topic`, not attached and with nothing attached to it can be attached, and only to a topic that is neither attached nor a job topic; attaching is one-way and never splits; retry, redo and correction of the sub-chat's tasks stay in it; the target's workers get an excerpt of the sub-chat, then its newer lines; the phone shows "Attached to “T”" (「T」に統合) and lists attached sub-chats on the target.

## 2026-10-09 — ⌘Enter sends by default on the Mac
Source: owner feedback after testing 0.7.0.

- The Mac popover's default `[general] send_key` becomes `"cmd-enter"`: Enter adds a line and ⌘Enter sends. It stays customizable in Settings › General. This replaces smart Enter as the Mac default.
- Implementer reading (not an owner decision): files that already set `send_key` keep their value, and every file Yorozu has written sets it, so the new default reaches new data folders; phone hardware keyboards are unchanged here.

## 2026-10-09 — Replies skip categorization
Source: owner feedback after testing 0.7.0.

- A reply links to the replied message's topic without categorization.
- Implementer readings (not owner decisions): clients send `MessageData.replyTo`; a reply to a message with a topic pins that topic's home (an attached sub-chat resolves to its target) for `delegate`, `reply` and `clarify`, and a `steer` of a task outside it becomes new work there; a `routing_pin` receipt records it; the Mac context menu has Reply, then Copy (it has no Share, Select Text or Show Details items).

## 2026-10-09 — Host and client devices; Settings without scrolling; Mac feedback on 0.7.0
Source: owner feedback after testing 0.7.0 on an iPad.

- Client devices won't always be iPhones: iPads now, Macs as clients later, maybe non-Apple devices. User-facing text says **host** (the Mac running Yorozu) and **client devices** / **clients**, not "this Mac" or "iPhone(s)"; Settings › Devices lists "Client devices"; "Pair iPhone…" becomes "Pair a Client Device…".
- Mac Settings shows all its information without scrolling, on every tab.
- The pair sheet shows the result when a client device pairs: a checkmark, "Paired with “<name>”" and Done.
- The menu-bar icon's menu offers Open Quick Chat, Pair a Client Device…, Direct Connection (LAN/VPN), Keep Host Awake, Settings… and Quit.
- Mac icons are SF Symbols, except the menu-bar logo and the app icon; the delivery mark under the user's messages is two overlapping `checkmark.circle` symbols, filled once read.
- Implementer readings (not owner decisions): Advanced was split into Harness (harness, connection, enrollment, models) and Advanced (coding workers, integrations), with About this install moved to Storage; config keys and values (`destination = "phones"`, `keep_mac_awake`, setup id `pair_iphone`) and wire fields are unchanged; Gateway-enrollment and coding-tool text keeps "this Mac", which is about macOS itself.

## 2026-10-09 — Workers as harness sub-agents, coding agents run by Yorozu, a workspace with a folder per task
Source: owner decisions in issue #351.

- Workers are sub-agents of the active harness, OpenClaw or Hermes Agent, not separate entities. Claude Code and Codex are not hard-coded, and the user doesn't always have to use Claude Code for coding.
- Coding agents run through Yorozu. Claude Code, Codex and others are called through a Yorozu-owned process that runs the agent's terminal command. Its live output streams into the task's sub-chat on the host and on clients.
- No hard-coded repository. The user works across many repositories. The special self-development setup (`dev_repo` = Yorozu's checkout, merge into `projectx`, then `build_native.sh --restart`) is dropped.
- Workspace. Settings › Storage sets a workspace folder for agents, default `~/Yorozu/workspace`. Downloaded files go there, and so do downloaded (cloned) repositories.
- One folder per task. Each task or sub-chat gets its own directory inside the workspace, used as its working area, so things don't get jumbled.
- File access. Agents' file access is not limited by default. An optional setting can limit it.
- This replaces "coding workers are opt-in on one configured repository (`dev_repo`)", the coding-executor lines (harness-offered executors, the coding contract, the OpenClaw rule that app work goes to Codex) and the job executor choice.
- Implementer readings (not owner decisions): the routing `executor` field, the coding executors and the coding contract are removed; old `dev_repo`, `dev_base` and `[models.coding]` keys stay in the file as ignored data, and old coding work rows reconcile as stopped; the tool is the app binary as a CLI, `Yorozu agent run <agent> --task <work id> -- <prompt>`, talking to the running app over `<data root>/agents.sock` (a CLI rather than an MCP server, since harness shells already run long commands and MCP tool calls are bound by each harness's tool timeout); the work id is the task token and must be a running worker task; the task folder is `<workspace>/<label slug>-<topic id prefix>/`, derived, not stored, and an attached sub-chat uses its target's folder; OpenClaw sets it as the topic session's `cwd`, Hermes names it in the contract (`terminal.cwd` is the workspace); built-in agents run with full access (`claude -p … --permission-mode bypassPermissions`, `codex exec --sandbox danger-full-access`); `restrict` is enforced in code for coding agents only; OpenClaw thinking steps may now run 70 minutes so a worker can wait for an agent; three worker lanes replace two thinking plus one coding lane.
- Review follow-up (implementer readings): the built-in agents' timeout is 1500 s, under OpenClaw's 1800 s exec default, and the contract tells workers to set exec `timeoutSeconds` (Hermes `timeout`) to at least the agent timeout plus 120 s; with `restrict` on, agents run a sandboxed `restricted_command` (Claude Code `acceptEdits` plus `--add-dir <workspace>`, Codex `workspace-write` plus `--add-dir <workspace>`) or are refused; at most 2 agents run at once and one per task; a run stops when its client hangs up or its task stops running; logs live in `<data root>/agent-runs/`; prompts go on stdin through a quoted heredoc. Whether full access stays the default while `restrict` is off is left to the owner.

## 2026-10-10 — Coding agents: full access by default
Source: owner, in session ("full access").

- With `[workspace] restrict` off, the built-in coding agents keep full access (`claude --permission-mode bypassPermissions`, `codex --sandbox danger-full-access`); with it on they run sandboxed to the workspace. This settles the open question from #351.

## 2026-10-10 — Live steering by default; notifications with content; start, progress and completion messages
Source: owner, in session, after a held steer showed "I'll apply that right after the current step." and notifications read only "Yorozu replied".

- Steering is the default for a message about running work: the change goes into the running task live, not after its current step. On OpenClaw that means `chat.send` with `queueMode: "steer"` into the topic session's active run; the follow-up turn stays only as a fallback when the live inject is refused.
- Notifications carry the message's actual content, on the host and on client devices. On client devices the preview is end-to-end encrypted: the host seals it, the relay forwards an opaque blob, and a Notification Service Extension on the phone decrypts it, so Apple and the relay never see the text. This replaces the content-free notification decision (2026-10-09, #311 question 3 and #320). The relay on `main` already forwards per-phone sealed previews, so it needs no change.
- Delegated work gets an initial, progress and completion message in the main timeline, so the user knows what is happening. The secretary writes the initial message in its own words, naming the task, from the routing call it already makes (no extra model call). Progress messages come from worker milestones, a one-line update at most about every 2 minutes, and none for tasks that finish quickly. The completion message is the result. This replaces the 2026-10-08 "No boilerplate acknowledgments" decision; boilerplate such as "I'll work on that in the background" stays banned.
- Only results, failures and questions notify; initial and progress messages update the timeline silently.

## 2026-10-10 — Two-stage topic categorization
Source: owner, in session, after reviewing how real messages were filed: a photo with no text went to the latest topic and its follow-ups split across two topics, a short reaction to an answer was left untopiced, two "use Codex/Claude Code to create a file" tests got a topic named after the tool, and a vague request got a label naming a subject it never mentioned.

- Every message first goes through a small-model classification step that sees the message and the last few messages and answers `new` (a new subject: a new topic), `oneoff` (small talk or something the secretary answers itself: no topic) or `continue` (an earlier subject).
- Always make a topic: anything that needs a worker gets one. `oneoff` is only for what the secretary answers without a worker; if work turns out to be needed, it becomes a new topic.
- For `continue` the topic is found by search, not by being the latest topic. The classifier also returns search terms in English and Japanese; code searches the existing full-text indexes (`messageSearch`, `eventSearch`) plus topic labels and summaries and ranks topics by hits and recency, and the 5 most recent topics are always candidates. The secretary's routing call gets those candidates, each with a one-line summary, instead of the full topic list, and picks one. If none fits it looks at the next 5 by recency, at most 3 rounds in all; then a new topic is created silently, with no question to the user.
- Topics keep a one-line summary, updated by the memory extraction that already runs after results (no extra model call), and searchable.
- Photos and images: the classification step gets image thumbnails when its model accepts images (the existing `models.list` `input` check), so it can tell a floor plan from a screenshot; other files stay name, type and size only.
- Kept: the #348 attach mechanism, reply pinning (a reply skips classification and stays in the replied message's topic), steering of running work, the identical-message rule and job routing. A topic label names a subject, never a tool: a test of "use Codex to …" on Yorozu is Yorozu work, under `self_topic`.
- Cost accepted: one extra small-model call per message, skipped when a reply pin or the identical-message rule already decides.
- This replaces "a clear follow-up goes to the latest user-discussion topic" (2026-10-07) and the secretary seeing the whole topic list.
- Implementer readings (not owner decisions): the classifier runs on the secretary model and its call failing counts as `continue` without terms; `new` shows the `self_topic`'s topic as the one candidate and `continue` adds it to the first round; job topics are never candidates (they are listed under jobs); topic search counts matching messages and sub-chat events per term (at most 5 a term) plus 5 for a label or summary match, divided by 1 + months since the topic's last activity; label and summary matching is a `LIKE` scan, since topics are few, rather than a new full-text index; "none fits" is the decision's `noMatch` flag with a `newTopic` label, which the next round replaces unless the label already names a topic; summaries are at most 200 characters and written only for results in non-job topics; thumbnails are 512 px JPEGs; Hermes, which takes no image input from Yorozu, classifies with file descriptors only.

## 2026-10-13 — User-created threads
Source: owner, in a design session: sub-chats are threads, and the user should be able to start one, not only the secretary.

- A sub-chat is a thread. The secretary starts threads from the main timeline as before; the user starts them with New chat. One list holds both.
- The user can type in every thread. The secretary answers there, scoped to the thread: it replies itself, steers the thread's worker or starts work. Job threads keep their direct job input.
- One thread is one topic with one persistent worker session; work started in a thread stays in it. A user-started thread is a topic from its first message, small talk included.
- Messages: the user's on the right, agent messages on the left labelled Secretary or Worker. A secretary-started thread is marked by an icon in the list and a "Started by Secretary from the main chat" header that links to its source message.
- A user-started thread never posts to the main timeline; a list badge and a push notification that opens the thread cover it.
- The secretary searches every thread's messages, current thread first, and cites hits with a link.
- Names are automatic from the first message and renamable. Archive is manual only, and archived threads stay searchable. Delete is permanent, with a confirmation that says extracted memory stays.
- The list pins the main timeline on top, then threads by latest activity, loaded a page at a time behind Show more.
- Mac: the Activities window becomes the chat window with the thread list as its sidebar; the popover stays main-only. Phone: the same list as a navigation stack.
- Wire: threads are an additive capability within 0.7, shipped to the Mac and the phone together; phones without it still get the main timeline.
- This replaces "one main timeline is the only place to type" (2026-10-09), "sub-chats of other topics stay inspect-only" (2026-10-09) and the inspect-only Activities window (2026-10-10).
- Language, clarified the same day: "Swift wherever possible, to serve a native feel", not Swift only. Never Python; code that must live in another ecosystem, such as an OpenClaw Gateway plugin, uses that ecosystem's language.

## 2026-10-13 — User-created threads: implementer readings (not owner decisions)
Source: the implementation of the 2026-10-13 thread decisions (branch `user-threads-impl`). Each is a reading the owner may overrule.

- Thread list grouping (status open item): kept Needs attention, Running and Recent, each by latest activity, with Main pinned above them. Grouping uses each row's current task state, so an `amendment_pending` task that already has a result counts as Running; a thread whose failure is older than the loaded pages shows only once Show more reaches it.
- A thread is created by its first message (`newThread` on `message`/`attachment_commit`, with the client's id), so New chat works offline through the outbox; `thread_control` covers rename, archive, unarchive and delete. Engine has `createThread` for the same.
- A new thread is named from its first message's first line (≤ 40 characters, else "New chat") until the secretary's routing call for that message gives it a label (`newTopic`); a name the user set meanwhile wins. No extra model call.
- Typing in an archived thread brings it back to the list (archiving itself stays manual only).
- Main-timeline routing never files into a user-started thread and never reuses its label; attach refuses user-started threads on both sides.
- Recall runs on the classification step's terms, which in a thread now runs for its terms only (its kind is ignored); a one-off gets no recall. Up to 6 hits, current thread first; citations are `[In <chat>](yorozu://message/<id>)` links.
- Deleting a secretary-started thread also removes its messages from the main timeline (they are the thread's messages). Delete is refused while a task of the thread runs or is uncertain. Worker sessions in the harness, receipts and the task folder stay; only Yorozu's store and its attachment files are cleared. The topic row stays as a tombstone so phones drop what they hold.
- Thread messages stay in the phone's history window for 30 days, like job-only ones; older ones load as a page around the list row's newest message. A phone without `threads-v1` keeps a deleted secretary thread's cached main messages until its cache resets.
- Mac: the window keeps id `activities`, titled Chats. The thread composer is text-only on the Mac (host and client); files go from the main chat or a client device. Thread results post macOS notifications that open the thread; the menu-bar dot stays main-only.
- Phone: Delete closes the thread screen when the request is sent (a refusal shows on the list row); a thread's read cursor follows its newest stored message while the screen is open, without the main chat's at-the-bottom check; a cited message the phone does not hold opens the main page view; the Activities badge still counts topics that need attention, not thread unread counts.
- Live check (#397–#400): main-timeline routing never sees a user-started thread's work or topic ids (not in `work`, not on `recent`); a main reply naming one is posted untopiced and any other main decision naming one is refused. Recall hits outlive memory hits and finished work in the routing trim and carry a ready citation link the secretary must copy.

## 2026-10-14 — The thread list is the iPhone's root
Source: owner, after the thread implementation: the root view should be the thread list, and the main chat and each thread pages of it.

- The iPhone opens on the thread list (Main chat pinned on top, New chat, the threads); the main chat and every thread are pushed from it, with the back button returning to the list. Search and Settings sit on the list.
- Implementer reading: a host that has said it does not take `threads-v1` keeps the main chat as the root, as before; until the first handshake the app assumes threads and opens on the list. The Mac's chat window is unchanged (its sidebar is already the list).

## 2026-10-14 — Sections: a tab bar on iPhone, a sidebar on iPad and the Mac
Source: owner, design interview on adding a tab bar.

- iPhone and iPad get one `TabView` with `.sidebarAdaptable`; the Mac chat window is reorganized into the same sections as a sidebar. Settings stays the macOS Settings window and the popover stays main-only.
- Sections, in order: Chats (`bubble.left.and.bubble.right`), Scheduled (`clock`), Settings (`gearshape`, iPhone and iPad), Search (the search role; the sidebar's search field on iPad and the Mac, ⌘F in the Mac window). No section customization. Wording ("sub-chat" or "thread") is not standardized in this change.
- The main chat stays pinned on top of Chats (the 2026-10-14 root decision stands). On iPad and the Mac Chats is three columns: sections, thread list, open chat. The app always opens on Chats.
- Scheduled is its own section on every platform: job list, then the job's page with status, schedule, Pause, Resume, Run now, Delete, a banner when the job needs the user (answered in its sub-chat; no Approve button), and its sub-chat with the direct input. Settings › Jobs leaves the Mac. A job with no sub-chat yet opens with no runs. The phone caches the job list on disk and shows its time.
- `job_list` gains an optional `schedule`, the Mac's wording (the summary's first line, or the cron text until a summary exists).
- Badges: a small dot, no number, on Chats when a thread needs attention and on Scheduled when a job does. Settings and Search have none.
- The tab bar hides inside a chat. A push tap, citation or search hit switches to Chats and resets it to list → target.
- ⌘1 Chats, ⌘2 Scheduled, ⌘N New chat, ⌘F search, ⌘, Settings.
- Only the latest version runs: the layout for a host without `threads-v1` and the UI gates on `threads-v1` and `jobs-v1` go.
- Delivery: branch `tab-bar`, PRs in order: decisions, docs and the `schedule` field; iOS; the Mac.

## 2026-10-14 — Chat UX: native navigation, offline history, optional Main chat (#405)
Source: owner, UX pass agreed on 2026-10-14 (issue #405).

- Native SwiftUI components and behaviour; the search role tab and `.searchable` replace the custom search field.
- Clients keep the whole history (not the 500-message / 30-day window), searchable offline; incomplete first sync is shown as such; attachments on demand and kept.
- One chat list by last visible message; blue and orange dots, a running spinner; no groups, pins, origin icons or counts.
- Main chat off by default, host-wide; it controls the global workflow; history kept when off.
- Launch starts a new draft; Quick Chat when Main is off; device-local drafts with files; links save the draft.
- Follow new messages only at the bottom; reading positions restored.
- Swipe Archive; Rename and Delete in the context menu; search includes archived chats (marked, filterable); Delete is permanent everywhere, says long-term memories stay, and Stop and Delete waits for a confirmed stop.
- Queued messages auto-send; 24 h expiry from Send; an unsent reminder at 30 minutes by default, configurable or Off, cleared by host receipt only; grouped.
- Implementer readings: the Main chat's row takes the same actions (its Delete stops its work, then removes its messages, the work they started and secretary-started threads left empty; user-started chats stay); a Main message arriving while Main is off is refused with the reason, never rerouted; a grouped reminder fires when the oldest waiting message reaches the age and covers every message waiting then; Repair of the same host keeps that host's history, drafts and outbox.

## 2026-10-15 — Yorozu as an OpenClaw channel (#415)
Source: owner, tracking issue #415 (Decisions, 2026-10-15).

- Yorozu drops the secretary system completely and becomes an OpenClaw chat channel, a peer of Signal or Telegram: a TypeScript channel plugin (`plugins/openclaw-yorozu`) inside the owner's OpenClaw Gateway talks over the end-to-end-encrypted relay to Yorozu client apps on iPhone, iPad and Mac. OpenClaw runs the agent, sessions, memory and cron; Yorozu only carries messages, with a Signal-like UX.
- Shape: Yorozu runs nothing of its own (no routing, classification, workers, coding agents, memory, jobs, Hermes or cua); all `Sources/ProjectXCore` engine code and the Mac host role go. No Mac host process: the plugin holds the host keys and the relay connection itself; a Mac bridge app only if the spike shows a plugin cannot. One multiplatform SwiftUI client app for iPhone, iPad and Mac, clients only. No backward compatibility: wire protocol v3, every device re-pairs once; old wire types, store and engine are deleted, not flagged off.
- Conversations: the client mirrors OpenClaw sessions, minimal (list, history, send and replies, new conversation, tool calls collapsed, attachments, push, read/unread, rename/archive/delete; no agent picker). The peer is the owner, not the device; session key `agent:<agent>:yorozu:direct:owner:thread:<convId>`. One agent from `channels.yorozu.agent`, default `main`. Only Yorozu conversations are listed. "+" makes a new `convId`; `/new` resets the session in place; other slash commands pass through as text. Titles come from OpenClaw's title generator (`utilityModel`); a manual rename (session `label`) overrides it. The Gateway transcript is the source of truth; clients cache and backfill from the plugin; new devices see full history.
- Status: ✓ sent = relay accepted; ✓✓ delivered = plugin received and decrypted; read = agent run started; typing from run start until the reply. Unread badge on agent replies until opened on any device, synced across devices, manual Mark as Read/Unread stays; the plugin stores the read cursor per conversation in its state dir. Replies arrive whole, chunked by length, no edit-in-place streaming.
- Pairing and security: `openclaw yorozu pair` prints the QR and `yorozu://pair…` link (relay URL, room id, host public key, one-time token and secret); scanned devices join the plugin's allowlist. Noise-style IK handshake per connection over X25519, HKDF-SHA256, ChaCha20-Poly1305 and Ed25519 relay frames. Client cache under Data Protection `complete`; client keys in Keychain, this-device-only, non-syncing; plugin keys in OpenClaw's credentials store, `0600`; push previews sealed; fingerprint on both sides at pairing. Transcripts on the Mac stay plaintext in OpenClaw's state.
- Transport: relay only; the direct path (port 8738) is dropped; the plugin only connects outbound and the Gateway opens no new port. The deployed relay also serves v1 on `main`, so relay changes stay backward compatible.
- Push and attachments: one push per finished agent reply via the relay's `notify`, preview (title + first line) sealed per device, none to a device with that conversation in the foreground; cron output into a conversation pushes the same way; no mute yet. Attachments both ways (`sendMedia`), 8 MB limit, sealed chunks under the relay's 1 MiB frame limit; the share extension stays; no voice notes yet.
- Crons: a Crons tab next to Chats lists all jobs on the configured agent (`cron.list`), disabled ones greyed, with name, human schedule, next run and last status (error on tap). No admin calls from Yorozu: "Edit in chat" opens a conversation with the draft `Change cron job "<name>" (id <id>): `. A job delivering into a Yorozu conversation (`delivery.channel: yorozu`, `threadId`) opens it from its row.
- Process: worktree + PR flow on `projectx`, one child issue per PR; the secretary is deleted only after the new path works end to end; tests and CI stay on hold.
- Supersedes #323 and #322; v1 → v2 migration stays a future topic.

## 2026-10-17 — Feedback on 0.8.0 from the iPhone

- The iPhone's tab bar hides inside a conversation; Chats and Automations use inline titles; previews are one line.
- Compose is `square.and.pencil` in the chat list's bottom toolbar (native, not a custom floating button), on every platform; the Mac keeps it in the window toolbar.
- Crons is renamed Automations (ja 自動化), `clock` icon kept. Supersedes the 2026-10-15 tab name.
- Settings replaces the Host sheet: a gear on iPhone and iPad, the ⌘, window on the Mac. Host-side changes from the phone: list and remove paired devices, and push on or off per device. Agent switching and tuning limits stay out. Supersedes "No admin calls from Yorozu" for these two.
- No push to a device while the app is in front on it (per device, not across devices); a minimal top pill instead, optional light haptic. Supersedes "none to a device with that conversation in the foreground".
- Reading a conversation clears its notifications on the other devices, including closed apps through a silent relay push; the relay change goes to `main`, backward compatible.
- Mockups in Claude Design only for large changes.

## 2026-10-17 — Upgrade from 0.5.0-beta, versioning and App Store

Grilling session with the owner. Plan: [upgrade-from-0.5.md](../upgrade-from-0.5.md).

- Only 0.5.0-beta installs upgrade, to 0.9.0-beta. 0.4.0 is not upgraded and the stable feed stays frozen. The owner checks each migration by hand; then all migration code is deleted. Fix forward only.
- Mac stays on GitHub Releases + Sparkle as `to.yumi.yorozu` (Developer ID, notarized), beta feed by default. This reverses the Mac part of "takes v1's identity" as `to.yumi.yorozu.ios` (#426). `projectx` merges into `main`; the release job is the one CI exception.
- Version 0.9.0. Visible build restarts at 1 per version; `CFBundleVersion` = major·10⁷ + minor·10⁵ + patch·10³ + build, because Sparkle compares that integer and the installed 0.5.0-beta is `10279` (TN2420: macOS builds rise across versions).
- Supersedes "every device re-pairs once": 0.5's host keys and devices carry into the plugin, and iOS copies `pairings` into `pairing-v3`, with QR fallback.
- First-launch migration on the Mac is fully automatic, including the plugin reload with capability acceptance (exception to click-to-write). 0.5 chats convert to conversations seeded with one plain `chat.inject` (header + last 40 turns); memory notes import; no bridge release.
- iOS goes to the public App Store (nothing was there before), manual release, no phased rollout. Review: a live review host, plus a fixture demo behind `YOROZU-DEMO` documented in the notes, following OpenClaw's iOS app. iOS shows a dismissible "Update available" row from Apple's lookup API.
- Release order: TestFlight assignment and the Mac appcast item go live together.
- Groundwork: schema versions on stored records, a protocol range one version back, additive changes, stable contracts, Sparkle `minimumAutoupdateVersion` for breaking jumps.
- Naming: app versions ("0.5", "0.9") in prose and migration code; no version in type names; the wire protocol stays an integer.

## 2026-10-15 — Superseded by the channel decisions: OWNER_DECISIONS.md lines as of 2026-10-14
Source: OWNER_DECISIONS.md before #417, kept as written. These areas were reversed by the 2026-10-15 channel decisions above: the secretary, threads and secretary UX, the Mac host and its UI, phone-as-mirror, delivery-mark semantics, the direct path, routing, workers, jobs, memory, Hermes and harnesses, role models, assisted setup and the setup CLI, and the R1–R3 ordering.

**Product and UX**

- Wording: the Mac running Yorozu is the **host**; paired devices are **client devices** (or **clients**), since they are iPads and iPhones now and may be Macs or non-Apple devices later. User-facing text says "host" and "client devices" (ja ホスト, クライアント端末), never "this Mac" or "iPhone(s)" for those roles; "Mac" stays where the text is about macOS itself. (2026-10-09)
- Threads: a sub-chat is a thread. The secretary starts one when work from the main timeline needs a worker, and the user starts one with New chat. One thread is one topic with its own persistent worker session, and work started inside a thread stays in that thread. The user can type in every thread: the secretary answers there, scoped to the thread, and replies itself, steers the thread's worker or starts work. A job's thread is the exception: its input still talks directly to the job's agent (Jobs). On the phone each task in a thread keeps its Stop button while it runs and Retry when it failed or is uncertain; they act directly through the Engine, without the secretary, and post the same acknowledgments a typed stop or retry does. The long-term goal is typed control reliable enough that the buttons become unnecessary. The Engine calls and `task_control` are implemented (PR B of #313), and phone sub-chats with the buttons in PR C of #313; typing in threads and New chat are implemented. (2026-10-13)
- In a thread, the user's messages are on the right and agent messages on the left, labelled Secretary or Worker. A thread the secretary started from the main timeline is marked with an icon in the thread list and a header at its top, "Started by Secretary from the main chat", that links to the message it came from. Implemented. (2026-10-13)
- A thread the user started never posts to the main timeline; its unread or finished badge in the thread list and a push notification that opens the thread cover it. Threads the secretary started keep their initial, progress and completion messages in the main timeline. Implemented. (2026-10-13)
- One chat list (2026-10-14, #405, replacing the pinned main timeline and the Needs attention, Running and Recent groups): every chat newest first by its last visible message (start, milestone and other progress notes, status changes and renames never move a row), each row its title, an excerpt of its last message, that message's time, one filled dot (blue: an unread reply or finished work, cleared by reading; orange: an unanswered question, a pending approval or a blocker, cleared only once resolved, and winning over blue) and a small spinner by the time while work runs; no origin icons or unread counts. Swipe a row to Archive; Rename and Delete (Stop and Delete while work is open) in its context menu, the same on the Mac. Implemented (#405). (2026-10-14)
- Mark as Read and Unread (2026-10-14): swiping a chat row from left to right (full swipe allowed), or its context menu, marks it read or unread by its unread state, on iPhone, iPad and the Mac. It never clears orange: a question, approval or blocker stays until resolved. Unread is a flag beside the forward-only read cursor, synced through the host; opening the chat clears it. Offered only while the host is connected and takes it. Implemented. (2026-10-14)
- Main chat is opt-in (2026-10-14, #405): off by default, one host-wide setting (`[general] main_chat`) every client shares (`host_settings`). It controls the global conversation and its cross-topic routing, not only its entry: while off the host refuses new Main messages with the reason (a client keeps them as Not delivered with Resend; nothing is dropped or moved to another chat) and every chat stands on its own; Main's history stays, readable from links and search. On, Main joins the one list unpinned, with the same row actions (Rename and Archive in `config.toml`; Delete stops its work, then removes its messages and the work they started on every device; chats the user started and memories stay). Implemented. (2026-10-14)
- Entry points and drafts (2026-10-14, #405): opening the app (the phone, the Mac chat window) starts a new chat draft; with Main off the Mac's menu-bar icon opens Quick Chat as a new draft. A draft becomes a chat only with its first message. Every draft (text and files) is kept on its own device across relaunches, never synced; Quick Chat resumes its unsent draft and starts fresh after a send or Discard; other drafts stay listed. A notification, citation or search link saves the current draft and opens its target message. A reader at the bottom follows new messages; anyone reading older ones stays put with the ↓ button; reopening a chat returns to where its reader left it. Implemented. (2026-10-14)
- Threads are named automatically from their first message, like the secretary's topics, and the user can rename them. Archiving is manual only, never automatic; an archived thread leaves the list and stays searchable. Delete asks for confirmation and removes the thread's messages permanently, from search and from the secretary's recall; memory already extracted from them stays, and the confirmation says so. Implemented. (2026-10-13)
- The secretary can search the messages of every thread, archived ones included, ranking the current thread first, and cites a hit with a link to its message, for example "In Kyoto: Hoshinoya, ¥28k". Implemented. (2026-10-13)
- The main timeline shows no topic labels, IDs or routing controls. Threads show their name. (2026-10-13)
- Layout: the Mac app is a menu-bar host. Clicking its icon opens a compact popover with the main timeline and its composer, or Quick Chat while the Main chat is off (#405). A Mac can instead be a client of another host Mac, as in v1, chosen in Settings (`general.role`); a v1 client Mac stays a client after the update (2026-10-11). The Activities window becomes the chat window: the chat list as its sidebar and the selected chat beside it with a composer; the popover keeps only the main timeline (2026-10-13, implemented). The iPhone is the full client with threads, controls and jobs (phone sub-chats and controls are implemented in PR C of #313, jobs in #319). Sections, the window sidebar and the tab bar are in the next line (2026-10-14). The Mac is the single source of truth, is assumed always running and keeps running when its UI closes; only Quit ends it. Settings is a standard macOS Settings window, opened with ⌘, or from the menu-bar menu, which also offers Open Quick Chat, Pair a Client Device…, the Direct Connection (LAN/VPN) and Keep Host Awake switches, and Quit. (2026-10-09)
- Sections (2026-10-14): one `TabView` with `.sidebarAdaptable`, a tab bar on iPhone and a sidebar on iPad and in the Mac chat window. Chats (`bubble.left.and.bubble.right`), Scheduled (`clock`), Settings (`gearshape`, iPhone and iPad only; the Mac keeps its Settings window, ⌘,) and Search (the search role: a tab on iPhone, the sidebar's search field on iPad and the Mac, ⌘F in the Mac window). The app always opens on Chats, on a new chat draft (#405): the one chat list, and on iPad and the Mac three columns (sections, thread list, open chat). The tab bar hides inside a chat. Scheduled is the job list and each job's page (status, schedule, Pause, Resume, Run now, Delete, a banner when the job needs the user, and its sub-chat with the direct input) on every platform; the phone caches the job list, and a job needing approval is answered in its sub-chat. Chats and Scheduled show a small dot, no number, when a thread or job needs attention. A push tap, citation or search hit switches to Chats and opens list → target. ⌘1 Chats, ⌘2 Scheduled, ⌘N New chat. No section customization. Only the latest Mac and phone run together, so there is no layout for a host without threads or jobs. The popover keeps only the main timeline. (2026-10-14)
- Settings are layered: tabs for everyone (General, Devices, Connection, Storage; Jobs moved to the Scheduled section on 2026-10-14) plus Harness and Advanced tabs shown while General › "Show Advanced settings" is on. Every tab shows all its content without scrolling: the window sizes to each tab, and a tab too tall for a 1080-point screen is split rather than scrolled (2026-10-09). General holds start at login, keep the host awake, notifications, appearance, YOLO, send key and global shortcut. Implemented (phase B of #312); settings can also be changed in `config.toml` or by asking in the chat. (2026-10-09)
- Devices: "Client devices" with their names (the device's model, such as "iPhone 17 Pro", renamable on the Mac, because iOS hides the user's device name), online or last seen, and Remove; Pair a Client Device lives here (and in the menu-bar menu), mints a code only when pressed, and shows the paired device's name with Done once one pairs. Implemented (phases A and B of #312). (2026-10-09)
- Connection: relay status, the relay URL (editable, with a warning that every phone must pair again) and direct-path diagnostics. Harness: the harness, transport, Gateway URL (loopback only), native enrollment and the per-role model pickers. Advanced: the dev repo and integrations. Storage shows run mode, data folder and agent id read-only while Advanced settings are on. Implemented (phase B of #312); the direct-path diagnostics are implemented in #315. (2026-10-09)
- iPhone Settings gains a Connection section: Direct connection toggle, diagnostics (path, last error), relay host, Mac key fingerprint, paired since, Mac and phone versions, and Copy diagnostics. Remove host and Repair also remove the phone's record on the Mac; a phone that cannot reach the relay removes its pairing anyway, and the Mac's record stays until it is removed in Mac Settings. The Mac-side removal (`device_remove`, sent by Remove host and Repair) is implemented in PR B of #313; the rest is implemented in phase B of #312, and the Direct connection toggle and the path diagnostics in #315. (2026-10-09)
- Start at login is on by default, and onboarding says so (#317). The login item itself is implemented; the setup step is in the step engine (#317). (2026-10-09)
- Onboarding is designed for a new person; the owner and existing users go through the same flow, which skips whatever is already in place, and owner specifics come from `config.toml`. A first-launch setup window runs welcome → harness → models → integrations → YOLO → start at login → pair a client device → done, skipping completed steps, and reopens from Settings › General ("Run setup again…") next to a status row ("Ready" or "N items need attention"). Setup completion is stored in `config.toml`, never in v1's `onboardingCompleted` key. Moving v1 users to v2 is a separate issue (#322). Implemented (#317): the step engine, `[setup]` in `config.toml` and the setup window, whose rows are Harness, Connect to the Gateway, Models, Computer use, YOLO, Start at login and Pair a client device, plus the optional `yorozu` command link; the Gateway row is in the owner-approved mockup. (2026-10-09)
- Block or warn: the composer is blocked only when nothing could answer (no harness at all), with a plain reason and "Fix…"; partial problems show a warning banner with "Fix…". Errors read in plain language. The phone shows the same Mac readiness (contract 0.7). The readiness model, plain-language errors, the wire event, the phone line, the Mac composer state and the banner are implemented (#317). (2026-10-09)
- Pairing: the iPhone app claims the https pairing link again (`applinks:yorozu.yumi.to`), so the system Camera opens Yorozu; v1 and v2 share the iOS bundle id, so the website's association file already covers v2. The Mac shows the key fingerprint and the pairing code as text, and the wording matches on both devices. Implemented (#317). (2026-10-09)
- Delegated work gets an initial, progress and completion message in the main timeline. The secretary writes the initial message in its own words, naming the task, from its routing call (no extra model call); boilerplate such as "I'll work on that in the background" stays banned. Progress messages come from worker milestones, one line at most about every 2 minutes, none for tasks that finish quickly; the completion message is the result. Initial and progress messages never notify. Implemented (#362). (2026-10-10) The menu-bar icon and the popover header show running work. While the secretary routes a message (from Send until its reply or delegation), a typing-style "thinking" bubble shows in the main timeline on both devices, next to the global working spinner; per-topic status lives in the phone's sub-chat list. The Engine exposes the routing state, and the routing flag on the wire is implemented in PR B of #313; the bubble is implemented on both devices in PR C. Steer, stop, correction and failure notices stay short and factual, and app-generated notices never enter the secretary's context. (2026-10-09)
- Notices are compact system rows with an icon, distinct from answers; failures read in plain language with a Details disclosure for the raw error. New notices are stored as a code plus parameters and rendered in the user's language at display time. Implemented on the Mac and the phone (#311). (2026-10-09)
- A finished result goes into the main timeline at once. A background completion does not change the active topic. Results are stored without the `Regarding “…”:` prefix and a quoted, tappable reply header is drawn from `replyTo` at display time; Copy copies only the answer, and old results keep their stored prefix. Implemented (#311); old results are shown as stored, without a header. (2026-10-09)
- Worker activity (public messages, progress and tool events, never private reasoning) appears in the sub-chat at message granularity, never in the main timeline. A tool row names the real tool behind `tool_call` and the app it targets, never arguments, for example "cua: type_text in TextEdit". (2026-10-09)
- Timeline: day separators, the exact time on hover (Mac) or long-press (phone), and "sent … · delivered …" on delayed messages. The view stays put while the user reads, a ↓ button appears, and sending jumps to the bottom. Implemented on the Mac and the phone (#311); the delay line is implemented in #314, under the bubble on the Mac and in the message's details on the phone. (2026-10-09)
- Search covers everything on both devices: ⌘F in the Mac popover and a search field on the phone. The Mac searches its full history with a full-text index (SQLite FTS, like memory) and the phone sends its queries over the relay; a hit jumps to the message in context. Phone search covers sub-chats as well as the main timeline. The index (message bodies and sub-chat worker events) and the engine call are implemented; phone search over the relay is implemented in PR B of #313; the Mac's ⌘F bar is implemented (#311) and searches the main timeline; the phone's search UI is implemented in PR C of #313. (2026-10-09)
- Mac attention: a dot on the menu-bar icon and macOS notifications for results, failures and questions; tapping one opens the popover at that message. Both can be switched off in Settings, and a destination setting chooses this host or client devices. The dot and the notifications are implemented (#311); the Settings switch and destination are implemented (phase B of #312), and the Phones destination with push (#320), which shares the Mac's classifier. (2026-10-09)
- An optional global shortcut opens the popover: preset ⌥Space, off by default, enabled or changed in Settings › General. Clicking the menu-bar icon is the default way in. The shortcut is implemented (#311), and so is its Settings row (phase B of #312). (2026-10-09)
- Phone: a long-press menu with Copy, Share and Show details; a draft over 6,000 bytes shows a hint and offers "Send as text file" (also on the Mac); an empty state says what Yorozu does with an example; Send always works (outbox). The long-press menu, the over-limit hint and the empty state are implemented (#311, the hint and the empty state on the Mac too); the outbox is implemented (#314); "Send as text file" is implemented on both devices (#316). (2026-10-09)
- On a worker failure or lost connection, post a brief notice; the user says "retry" to continue in the same sub-chat. There is no automatic retry, and a run's real status is reconciled before any retry so no duplicate starts. A context-overflow failure gets a specific message and no retry offer, since a plain retry would fail the same way. (2026-10-08)
- A new request blocked by an uncertain task reconciles that task's run first. Confirmed stopped: the task is retired with a notice and the new work starts. Completed: its result is delivered. Still running or unknown: it keeps blocking and the user is told why, so no run is duplicated. A dismiss action for stale uncertain tasks comes later. (2026-10-09)
- A message stays capped at 6,000 bytes; long text is a job for attachments, not a higher cap. (2026-10-08)
- No in-app memory view, editor or reindex control. Memory stays reachable as Markdown files; Settings › Storage shows the memory folder and the files folder with their sizes and Show in Finder (implemented in phase B of #312; the files folder reads "Not created yet" until the first launch with #316 creates it). (2026-10-09)
- Input is text plus attachments of any file type, in both directions: the user attaches files in either composer, and workers can hand files back with their results. At most 10 files a message, each at most 50 MB; a message may carry files and no text. Photos and other images are downscaled to 2048 px on the long edge by default, each with "Send original". Composer methods: on the Mac drag-and-drop, paste and a file picker; on the phone the photo library, the camera, Files and paste (the iPhone share sheet is #322). Privacy: no extra step; attachments are treated like typed text. Implemented (#316). (2026-10-09)
- Attachments are stored visibly at `~/Yorozu/files/<YYYY-MM>/<YYYY-MM-DD_HHMMSS>_<sanitized original name>` (`_2`, `_3`… on a clash), never in a repo checkout or worktree. Files are kept forever and deleted by hand in Finder; a missing file shows "File no longer available" on both devices. OpenClaw's own media copies are left alone. Implemented (#316). (2026-10-09)
- Phone attachments: with the Mac away, a message with files waits on the phone, text included, and uploads when the Mac is reachable (the relay's 5 MiB buffer holds text only). Previews (thumbnails, file rows) download automatically; a full file downloads on tap, opens in Quick Look or the share sheet, and stays in the phone's cache. Implemented (#316). (2026-10-09)

**Phone sync**

- The phone is a mirror of the Mac with control. The Mac is the only source of truth; the phone sees what the Mac knows (sub-chats, worker progress, topic status) and can control work. The mirror (records, catch-up and the cache) is implemented in PR B of #313; the phone's sub-chat UI is implemented in PR C. (2026-10-09)
- Reliability comes before new capabilities. Two message-loss bugs are fixed: frames the relay replays from a known phone are kept and processed, and acked only once the Engine has stored or refused them; a message stored but never routed before a quit is routed on the next launch if it is less than 24 hours old. Implemented. (2026-10-09)
- Contract 0.7 is a clean break for v2's own phones: the Mac speaks only 0.7 and a 0.6.x phone gets a clear "Update Yorozu" through the peer-info handshake. New events travel inside the existing end-to-end-encrypted envelope, so the deployed relay does not change. The thread id field stays and `"main"` is never hard-wired. Implemented in PR B of #313. Threads reach phones as an additive capability within 0.7, shipped to the Mac and the phone together; a phone without it still gets the main timeline. Implemented. (2026-10-13)
- Full history on clients (2026-10-14, #405, replacing the history window): every client keeps the whole history (titles, full message text, read state and tombstones) in an encrypted local store under iOS file protection, backfilled page by page from the start (`history-v1`), resumable, then kept current by change sequence; deletions apply on reconnect and a backfill never brings a deleted chat back. It cold-launches offline, lists active and archived chats and searches them on the device; an unfinished first sync says so rather than showing an empty list. Full attachments download on tap and stay. Implemented. (2026-10-14)
- Read state is synced: one "last seen message" cursor held by the Mac, an unread marker or divider, reading on one device clears it on the other, and the cursor feeds the menu-bar dot and the phone's push badge (#320). The Mac's cursor table is implemented; the cursor on the wire (the Mac applies it and sends it to phones; the phone's call to move it) is implemented in PR B of #313; the divider on both devices, the phone's and the popover's cursor moves, and the menu-bar dot following the cursor are implemented in PR C. (2026-10-09)
- Connection status: after a return from the background and on a fresh launch, the phone shows the last known status for 3 seconds while reconnecting, then the real status. While disconnected, working and topic status read "status unknown", never idle. Message marks are never faked. Implemented in PR B of #313 for the connection status and the working flag, and in PR C for topic and task statuses. (2026-10-09)
- Delivery marks, Signal's system without its icon files (AGPL-3.0), on every user message on both devices: Sending, then Delivered (the relay or the Mac has it), then Read (the Mac started routing it), only forward; Not delivered after the 24-hour deadline or a refusal, with the reason, Resend and Delete, and only Resend moves it back to Sending. SF Symbols in the text colour, icon only: `circle.dotted` (spinning while a frame is in flight, still while waiting for a connection), `checkmark.circle`, `checkmark.circle.fill`, and a red `exclamationmark.circle`. Tapping the mark shows each state's time. The Mac shows Delivered once stored and Read once routing starts, and records the read time in one column, existing history marked Read; it also keeps the phone's send time (`sentAt`) for the delay line and the secretary's message age. VoiceOver reads the state as part of the bubble and announces only Not delivered. Implemented (#314); the final visuals follow the Claude Design pass. (2026-10-09)
- Offline sending: the phone keeps a persistent outbox, so Send always works and the draft clears at once. While the Mac is away the relay holds messages (24 hours, 5 MiB per room) and the phone need not stay connected; late messages are delivered normally, the Mac shows the delay ("sent 02:14 from phone · delivered 09:30") and the secretary is told the message's age, never its device. Each message expires 24 hours after it was sent and then shows Not delivered. Queued messages go by themselves when the link returns. Unsent reminder (2026-10-14, #405): when the host has not confirmed receipt (its receipt or stored copy; the relay's acceptance does not count, nor does whether the assistant has read it) by 30 minutes after Send (Settings: 15 min to 6 h, or Off), one grouped notification fires, scheduled with the system so it fires while the app is suspended; a receipt or cancellation removes it. An expired message shows Not delivered with Resend, which starts a new 24 hours; the expiry notice fires at the deadline. Notification permission is asked the first time a message has to wait for a connection, and a denial is respected. Implemented (#314, #405). (2026-10-14)
- Direct path: besides the relay, the phone reaches the Mac directly on the same LAN or a private VPN (Tailscale/WireGuard); the relay stays the fallback and keeps its 24-hour buffer. Selection is automatic, and the path in use shows only in Settings diagnostics on both devices, never in the chat. Discovery: the Mac sends its LAN and VPN addresses in the sealed peer info over the relay, the phone stores them with its pairing, and the listener port is fixed; Bonjour only later, if needed (#322). Implemented in #315. (2026-10-09)
- The iPhone's "Direct connection (LAN / Tailscale)" setting is off by default; turning it on is when iOS asks for Local Network access, and until then the phone uses the relay only. Denied, Settings points to Privacy › Local Network. Implemented in #315. (2026-10-09)
- The Mac listener lives in the Mac app's relay host, in Swift (`NWListener` with WebSocket), on Wi-Fi/Ethernet and `utun` interfaces only. Each phone has a route, relay or direct, that its latest authenticated hello moves, and delivery follows the route, so the LAN keeps working through relay outages. Both paths carry the same sealed envelope and the same per-device sequence counter. The direct handshake is mutual and domain-separated: the phone signs `yorozu-direct-v2|room|nonce` and the Mac proves it holds the paired key. Implemented in #315. (2026-10-09)
- The phone races direct candidates at once against the relay about 300 ms later; the first authenticated `joined` wins, and the race never runs through `hello`. LAN candidates only on Wi-Fi or Ethernet, VPN candidates only while a VPN is up. It re-races on foreground, network change and failure, upgrades from the relay to direct make-before-break, backs a failed candidate off 30 s doubling to 10 minutes (reset on a real network change), and never downgrades while the direct heartbeat is healthy; v1's `skipDirect` is not ported. Liveness: the phone pings every 10 s with a 5 s deadline, the Mac drops direct links silent for more than 30 s and closes them when it sleeps, and the host holds a `ProcessInfo` activity against App Nap. Every path switch is a new session with catch-up and the outbox resend; direct never buffers. Implemented in #315. (2026-10-09)
- Direct path hardening after the security review, implementer readings rather than owner answers: the phone speaks first with a `probe` (room and nonce) and sends its key and signed `join` only after the Mac's `joined` proves the Mac's key, so the phone's identity never reaches an unproven listener; the room, a stable hash of the Mac's key, still travels in cleartext. Candidates and the addresses the Mac accepts connections on are private only (RFC 1918 or ULA, plus 100.64.0.0/10 on `utun`) and must arrive on a Wi-Fi/Ethernet or `utun` interface. The Mac refuses new direct connections with 4000 from sleep until wake, and a 4000 backs off every candidate on the phone so it takes the relay; a 4002 is not a failure and re-races at once; a live relay hello within 2 s of a direct link's own hello leaves the direct route alone. Implemented in #315. (2026-10-09)
- No wake-on-LAN or waking the Mac from the phone; Keep Mac awake (off by default, Settings › General) covers it. Implemented in #312. (2026-10-09)
- The direct listener's port and switch were open questions taken at their defaults by the implementer, not answered by the owner: port 8738 (not v1's 8443), `[direct] enabled = true` and `port` in `config.toml`, both security-relevant; a phone still dials directly only once its own setting is on. Implemented in #315 ([status.md](secretary-status.md#open-items)). (2026-10-09)
- Notifications carry the message's actual content on the host and on client devices (2026-10-10, replacing content-free text). On client devices the preview is end-to-end encrypted: the host seals it, the relay forwards an opaque blob, and a Notification Service Extension on the phone decrypts it, so Apple and the relay never see the text; the deployed relay already forwards per-phone sealed previews (v1's `previews` map), so no relay change is needed. Implemented (#364); the line below holds for clients without the extension. (2026-10-10)
- Push notifications through the relay's existing APNs path: the lock screen shows only fixed, content-free text ("Yorozu replied"), never message content, and there are no sealed previews. Triggers: a result, a failure, a result that asks a question, and the Mac coming back online. The app badge is the unread count from the synced read cursor. The notification destination setting decides where notifications appear: this Mac, phones, and later a Mac client; "phones" is push. The outbox and expiry notifications stay local (#314). No model learns a message's device, v1 keeps working, and v2 iOS builds stay internal. Implemented in #320 with no relay change: the Mac sends only the four classes the deployed relay accepts (result `reply`, failure `failed`, question `approval`, back online `done`) and the phone words each fixed relay key for v2 in English and Japanese; the on-device checks are pending. (2026-10-09)
- Push open questions taken at their proposed defaults by the implementer, not answered by the owner (#320): results are worker and posted job results, secretary replies and unconfirmed-change notices; questions use #311's signal, with no `asksUser` field; "Mac back online" fires once when a relay registration follows at least 10 minutes offline, the app's downtime included, at most hourly; the phone sets the badge itself and removes delivered pushes the cursor passes; no banner over the main timeline, a tap opens the message; one permission request shared with #314, which a paired phone also makes at a foreground launch if never asked (chosen over open question 7's default, since the phone cannot see the Mac's destination; a background launch asks nothing); pushes only with notifications on and destination `phones` ([status.md](secretary-status.md#open-items)). (2026-10-09)

**Routing**

- Every message first goes through a small-model classification step that sees the message, the last few messages and, when its model accepts images, the message's image thumbnails: `new` (a new subject), `oneoff` (small talk or something the secretary answers itself) or `continue` (an earlier subject), with search terms for `continue`. Then the secretary model reads the message with the last few messages, the candidate topics, each with its one-line summary, and memory search. It replies to quick turns, asks for clarification and coordinates, and running work never blocks it. The extra small-model call per message is accepted; a reply pin or the identical-message rule skips it. Implemented. (2026-10-07, classification 2026-10-10)
- Substantive thinking, analysis, research, tool use and code are delegated automatically; the secretary does not try them first. (2026-10-07)
- A follow-up is found by search, not by being the latest topic: the classifier gives search terms in English and Japanese, the chat search indexes and topic labels and summaries are searched, topics are ranked by hits and recency, and the 5 most recent topics are always candidates. The secretary picks one; if none fits it sees the next 5 by recency, at most 3 rounds in all, and then a new topic is created silently, with no question to the user. If two candidates stay plausible, one internal review by a stronger model runs, then the user gets a short clarifying question. Implemented. (2026-10-07, search 2026-10-10)
- A topic is one concrete matter the user would follow as its own thread (an errand, decision, purchase, trip, project or problem), not a broad area: moving the washing machine and the new home's internet are two topics, not one "Personal" topic. The app's own UX, memory and code stay under one broad topic, named by `self_topic` in `config.toml`. No automatic topic merging or splitting, except attaching a new sub-chat to an existing topic (below); existing broad topics stay as they are. (2026-10-09, narrower topics 2026-10-10)
- Small talk is never filed: a `oneoff`, such as "hello" or something the secretary answers without a worker, gets a reply and no topic. Anything that needs a worker gets a topic: a `oneoff` that turns out to need work becomes a new topic, and a `new` subject starts a new sub-chat, a vague one with too little context included. A topic label names the subject in the user's words, never a tool and never an invented subject: a test of "use Codex to …" on Yorozu is Yorozu work, under `self_topic`. Once a new sub-chat turns out to belong to a topic that already exists, it is attached there: its context joins the original topic, the discussion continues in that topic, and its own history stays where it is. This replaces "No automatic topic merging or splitting" for this case. Implemented (#348). A thread the user starts with New chat is a topic from its first message, small talk included, and messages typed in it stay in its topic (implemented). (2026-10-13)
- Topics keep a one-line summary, updated by the memory extraction that already runs after each result (no extra model call); routing shows it with each candidate and topic search matches it. Implemented. (2026-10-10)
- Owner-specific routing hints are settings with generic defaults: `personal_knowledge` (where the user's personal notes live) and `self_topic`. (2026-10-09)
- The secretary sees only a description of attached files (name, type, size, path), never their contents; work that needs a file's contents is delegated. For a message with files and little or no text it acts when the context is clear, else asks one short question. Implemented (#316). The classification step also gets thumbnails of the message's images when its model accepts images (the `models.list` `input` check), so it can tell a floor plan from a screenshot; other files stay name, type and size only. Implemented for OpenClaw; Hermes takes no image input from Yorozu, so there it gets the descriptors only. (2026-10-09, thumbnails 2026-10-10)
- A reply links to the replied message's topic without categorization (it skips the classification step): the secretary still picks the action, but the topic is the replied message's, never a new or another one. A reply to an untopiced message routes normally. The Mac popover offers Reply first in a message's context menu, with a quote bar above the composer. (2026-10-09)
- A change to running work steers that same task and never starts a separate one. Steering is live by default: the change goes into the running task, not after its current step (on OpenClaw, `chat.send` with `queueMode: "steer"`); the follow-up turn is only a fallback when the live inject is refused. Implemented (#363). (2026-10-10)
- Wrong-topic recovery stops the mistaken work if it is running, sends the instruction to the intended existing topic and leaves the mistaken history where it is. A stop is reported as confirmed only after it is acknowledged. (2026-10-07)

**Workers**

- The secretary/worker split is core architecture: workers run in topic sub-chats in bounded parallel lanes. (2026-10-07)
- One persistent sub-chat per topic, reused for later requests. Before each thinking task Yorozu reads the topic session's token count and, at about half the model's usable window, compacts the session as its own step outside the task. The compaction is noted in the topic's sub-chat; a failed compaction posts a short failure notice in the main timeline. (2026-10-08)
- Workers are sub-agents of the active harness (OpenClaw or Hermes Agent), not separate entities; the secretary only delegates to workers and never picks a coding tool. Claude Code and Codex are not hard-coded, and coding does not always mean Claude Code. Implemented (#351). (2026-10-09)
- Coding agents run through Yorozu: Claude Code, Codex and others are called through a Yorozu-owned process that runs the agent's terminal command, and its live output streams into the task's sub-chat on the Mac and on clients. Agents are data (`[coding_agents]`), the built-in `claude` and `codex` offered when installed; workers call them with `Yorozu agent run`. Implemented (#351). (2026-10-09)
- No hard-coded repository: the user works across many repositories. The self-development setup (`dev_repo` = Yorozu's checkout, merge into `projectx`, then `build_native.sh --restart`) and the coding contract are dropped. Implemented (#351). (2026-10-09)
- Workspace: a workspace folder for agents, default `~/Yorozu/workspace`, set in Settings › Storage (`[workspace] path`). Downloaded files and cloned repositories go there, and each task or sub-chat gets its own folder inside it as its working area. Implemented (#351). (2026-10-09)
- File access: agents' file access is not limited by default; an optional setting limits it (`[workspace] restrict`; enforced for coding agents, a contract rule for workers). Implemented (#351). (2026-10-09)
- Coding agents run with full access by default: with `[workspace] restrict` off, the built-in `claude` and `codex` run unsandboxed (`--permission-mode bypassPermissions`, `--sandbox danger-full-access`); with it on they run sandboxed to the workspace. A `[coding_agents.<name>]` entry can set its own command. (2026-10-10)
- Yorozu sets no size limit on what workers return: the UI renders any length and long results travel to the phone in chunks (chunking: PR B of #313). The secretary and memory extraction get excerpts of results within their own budgets. Any length renders in full with proper formatting (code blocks that scroll sideways with Copy, real tables, rules, inline images) and no "Show more". The shared renderer is implemented on the Mac and the phone (#311); inline images are local files only, and remote image URLs stay links. (2026-10-09)
- Topic workers run at full permission with the harness's default tools. (2026-10-09)
- Files reach workers as paths: one `Attached document: <path>` line per file in the worker input, and images also as direct model input when the worker's model takes images (the per-call `models.list` `input` check decides; otherwise the path alone). Workers return files as a `files` array in their final JSON or as OpenClaw `MEDIA:<path>` lines; any readable path is accepted except private folders and key files (implementer safety reading, see the decisions log), and Yorozu copies each into `~/Yorozu/files/` and attaches it to the result, under the same limits. Steer, retry, redo and correct carry the files. Implemented (#316). (2026-10-09)
- Sub-chats may show intermediate images that workers choose to share, synced to the phone; this amends the cua rule that kept screen content out of progress messages. Accessibility-tree dumps and clipboard contents stay out, and screen content never goes into memory. Implemented (#316); the Mac has no sub-chat UI, so they show on the phone. (2026-10-09)
- Workers carry a request through end to end, including commit, merge, push, rebuild and restart when the chat asks for it, and ask only for what only the owner can do (logins, approvals, secrets). They take no unrequested destructive or outward-facing action and leave the owner's uncommitted files untouched. (2026-10-08)
- Integrations are data, a plugin system without code loading ("no plugin loaders" stays): each declares its MCP servers, worker rules, setup steps and read-only checks, settings and an on/off switch. Built-ins ship with the app; new ones are added as data, shipped or written in `config.toml`. Checks run only during setup, while Settings is open and on "Check again"; permission grants stay manual, with a copy button. Implemented (#317). (2026-10-09)
- CuaDriver is optional: computer use is the first built-in integration, `cua`, on by default and switchable; turning it off removes its MCP server and its worker rules. Implemented (#317). (2026-10-09)
- Workers operate the Mac through cua: approach A first, with the computer-use rules in the worker prompt and no separate executor until collisions or timeouts call for one. (2026-10-08)
- Yorozu keeps the list of MCP servers its workers may use, so switching harness does not move tool registrations. The list is data only: harness adapters apply it, and Yorozu never starts servers or runs tool calls. Workers get it; coding agents run by Yorozu use their own configuration. It lives in `config.toml` as `[mcp_servers.<name>]` tables (`command`, `args`), replacing `mcp-servers.json`; enabled integrations add their own servers (#317). (2026-10-09)
- Yorozu changes its own settings when asked in the chat: a worker edits `config.toml` and the app reloads it. An invalid edit keeps the last valid settings and posts a notice. Security-relevant settings (MCP servers, relay URL, direct connection (`[direct]`, implemented in #315), harness choice, Advanced items) need the user's yes in the chat first, as a prompt rule. (2026-10-09)
- YOLO mode, off by default, offered during onboarding (#317) and switchable in Settings › General, lifts the "ask first" rules for outward-facing steps the user requested in apps and for the risky cua tools. Settings changes and unrequested actions still need the user's word, and the hard limits always hold: no secrets, never take focus, never touch other agents' sessions. Implemented in the worker prompts, with the switch in Settings › General (phase B of #312). (2026-10-09)
- Workers always treat the Mac as unattended, whichever device the request came from: they never take focus and never use foreground input (no `bring_to_front`, foreground delivery, focus-taking shortcuts or `open` without `-g`), with or without the user's approval, YOLO included. An app that accepts only foreground input is reported as not doable in the background. Implemented in the worker prompts. (2026-10-09)
- No model ever learns which device a message came from: secretary and worker inputs carry no device origin. (2026-10-09)
- Computer-use concurrency stays in the prompts: each worker run uses its own cua session and never retries a timed-out action blindly. Across topics, two tasks may operate the same app at once until a code lane of one is added, which comes only if collisions or timeouts show up. (2026-10-08)

**Jobs**

- Yorozu runs scheduled jobs itself, with its own scheduler in the Mac app, never through the system `cron`, launchd, OpenClaw automations or Hermes cron (those are reference only). AI work runs through whichever harness is active. Users create, change, pause and remove jobs in plain language. Implemented (#319). (2026-10-09)
- Job definitions are data in `jobs.toml` next to `config.toml`, editable by hand, by a worker, or through Scheduled on the Mac and the phone (Pause/Resume and Delete write the file). The app watches and validates the file; an invalid edit keeps the last valid jobs running and posts a notice naming the problem. Implemented. (2026-10-09)
- One topic per job: its own sub-chat and persistent worker session, so runs build on each other. A message about a job in the main chat is routed to that job's agent. Implemented. (2026-10-09)
- Schedules are time-based (intervals, calendar rules, one-shots), all stored as cron expressions and evaluated by Yorozu in the Mac's time zone. A one-shot retires after it runs. The Mac app is assumed always running: there is no missed-run handling. Condition watchers come later (#322). Implemented. (2026-10-09)
- A job is a pure script, an AI task, or a script whose output feeds an AI step (always, when the output changed, or when it matches a pattern). AI is always optional. Implemented. (2026-10-09)
- Scripts run as child processes of Yorozu, as the user's account, in `~/Yorozu/jobs/<job>/`, with a timeout (10 minutes by default, per job), output captured to the sub-chat, independent of the harness. A new or changed script needs the user's yes in chat, even in YOLO mode. Implemented; the gate stops unattended runs of unseen code and is not a sandbox. (2026-10-09)
- Posting is per job: every result to the main timeline, or only notable ones; if the user did not say, the job's agent asks. Failed runs are notable. The full output of every run stays in the job's sub-chat. Implemented. (2026-10-09)
- Runs never overlap: while a run is still going, the next slot is skipped with a note. AI steps use the job topic's worker on the worker model; a job may name another model (not yet implemented). A job's `executor` key is ignored since coding executors were dropped (#351). (2026-10-09)
- Each job has an exact spec in `jobs.toml` and a user-facing summary generated from it and kept in sync. Implemented. (2026-10-09)
- Jobs list in Scheduled (Sections) on the Mac and the phone: name, schedule in plain words, next run, last result, Pause/Resume, Run now and Delete; opening a job shows its page with its sub-chat and the job input. Implemented: the Scheduled section of the Mac chat window (Settings › Jobs until 2026-10-14), Scheduled on the phone, and the `job_list` and `job_control` wire events under capability `jobs-v1`; the phone side is not yet checked on a device. (2026-10-09, Scheduled 2026-10-14)
- Job input: each job's screen has an input that talks directly to that job's agent, with no secretary routing; the conversation stays in the job's sub-chat. Typing in other threads goes through the secretary (Product and UX). Implemented. (2026-10-13)

**Memory**

- Memory is automatic, persistent, owned by the user and the most important part of the product; the user never has to say "remember this". (2026-10-07)
- Keep useful topic knowledge as well as personal facts, preferences and decisions. Attribution stays separate: a pasted source claim or an assistant analysis never becomes a user belief or a verified fact. (2026-10-07)
- Markdown files are the single source of truth. The SQLite index is disposable and rebuilt from them; no filesystem watching. Vector retrieval may extend this later. (2026-10-07)
- Memory is global, not partitioned by topic, and retrieved selectively. (2026-10-07)
- Past versions of a note stay in the note until it would exceed its size cap; then the oldest move to a per-note history file, `<memory root>/history/<id>.md`, that search and the index skip. No version is lost. (2026-10-08)
- Forgetting deletes the Markdown memory and refreshes the index. Chat history is never deleted, redacted or rewritten. (2026-10-07)
- Workers may edit memory files, scoped to the memory directory. (2026-10-07)
- Attachments reach memory only through the conversation: extraction reads message text, never file contents, and a note may cite an attached file (name and path) as its source. Sub-chat images never reach extraction. Implemented (#316). (2026-10-09)
- App state goes in Application Support and the index in Caches (Apple guidance); the Markdown memory is visible in `~/Yorozu/memory`. Settings are `config.toml` in the same Application Support folder. Schema changes are GRDB migrations that run at launch; moving data between folders or machines is done by hand. Paths: [docs/setup.md](secretary-setup.md#where-data-lives). (2026-10-09)

**Platform and release**

- iPhones are clients of the host Mac through v1's end-to-end-encrypted Cloudflare Workers relay, reused as a deployed service, with v1's chat input UI. New client and host code stays Swift. The relay may be changed when that is the better design. (2026-10-08)
- Website (https://yorozu.yumi.to, `apps/web` on `main`) for 0.7.0: it describes only shipped behaviour, and every v1 claim that no longer holds is rewritten, not left in place. The paste-in message is published verbatim from [docs/setup.md](secretary-setup.md#paste-in-message). v1 keeps working: `/pair`, the AASA file, and the privacy and terms pages. The public TestFlight link stays on v1 until v2 is released to that group. No personal data on the site, in screenshots or in `Start.md`; screenshots come from the 0.7.0 UI. The change is a PR to `main`, with `Start.md` in the same PR, that the owner merges at release ([docs/release.md](../release.md#website)). Its open questions run at their proposed defaults ([docs/status.md](secretary-status.md#open-items)). (2026-10-09)
- CuaDriver stays a separately installed, optional app. Yorozu does not bundle it or keep its daemon running; `cua-driver mcp` starts the daemon itself. (2026-10-09)

**Engineering**

- Stack: SwiftUI with selective AppKit, structured concurrency, GRDB/SQLite, Markdown memory with an FTS5 index, a Swift client that drives separately installed harnesses (OpenClaw, Hermes Agent), and swift-toml for `config.toml`. Not used: Electron, Tauri, web frontends, SwiftData, Core Data, agent orchestration frameworks, vector services, plugin loaders, Python in the repo, or a separate Yorozu process for a harness. (2026-10-09)
- Assisted setup writes only Yorozu's own entries into the harness config, and only when the user clicks: for OpenClaw its agent entry, its model allow-list entries and its `yorozu-*` MCP entries, through `config.patch`. It never touches other agents' entries, providers or logins. Installing software, signing in to providers and granting permissions stay manual; Yorozu gives the instructions. Implemented (#317). (2026-10-09)
- Agent id: a new person gets the generic `yorozu`; the owner keeps `projectx` through `config.toml`, with session keys unchanged. Implemented (#317). (2026-10-09)
- Setup CLI: a Swift subcommand of the app binary (`Yorozu.app/Contents/MacOS/Yorozu setup …`), with an optional `yorozu` link on `PATH`. `setup --json` prints the next step (what it checked, plus any question with id, text, choices and default), and `setup answer <id> <value>` applies an answer and prints the next one. One step engine backs the CLI and the setup window. A short message the user pastes into an existing agent (Claude Code, Codex, OpenClaw…) has that agent drive the CLI and ask the questions; it lives in [docs/setup.md](secretary-setup.md#paste-in-message), and the website and `Start.md` publish it (#321). The app-download step joins once Mac distribution exists. The CLI and the message are implemented (#317). (2026-10-09)
- Harnesses: Hermes Agent (Nous Research, MIT, Python) is allowed as an external harness the user installs, like OpenClaw (Node). Each adapter is Swift inside Yorozu: OpenClaw over its Gateway, Hermes over its loopback HTTP API server (`127.0.0.1:8642`, an API key of at least 16 characters, sessions, runs with stop, steer and approval, SSE events and idempotency keys). Runs survive Yorozu restarts and are reconciled. Yorozu never becomes a harness itself: it never runs MCP servers or tool calls. Each harness and each integration declares its own detection. ACP as a generic adapter and remote harnesses are future work (#322). Implemented, compile-checked only ([docs/hermes-integration.md](hermes-integration.md)). (2026-10-09)
- One main harness at a time, `[harness] kind` in `config.toml`, detected and chosen in onboarding (#317) and switchable in Settings, a security-relevant change. Each adapter declares its own read-only detection. A switch keeps Yorozu's data, and topic workers start fresh sessions on the other harness. Several harnesses at once, with threads bound to a harness, is future work (#322). The config key, the switch (applied at the next launch, and held while work is active), detection, the setup step and the Settings row are implemented (#317). (2026-10-09)
- Hermes profiles: Yorozu owns two dedicated profiles and writes only their config: `yorozu-worker` (default tools, Yorozu's MCP servers, a working folder) and `yorozu-roles` (secretary and extraction, no tools). Hermes's own memory, background self-review, skill creation and cron are off in both. The user's own profiles stay untouched; the user installs Hermes and configures providers in it. The profile writer and the setup step that runs it are implemented (#318, #341). (2026-10-09)
- Hermes defaults (accepted): roles run in `yorozu-roles` as fresh one-shot runs, and the 21-message routing replay is redone on Hermes before it can be main; the serving model is checked on every run and a fallback model fails closed. One session per topic (`yorozu-<topic id>`), runs keyed by Yorozu run ids, live progress over SSE and live steering. Workers run at full permission with Hermes's per-step approvals off; the ask-first rules and YOLO stay in Yorozu's prompts. Providers and keys live in Hermes; the API key is generated at setup, written to Yorozu's profiles and kept in the Keychain. Yorozu's MCP servers are written into `yorozu-worker`. Topic compaction maps onto Hermes's own at the same threshold, and the session id stays. OpenClaw and Hermes may both be installed; Yorozu records the Hermes versions it was tested with, warns on others and never updates Hermes. (2026-10-09)
- Hermes providers: Codex or Claude Code, never GitHub Copilot (owner, 2026-10-09). The Codex route: a separate Hermes login (`hermes auth login openai-codex`, not the Codex CLI's tokens), Yorozu's profiles borrow the default profile's grant, and `auth.adopt_external_logins` stays false. Readiness blocks on a Copilot provider and Yorozu never starts a run with one ([docs/hermes-integration.md](hermes-integration.md#providers)).
- Settings live in one file, `config.toml`, in Yorozu's data folder, which keeps them apart from v1 by construction. `PROJECTX_*` environment variables still override them for development. TOML comes from a small SwiftPM dependency. (2026-10-09)
- The native WebSocket Gateway transport is the default, so sub-chat progress is live. The Mac enrolls as a Gateway device once, during onboarding (an app-only setup step, #317) or from Settings. Calls that need OpenClaw's admin scope go through the CLI, so native works as the default. (2026-10-09)
- Model roles get defaults computed from the harness's model metadata, with no hard-coded model ids, and each role can be overridden in Settings › Advanced (pickers filled from the harness's allowed models, with an Automatic entry that names its pick and reason; implemented in phase B of #312) or in `config.toml`: the secretary and extraction take the cheapest allowed model with enough window and output cap; workers take the harness agent's primary model, else the most capable (highest-priced) one; the stronger routing review takes the most expensive allowed model that differs from the secretary's. Defaults are recomputed at launch when there is no explicit choice, the rule inputs are configurable, and explicit choices always win ([setup.md](secretary-setup.md#models)). (2026-10-09)

**Roadmap**

- Order: R1 thinking workspace, then R2 coding workers that develop Yorozu itself, then the iOS client over the relay on internal TestFlight, then R3, cua (https://cua.ai) integration so Yorozu can operate the user's computer. Progress: [docs/status.md](secretary-status.md#roadmap). (2026-10-08)
- Context budgets (issue #310) come before the UI work: batch 1, then batch 2. (2026-10-09)
- Device management belongs to the Settings issue (#312), not #313. The YOLO choice and start at login are onboarding steps in #317. (2026-10-09)

## 2026-10-19 — Chat composer attachments
Source: direct owner message.

- Paste images into the chat input as attachments.
- On iPhone and iPad, the plus menu offers taking a photo in place.
- Reduce space between the plus sign and the text area.

Correction from owner, 2026-10-19 09:15 JST: Keep plus button in place; bring textarea toward it. Paste files as well as images directly into chat input.

Further correction, 2026-10-19 09:31 JST: plus glyph still too far right and now overlaps textarea. Move glyph left, leaving clear visual separation; keep full tap target.

## 2026-10-19 — iOS launch mark correction
Source: direct owner message at 10:27 JST, after internal build 18.

Use the oval mark inside the app icon for the splash, not the full icon; make it respond to light and dark appearance.

## 2026-10-28 — 0.5 migration retired

The owner: migration to 0.9.x is complete; nothing about the 0.5 migration is written any more. Removed from OWNER_DECISIONS.md: the Upgrade from 0.5.0-beta section, the migration clause of "Wire protocol 3", the 0.5 import clause of the list order, and the 0.5 rationale in the Mac bundle id and Sparkle lines. `docs/upgrade-from-0.5.md` deleted.
