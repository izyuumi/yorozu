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

## 2026-10-09 — Context budgets batch 2: implementer readings (not owner decisions)
Source: the batch 2 plan comment on issue #310, taking the three open questions of the 2026-10-09 owner update at their proposed defaults. The owner has not answered them; [status.md](../status.md#open-items) keeps them as open items, marked as defaults taken.

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
Source: the plan comment on issue #311, taking three of its open questions at their proposed defaults. The owner has not answered them; [status.md](../status.md#open-items) keeps them as open items, marked as defaults taken.

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
Source: the plan comment on issue #312, which splits it into phase A (`config.toml`, core, harness, app wiring, signing and the devices backend) and phase B (the Settings tabs, the iPhone Settings › Connection section and Copy diagnostics, after the owner approves the Claude Design mockups), and takes the issue's open questions 1–13 at their proposed defaults. The owner has not answered them; [status.md](../status.md#open-items) keeps the ones that matter as open items, marked as defaults taken.

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
Source: the plan comment on issue #313, which splits it by whether a change touches the wire, because a 0.7 Mac stops the owner's 0.6.1 phone: PR A (reliability and core, still on the 0.6 wire, branch `sync-reliability`), PR B (contract 0.7 and iOS, left open until the owner chooses when the Mac moves to 0.7) and PR C (the visual parts, after the owner approves the #311 mockups). It takes the issue's open questions 1–7 at their proposed defaults. The owner has not answered them; [status.md](../status.md#open-items) keeps them as open items, marked as defaults taken where PR A uses them.

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
Source: the plan comment on issue #318, which builds the harness seam, the Hermes adapter and the profile writer on branch `hermes-adapter`, against Hermes's documented API at v0.21.6, verified by compiling only because Hermes is not installed on the host. It takes the issue's open questions 1–9 at their proposed defaults. The owner has not answered them; [status.md](../status.md#open-items) keeps them as open items, marked as defaults taken.

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
Source: the plan comment on issue #319, which builds phase A (core, scheduler and app wiring) on branch `jobs` now, because it does not need contract 0.7: the job wire events (`job_list`, `job_control`, a message to a job) follow #329, and the Jobs list and job screens on the Mac and the phone follow the #311 design approval. It takes the issue's open questions 1–16 at their proposed defaults. The owner has not answered them; [status.md](../status.md#open-items) keeps them as open items, marked as defaults taken.

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
Source: the phase B plan comment on issue #311. The remaining open questions were taken at their proposed defaults; [status.md](../status.md#open-items) keeps them as open items.

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
