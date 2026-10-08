# Architecture

How Yorozu v2 is put together and how a message moves through it. Gateway call details are in [openclaw-integration.md](openclaw-integration.md), the phone wire format in [ios-relay-contract.md](ios-relay-contract.md), and file paths in [setup.md](setup.md#where-data-lives).

```
 Mac composer ──┐                         ┌── OpenClawHarness ── openclaw CLI ── local Gateway (agent projectx)
                ├─> Engine ─> Store       │      secretary + extractor (raw model runs)
 iPhone ─ relay ┘     │      (SQLite)     │      thinking workers (topic sessions)
   (RelayHost +       ├─> MemoryStore ────┤      coding workers (Claude Code / Codex in worktrees)
    EngineBridge)     │   (Markdown+FTS5) │
                      └─> Harness ────────┘   FixtureHarness / OfflineHarness for the other modes
```

## Components

| Component | Code | Job |
|---|---|---|
| App shell and UI | `Sources/ProjectXApp/ProjectX.swift` | `AppModel` opens the store, memory and harness for the run mode, resumes work, starts the relay, and polls a snapshot every 350 ms for the UI and the phones. Views: main chat, sub-chat popover, inspection pane, pair sheet. |
| Engine | `Sources/ProjectXCore/Engine.swift` | Takes messages, routes them one at a time through the secretary, applies the decision, runs workers in lanes, queues memory extraction. An actor. |
| Store | `Sources/ProjectXCore/Store.swift` | GRDB database `operations.sqlite` (tables `topics`, `messages`, `work`, `events`, `amendments`, `receipts`, `memoryJobs`). Holds an exclusive `flock` on `app.lock`, so a second process on the same data directory is refused. Owns every state transition. |
| MemoryStore | `Sources/ProjectXCore/Memory.swift` | User-owned Markdown notes plus a disposable SQLite discovery index. See [Memory](#memory). |
| Harnesses | `Sources/ProjectXCore/Harness.swift` | `OpenClawHarness` (live), `FixtureHarness` (scripted, no model), `OfflineHarness` (no model calls). `GatewayRPC` runs the `openclaw` CLI; `NativeGateway.swift` is the opt-in WebSocket client. |
| Models | `Sources/ProjectXCore/Models.swift` | Records, the routing `Decision`, worker input/output and state names. |
| Relay host | `Sources/ProjectXApp/Relay/` | `RelayHost` (the Mac side of v1's relay protocol), `EngineBridge` (phone events ⇄ Engine), `RelayKeys` (Keychain identity, `relay-devices.json`), `PairPhoneView`. |
| Wire package | `packages/YorozuWire` | v1's relay wire vendored: events, crypto, channel, `RelayClient`. Used by the Mac host and the iOS app. |
| iOS app | `apps/ios/Sources/YorozuIOS` | Pairing flow, then one chat screen over `RelayClient`. See [iOS app](#ios-app). |
| Markdown rendering | `Sources/ProjectXApp/ChatMarkdown.swift` | Shared by Mac and iOS. See [Markdown rendering](#markdown-rendering). |
| MCP server list | `Sources/ProjectXCore/MCPServers.swift` | The MCP servers workers may use, as data. Harness adapters apply it; see [MCP servers and computer use](#mcp-servers-and-computer-use). |

### Run modes

`PROJECTX_MODE` picks the harness ([setup.md](setup.md#environment-variables)).

| Mode | Harness | Behaviour |
|---|---|---|
| `live` (default) | `OpenClawHarness` | Real models through the local Gateway, agent `projectx` only. Starts the relay. |
| `fixture` | `FixtureHarness` | Scripted replies. Orange banner; input stays disabled until "I understand: enable synthetic TEST input" is pressed. Own data root ([setup.md](setup.md#where-data-lives)), no relay. |
| `offline` (also any invalid value) | `OfflineHarness` | Messages are saved; routing posts the failure "Offline mode: message saved; no model was called…". |

The first message sent binds the data directory to its harness mode (receipt id `runtime-binding`); sending from another mode is then refused. Offline mode never binds.

## Flow 1: a Mac message to a result

1. ⌘Return calls `AppModel.send`, then `Engine.send`. The body must be 1–6000 UTF-8 bytes and fewer than 32 items may be outstanding (routing + queued + running). The user `Message` (kind `conversation`) is stored and `send` returns at once; routing runs serially, one message at a time.
2. `Engine.route` builds the `RoutingInput`, a slim view rather than database records (long text is cut by UTF-8 bytes to its head and tail around a `[… cut]` marker):
   - `latestTopic`: the topic of the last user message that has one.
   - `topics`: every topic as `{id, label}`, the latest first, then by last activity (its newest message or work item).
   - `recent`: the last 4 `conversation`/`result` messages across topics plus the last 3 of `latestTopic`, deduplicated and in time order, as `{role, topicID, taskID, kind, body}`. A result loses its `Regarding “…”:` header and is cut to 1500 bytes; other bodies to 1000 bytes. Acknowledgments and failures are left out.
   - `work`: the last 12 work items plus every unsuppressed active or uncertain one, as `{id, topicID, state, executor, instruction, error}` with instruction ≤ 900 bytes and error ≤ 300 bytes.
   - `memory`: hits as `{id, title, excerpt}` (title ≤ 200 bytes, excerpt ≤ 400 bytes), up to 2200 bytes in all.
   - One trim, measured on the final prompt (the longer stronger-review variant, JSON without escaped slashes) against the 20000-byte raw-run cap (`rawPromptCap`): drop memory hits from the lowest-ranked (kept when the message is a forget request), then finished work oldest first, then the least recently active topics down to 10, then the oldest recent messages, then the remaining least active topics, then the oldest active or uncertain work. The latest topic and the topics of kept work and recent messages are never dropped. Dropped topics and blocking work are counted in an `omitted` field ("N older interrupted tasks and M less active topics omitted"). The policy is printed once, above the data.
3. The secretary (a raw model run on the secretary model) returns a `Decision`: `action` (`reply`, `delegate`, `steer`, `clarify`, `correct`, `retry`, `forget`, `stop`) plus `topicID`, `newTopic`, `taskID`, `instruction`, `reply`, `memoryID`, `executor`. The policy tells it the limits: instruction at most 600 characters, reply at most 1,500, and never copying the user's message into the instruction (workers get it verbatim).
4. The Engine validates it: known action, `executor` is `claude`, `codex` or absent, `topicID` and `taskID` known in the full snapshot (not only the trimmed view), `memoryID` among all retrieved hits, `instruction` ≤ 6000 bytes, `reply` ≤ 15000 bytes, `newTopic` ≤ 80 characters, plus the per-action required fields. It is saved as a `routing` receipt. A `clarify` gets one review on the review model (`routing_escalation` receipt); if that review fails, the clarification stands.
5. For `delegate`, the topic is `topicID`; without one, `latestTopic` when there is no `newTopic`. A `newTopic` reuses an existing topic with the same label (case-insensitive) or creates one with session key `agent:projectx:projectx:<topicID>`. `Store.insertWork` allows one active or uncertain work item per (topic, executor); an uncertain one is reconciled first ([Uncertain blockers](#uncertain-blockers)). No acknowledgment is posted.
6. Lanes: at most 2 thinking runs and 1 coding run at a time, across all topics.
7. `execute` moves the work from `queued` to `working` and builds the `WorkerInput`: topic, work, the request message, earlier same-topic `conversation` messages the session has not seen, and memory hits up to 3000 bytes. The harness runs it (see [Workers](#workers) and [Thinking input](#thinking-input)).
8. `Store.finish` either turns open amendments into a follow-up turn of the same task (see [Steer](#steer-stop-retry-correct-forget)) or completes it: the result is posted to the main timeline as kind `result`, with topic and `replyTo` set, as `Regarding “<first 100 characters of the request>”:` followed by the answer. Memory extraction is queued for it.
9. On an error the work becomes `failed` (never dispatched, or a context overflow the Gateway reported) or `uncertain` (it had a run ID), with the error stored up to 1000 bytes, and the timeline gets "That task failed: <error> Say retry to try again." A context overflow (`ProjectError.overflow`) posts its own message instead, with no retry offer ([Context overflow](#context-overflow-and-compaction)).

## Flow 2: a phone message to the same timeline

1. Pairing: opening the Pair iPhone sheet has `RelayHost` ask the relay to mint a code. The Mac makes a one-time secret (held only in memory and in the QR) and shows the pairing link as a QR and a link. The phone stores the pairing in its Keychain and dials the relay.
2. Handshake: `RelayHost` accepts a valid `hello` proof or a known device (at most 16), saves `relay-devices.json`, mints a fresh code if the sheet is still open, and runs the peer-info exchange.
3. Send: `RelayHost` opens the phone's sealed `message` event and `EngineBridge.admit` checks it, then calls `Engine.send(text, id:)`. The phone's id becomes the stored message id, so the message joins the same main timeline as the Mac composer and follows Flow 1.
4. Live updates: each 350 ms snapshot, `EngineBridge.publish` sends new messages and changes of the working flag to every compatible phone. A message over 256,000 UTF-8 bytes reaches the phone as its head plus "…(truncated; full answer on the Mac)", because one relay frame holds at most 1 MiB; chunking comes with #313.

Events, the handshake, admission checks and catch-up are specified in [ios-relay-contract.md](ios-relay-contract.md).

Phones see every main-timeline message, including acknowledgments and failures, and never sub-chat events. The Mac's relay host keeps its own keys ([Keychain items](setup.md#keychain-items)) and room, never v1's: the relay pins a room to the first key that registers. Registration, heartbeat (ping every 30 s, 10 s pong deadline), redial backoff (2 s doubling to 30 s), frame batching and device removal are in `RelayHost.swift`. A relay that cannot start (locked Keychain, unreadable device file) leaves the Mac app running and shows the error in the pair sheet.

## Routing behaviour

The secretary's policy is the `routingPolicy` string in `Engine.swift`. Bullets marked **(code)** are enforced by the Engine; the rest are prompt policy, which the model may not follow. The decision checks in [Flow 1](#flow-1-a-mac-message-to-a-result) step 4 are code too.

- Greetings, thanks and small talk get a reply and no topic. Other replies and clarifications carry a topic; a `newTopic` on a reply opens or reuses one.
- Substantive thinking, analysis, research, tool use and code are delegated without being asked. Questions about PAIOS (the owner's personal knowledge system, outside the repo), files or calendars, and recall of anything not in the supplied messages or memory, go to a worker ([why](openclaw-integration.md#what-the-agent-sees)).
- Coding work, docs in a repo included, is delegated with executor `claude` (Claude Code), or `codex` when the user names Codex. Commit, merge, push, rebuild or restart requests are coding work in the same topic with the executor of the work they continue. Quick shell questions are delegated without an executor (thinking workers have a shell). Coding instructions never ask for tests or CI.
- Operating the Mac or an app on it ("use app X") is delegated without an executor, and the instruction names the apps. New coding work that needs an app or a browser uses `codex` unless the user names Claude Code; continuing work keeps its executor. The user's answer to a question a result asked ("yes, send it") is delegated in that result's topic with the same executor, restating the request as confirmed.
- Topics are broad subjects of one to three words. PROJECTX is this app; the user's own life and preferences go to one separate personal topic.
- **(code)** A message identical to the previous user message, sent while that message's work is still active, is filed under that work's topic with no reply and no action (`Engine.route`).
- **(code)** `steer` or `retry` aimed at a finished task becomes a new `delegate` in the same topic with the same executor. This redo restates the original instruction (≤ 10,000 bytes, head and tail) followed by "The user now says: …" (the message ≤ 1500 bytes) (`Engine.apply`).
- "Stop" or "cancel that" about running work is `stop` with its task ID.

## Workers

| | Thinking worker | Coding worker |
|---|---|---|
| Chosen by | `delegate` without `executor` | `executor` `claude` or `codex` |
| OpenClaw session | Topic session `agent:projectx:projectx:<topicID>` plus a controller session for steering | `<topic session key>-claude` or `-codex`: one session and worktree per topic and executor, reused by later tasks there |
| Runtime and permission | OpenClaw runtime, permission `full`, the agent's default tools | `claude-cli` with `full`, or `codex` with `workspace` (sandboxed to the worktree) |
| Working directory | The agent workspace, the main checkout | An OpenClaw-managed worktree on branch `openclaw/<label slug>-<topicID prefix>-<executor>`, cut from `projectx` when the worktree is first created and reused without a rebase, so later `projectx` commits reach it only through a merge or a new worktree ([openclaw-integration.md](openclaw-integration.md#what-the-agent-sees)) |
| Run shape | Up to 7 steps; each step is one synchronous Gateway run | One async run of up to 2 hours, polled about every 20 s |
| Result | JSON `{text, appliedRevision}`, any length; or `{memoryCall}`, which the app runs and answers in the next step (at most 6 memory operations) | The last assistant text, read whole ([openclaw-integration.md](openclaw-integration.md#reading-final-replies)), plus a diffstat line of the worktree's uncommitted changes |
| Sub-chat progress | The run's public messages and tool names, copied after each step | Assistant text, `$ commands`, tool names with paths, and output or error tails, written while polling |
| Memory tools | `memory.search`, `memory.read`, `memory.write` | None |
| MCP servers | Yorozu's list | Yorozu's list (Codex); globally enabled OpenClaw servers only (Claude Code, an OpenClaw gap) |
| Changes to running work | Tries a live steer, else a follow-up turn after the step | Always a follow-up turn after the run |
| Session compaction | Yorozu compacts the topic session before a task once it reaches half the window | The tool compacts its own session; Yorozu detects it and notes it |

Models per role are in [setup.md](setup.md#models). Thinking and coding work in the same topic can run side by side.

The coding prompt (`contract()` in `Harness.swift`) tells the worker: work in its worktree; check compilation with `swift build`; run no tests or CI; commit, merge, push or restart only when the request asks, committing in the worktree (Conventional Commits, signed), merging into `projectx` with `git -C <main checkout> merge --no-edit <branch>`, never force-pushing, and running `<main checkout>/scripts/build_native.sh --restart` as the last step; leave the owner's uncommitted files alone; treat `OWNER_DECISIONS.md` as read-only. It states that it overrides AGENTS.md and CLAUDE.md: no new worktrees, no fetch or pull, no pull requests unless asked. The prompt also carries the task revision, the run marker `[run projectx-code-<uuid>]`, the instruction, the user's message verbatim under "The user's message, verbatim:", and the earlier topic conversation: newest first, each message ≤ 2000 bytes (head and tail), ≤ 6000 bytes in all, with "[… N earlier message(s) cut]" in place of anything older. The whole message is checked against 32000 bytes before the run handle is stamped; a bigger one fails with an overflow error and no retry offer. Both contracts carry `OpenClawHarness.outputRules`: keep tool output short (files read with an offset and limit, long command output through head, tail or grep, `list_windows` and `get_window_state` on the named app rather than whole-desktop views).

### Thinking input

A thinking session is sent `WorkerInput.wire`, slim views and never database records: `{policy, topic: {id, label}, revision, instruction, current: {id, body}, history: [{role, body}], memory: [{path, title, attribution, epistemicStatus, body}]}`, followed by the contract.

- History: the topic's `conversation` messages after the request of the latest earlier task in the same topic with the same executor that has a result. Earlier ones are already in the session. Failed or uncertain tasks prove nothing about what the session saw, so their messages are sent again. Messages are added newest first while the whole wire stays within 13000 bytes.
- Memory: search hits on the request and the instruction, up to 3000 bytes.
- The whole step message is checked against 32000 bytes before the run ID is stamped, so an oversized one fails the work rather than leaving it uncertain.
- A follow-up turn of the same task sends only the new amendments, under "Follow-up turn of the same task, now revision N. The user changed the request:", and asks for the whole answer again.
- The contract carries `OpenClawHarness.outputRules` (short tool output) and the cua rules.

The coding poll gives up as `uncertain` after about 10 minutes of Gateway failures, 15 unreadable histories in a row, or 3 polls that find no active run.

### Context overflow and compaction

Gateway calls and messages are in [openclaw-integration.md](openclaw-integration.md#compaction).

- Thinking: before each task, the topic session's token count is read; at half of min(its context window, 258,400) tokens the session is compacted as its own call. A compaction posts a sub-chat event of kind `compaction` ("Compacted this topic's session: N → M tokens"). A failed one posts a short `failure` message to the main timeline (a `StreamUpdate.notice`), and the task continues.
- Thinking overflow (`context_overflow` or `compaction_failure` on a step): one forced compaction, then the task fails with `ProjectError.overflow`, saying either that asking again should now work or to start a new topic.
- Coding: a compaction by Claude Code or Codex (new session id, or a lower fresh token count after the run) posts a `compaction` event. An overflow fails the task with "<tool>'s session ran out of context", the worktree changes kept, and says to start a new topic.
- An overflow failure is posted as is, without "Say retry to try again.": a plain retry would hit the same limit.

## MCP servers and computer use

Yorozu declares which MCP servers its workers may use; the harness starts, connects and calls them, and Yorozu never runs a server or a tool call itself. `MCPServers.load` reads `mcp-servers.json` from the data root once per app run, creating it with the cua-driver default ([setup.md](setup.md#mcp-servers)). `OpenClawHarness` mirrors it into OpenClaw as `yorozu-<name>` servers that only Yorozu's sessions switch on ([openclaw-integration.md](openclaw-integration.md#mcp-servers)). A list that cannot be read or mirrored fails each worker run with the reason until the next attempt succeeds.

Computer use goes through the cua-driver server ([cua-integration.md](cua-integration.md)). Its rules are prompt policy: `OpenClawHarness.cuaRules(task)` sits in both the thinking and the coding contract (only the named apps, one window at a time, background delivery, a fresh cua session per run, fresh snapshot then verify, no blind retries, ask before outward-facing steps and the listed risky tools, no secrets). Nothing in code enforces them.

## Steer, stop, retry, correct, forget

Replies in quotes are the exact acknowledgments posted to the timeline.

| Action | What happens |
|---|---|
| `steer` | The work's revision goes up. Queued work that never ran gets the text appended to its instruction (amendment `queued_input`): "Added that to the task before it starts." Otherwise the work becomes `amendment_pending` and a live steer is tried. Admitted: "Sent that change to the running task." Thinking, not admitted: "I'll apply that right after the current step." Coding: "Claude Code can't take changes mid-run, so it gets this after its current run. Say stop to halt it now." (or Codex). |
| Follow-up turn | When a run ends with pending or unconfirmed amendments, `Store.finish` appends them to the instruction, keeps the old answer as a `superseded_result` event and runs the same task again in the same session. A thinking session gets only the new amendments in that turn ("Follow-up turn of the same task, now revision N…"); it already holds the contract and the earlier turn. An answer that does not echo an accepted (live-steered) revision also triggers one follow-up turn, with that answer kept as `superseded_result`. |
| `stop` | Only for active or uncertain work, else "That isn't running." The work is suppressed first (queued and never run becomes `cancelled`; otherwise `cancellation_requested`), then the Gateway is asked to abort the run. "Stopped." or "Stopping it; not confirmed yet." A step still running locally settles the stop when it ends. |
| `retry` | Only for `failed` or `uncertain` work. With no run ID it counts as stopped. Otherwise the run is reconciled first: running or unknown refuses with "Retry has NOT started…"; completed delivers the result (or runs saved amendments: "The earlier run finished before your change, so I'm applying it now."); stopped retires the old work and delegates new work in the same topic and session with the original instruction, the saved amendments not already merged into it (≤ 10,000 bytes together, head and tail) and "User requested retry: …" (the message ≤ 1500 bytes). |
| `correct` | Wrong topic. The mistaken work is stopped or suppressed: "Got it, moving that to the right topic." Then the intended topic's active work of the same executor is steered, an uncertain one gets a saved `pending_reconciliation` amendment, or new work is delegated. History is never moved. |
| New work blocked by uncertain work | See [Uncertain blockers](#uncertain-blockers). |
| `forget` | Needs explicit wording (forget, delete, remove, 忘れ, 削除) and a `memoryID` from the retrieved hits. Queued extraction finishes first, the file is deleted after a SHA-256 check and the index is rebuilt: "Removed that memory from Markdown and refreshed its index. Original chat history is unchanged." |

### Uncertain blockers

Owner decision 7 (`Engine.clearUncertain`). Before a `delegate` inserts new work, each uncertain work item of the same executor in the topic is reconciled. If any blocker is active or suppressed, nothing is reconciled and `Store.insertWork` refuses as before.

- No run ID, or the run is stopped: the old work is retired (suppressed, `failed`) with the acknowledgment "The earlier task here stopped without finishing, so I closed it and started your new request. Its history stays in this topic." The new work starts.
- Completed: the result is delivered and the new work starts. If saved amendments make the old task run again, that runs instead and the new request is refused: "The earlier task here finished before your saved change, so I'm applying that change now. Send this again once it's done, or tell me to add it to that task."
- Running: refused with "An earlier task here is still running, so I haven't started this to avoid running it twice. Say stop to end it, or send this again once it finishes."
- Unknown: refused with "I can't confirm whether an earlier task here is still running, so I haven't started this to avoid running it twice. Say stop to end it, or try again in a few minutes."

Refusals are posted as `failure` messages. A dismiss action for stale uncertain work is not built.

## Restart and resume

On launch, `Store` rewrites unfinished work: rows without a run ID go back to `queued` (or `cancelled` if suppressed); rows with a run ID become `uncertain` with "App restarted while this was running." `Engine.resume` queues the first kind again and watches each uncertain run every 20 s for up to 360 checks (about 2 hours). A run found completed is delivered; one found stopped or still unresolved at the end gets "That task was interrupted by a restart. Say retry to continue."

Reconcile reads the session transcript, not only `agent.wait`: a thinking run is matched by its run ID on the reply, a coding run by its `<run>:user` turn or `[run <id>]` marker, taking the final non-tool assistant turn after it. That is why a coding worker that runs `build_native.sh --restart`, which kills the app mid-run, still has its result delivered by the relaunched app.

## Memory

Notes live under the memory root (`~/Yorozu/memory` in live mode) as `<UUID>.md`; automatic extraction writes `knowledge/<UUID>.md`.

- Format: line 1 is JSON metadata (`id`, `title`, `topicID`, `sources`, `evidence`, `knowledgeType`, `attribution`, `epistemicStatus`, `created`, `updated`, `lineage`), then a blank line, then the body. The file name must equal `id` + `.md`.
- `knowledgeType` is one of `user_fact`, `user_preference`, `user_decision`, `user_belief`, `source_claim`, `generated_analysis`, `topic_synthesis`, `tentative_hypothesis`; `attribution` is `user`, `assistant` or `quoted_source`; `epistemicStatus` is `user_stated`, `unverified` or `tentative`. A `user_*` note needs attribution `user`, status `user_stated` and an `evidence` quote found verbatim in a non-quoted user message among its `sources`. Generated analysis stays `assistant`; source claims stay `quoted_source`; hypotheses stay `tentative`.
- Limits: title ≤ 120 characters, body ≤ 8000 bytes, file ≤ 12000 bytes with lineage, ≤ 16 sources that must be existing message IDs, paths of at most 5 components of `[A-Za-z0-9_.-]`, no secret-shaped text.
- Writes: compare-and-swap on the file's SHA-256 (`null` means create only), an advisory `.writer.lock`, a temp file `.projectx-<uuid>.tmp` with fsync, then `renameat`. An overwrite keeps the note's identity, attribution and type and appends the previous body to `lineage`. A write that lands but fails to re-index returns `indexed: false` and must not be replayed.
- History (owner decision 6): when lineage would push a note past 12000 bytes, its oldest versions move to `<memory root>/history/<id>.md`, an append-only Markdown file with one `## Replaced <ISO 8601 time>` section per version (attribution, epistemic status, sources, then the old body). The history file is written atomically before the note is replaced, so a failure in between leaves a duplicate entry, never a lost version. Writes to paths under `history/` are refused (any letter case), and a forget deletes the note's history file too. Builds from before this change read every `.md` file and fail to launch once a history file exists.
- Index: `memory-index.sqlite` with a `discovery` table (id, title, summary = first 200 characters of the body, path) and an FTS5 `search_trigram` table (trigram tokenizer; the older `search` table is left for builds from before batch 2 that share the cache). It is rebuilt from the Markdown at every launch, before and after every write, and after every forget.
- Search terms (`MemoryStore.terms`): a query splits into runs of letters and digits, kana/kanji runs apart from the rest. Other runs of 3 or more characters are lowercased substring terms; shorter ones are ignored. A kana/kanji run of 3 or more characters becomes overlapping 3-character windows, dropping all-hiragana windows unless the whole run is hiragana (mostly grammar). Kana/kanji runs of 1–2 characters (not a lone hiragana) and 2-character stretches between hiragana in longer runs (東京 in 東京で) are short terms.
- Search: up to 64 terms ORed in a trigram `MATCH`, ranked by bm25. Trigrams cannot match 1–2 characters, so when there are fewer than 8 hits up to 16 short terms are matched with `LIKE` over the title and summary, ranked by how many match. A query with no terms gets no hits. At most 8 notes and 10 KB are returned, read back from the Markdown; a note larger than what is left of the 10 KB is passed over and smaller later ones still fit, and an unreadable or unparseable note is skipped and added to `MemoryStore.skipped`. Matching is lexical over the title and summary only, so it misses paraphrases.
- Strictness: the rebuild reads every `.md` file under the root except `history/`. An oversized, unparseable or misnamed file (a `README.md`, malformed metadata, a name that is not `<id>.md`) is skipped and listed in `MemoryStore.skipped`; at launch the app posts one `failure` message naming up to 10 of them. A symlink or a duplicate `id` still makes the rebuild throw: at launch that leaves the app open but not ready (the error shows in the window subtitle and sending is disabled); later it makes every memory write fail. Keep the memory directory to notes only.
- Extraction: runs serially on `conversation` and `result` messages (never acknowledgments, failures or secret-shaped text) as a raw run on the secretary model. The final prompt stays within `rawPromptCap` (20000 bytes): existing relevant memory goes as `{id, title, excerpt}` items (excerpt ≤ 600 bytes) up to 4500 bytes, and the source body is cut by UTF-8 bytes to its head and tail to fit what is left; a prompt that still does not fit fails the job. At most 4 proposals, each with a quote found verbatim in the source. Replacing an existing note needs correction wording (actually, correction, instead, changed, 訂正, 変更) and a currently retrieved note. A `memoryJobs` row per message (`saved`, `no_knowledge`, `error_no_replay`, `forget_request_not_extracted`) prevents re-extraction; an `error_no_replay` job keeps its failure reason in `memoryJobReasons` (≤ 500 characters; none when it looks like a secret), a separate table so older builds keep writing `memoryJobs`.
- Worker access: only thinking workers, only through `memoryCall`. Thinking workers also have a shell, so these rules hold for them by prompt, not by sandbox.

## State names

| Kind | Values |
|---|---|
| Work state | `queued`, `working`, `amendment_pending`, `cancellation_requested` (these four are active), `uncertain`, `failed`, `done`, `cancelled`, `superseded` |
| Amendment state | `queued_input`, `pending`, `accepted`, `applied`, `pending_reconciliation` |
| Message kind | `conversation`, `result`, `failure`, `acknowledgment`, `memory_receipt`; `amendment_unconfirmed_<revision>` is defined in `Store.complete` but not produced in practice, because `Store.finish` turns unconfirmed amendments into a follow-up turn first |
| Receipt kind | `runtime` (the single row with id `runtime-binding`), `routing`, `routing_escalation`, `gateway-request` (correlation only, see [openclaw-integration.md](openclaw-integration.md#request-receipts)) |
| Worker event kind | `lifecycle`, `tool`, `message`, `command`, `output`, `error`, `diff`, `superseded_result`, `compaction`, `fixture_progress` |

## Mac UI

- The window is the main chat: every message of every kind in one list. Each card shows "You" or "Yorozu" and a Copy button that copies the raw body. The composer sends on ⌘Return; Return adds a newline. The window subtitle shows the status notice.
- Toolbar: Sub-chats (a 480×620 popover listing topics with status symbols; each row pushes an inspect-only pane), Pair iPhone (live mode only), a small spinner "Working on it" while any work is active, and Connect native device (native transport only).
- Topic status symbols: `circle.dotted` working, queued or amendment pending; `checkmark.circle` done; `exclamationmark.circle` failed, uncertain, cancellation requested, or amendment pending with a result; `circle` otherwise.
- The inspection pane shows "Inspect only · <state>", the topic's conversation messages, then each work item: instruction, executor and state, amendments, events (monospaced for commands, output, errors and diffs), error, and the retained result as Markdown.

## iOS app

`RootView` shows the pairing flow until a host is linked, then the chat. Pairing takes a scanned or pasted link (or a `yorozu://pair` link) and has the user confirm the relay host and the Mac key fingerprint before saving. Going to the background closes the socket; coming back redials at once. The composer is v1's without attach, stash, model or Stop controls; it caps messages at 6000 bytes and its border turns vermilion while the Mac is working. A status dot always comes with a text label. Settings shows status, the Mac's name, Repair connection, Remove host and the version. The phone keeps its pairing in its own Keychain item and never reads v1's.

## Markdown rendering

`AttributedString(chatMarkdown:)` parses with `AttributedString(markdown:)` (returning partial parses, falling back to plain text) and flattens blocks itself, because SwiftUI `Text` ignores `presentationIntent`. Blocks are separated by newlines (a blank line between top-level blocks); headings render as bold title2, title3 or headline; code blocks are monospaced on a faint background; block quotes are secondary colour; table header rows are bold and cells in a row are tab-separated; list items get `• ` or `n. ` with four spaces per nesting level. Assistant text renders this way in one selectable `Text`, so a drag selects the whole message; user text stays verbatim.
