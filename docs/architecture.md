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
2. `Engine.route` builds the `RoutingInput`:
   - `latestTopic`: the topic of the last user message that has one.
   - Up to 12 topics, the latest first, then by label-word overlap with the message.
   - The last 6 `conversation`/`result` messages, each cut to 350 characters. Acknowledgments and failures are left out.
   - The last 12 work items plus every active or uncertain one, instructions cut to 300 characters, results removed.
   - Memory hits up to 2200 bytes.
   - The routing policy plus this context data stay at or under 15000 bytes: finished work is dropped first, then other work, the oldest recent messages and the lowest-ranked memory hits. The policy is printed once, above the data, so the whole prompt stays well under the 20000-byte cap on raw runs.
3. The secretary (a raw model run on the secretary model) returns a `Decision`: `action` (`reply`, `delegate`, `steer`, `clarify`, `correct`, `retry`, `forget`, `stop`) plus `topicID`, `newTopic`, `taskID`, `instruction`, `reply`, `memoryID`, `executor`.
4. The Engine validates it: known action, `executor` is `claude`, `codex` or absent, IDs only from the input, `instruction` ≤ 2000 bytes, `reply` ≤ 5000 bytes, `newTopic` ≤ 80 characters, plus the per-action required fields. It is saved as a `routing` receipt. A `clarify` gets one review on the worker model (`routing_escalation` receipt); if that review fails, the clarification stands.
5. For `delegate`, the topic is `topicID`; without one, `latestTopic` when there is no `newTopic`. A `newTopic` reuses an existing topic with the same label (case-insensitive) or creates one with session key `agent:projectx:projectx:<topicID>`. `Store.insertWork` allows one active or uncertain work item per (topic, executor). No acknowledgment is posted.
6. Lanes: at most 2 thinking runs and 1 coding run at a time, across all topics.
7. `execute` moves the work from `queued` to `working` and builds the `WorkerInput`: topic, work, the request message, earlier same-topic `conversation` messages up to 13000 bytes of input, memory up to 3000 bytes. The harness runs it (see [Workers](#workers)).
8. `Store.finish` either turns open amendments into a follow-up turn of the same task (see [Steer](#steer-stop-retry-correct-forget)) or completes it: the result is posted to the main timeline as kind `result`, with topic and `replyTo` set, as `Regarding “<first 100 characters of the request>”:` followed by the answer. Memory extraction is queued for it.
9. On an error the work becomes `failed` (never dispatched) or `uncertain` (it had a run ID), and the timeline gets "That task failed: <error> Say retry to try again."

## Flow 2: a phone message to the same timeline

1. Pairing: opening the Pair iPhone sheet has `RelayHost` ask the relay to mint a code. The Mac makes a one-time secret (held only in memory and in the QR) and shows the pairing link as a QR and a link. The phone stores the pairing in its Keychain and dials the relay.
2. Handshake: `RelayHost` accepts a valid `hello` proof or a known device (at most 16), saves `relay-devices.json`, mints a fresh code if the sheet is still open, and runs the peer-info exchange.
3. Send: `RelayHost` opens the phone's sealed `message` event and `EngineBridge.admit` checks it, then calls `Engine.send(text, id:)`. The phone's id becomes the stored message id, so the message joins the same main timeline as the Mac composer and follows Flow 1.
4. Live updates: each 350 ms snapshot, `EngineBridge.publish` sends new messages and changes of the working flag to every compatible phone.

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
- **(code)** `steer` or `retry` aimed at a finished task becomes a new `delegate` in the same topic with the same executor. A retry restates the original instruction followed by "The user now says: …" (`Engine.apply`).
- "Stop" or "cancel that" about running work is `stop` with its task ID.

## Workers

| | Thinking worker | Coding worker |
|---|---|---|
| Chosen by | `delegate` without `executor` | `executor` `claude` or `codex` |
| OpenClaw session | Topic session `agent:projectx:projectx:<topicID>` plus a controller session for steering | `<topic session key>-claude` or `-codex`: one session and worktree per topic and executor, reused by later tasks there |
| Runtime and permission | OpenClaw runtime, permission `full`, the agent's default tools | `claude-cli` with `full`, or `codex` with `workspace` (sandboxed to the worktree) |
| Working directory | The agent workspace, the main checkout | An OpenClaw-managed worktree on branch `openclaw/<label slug>-<topicID prefix>-<executor>`, cut from `projectx` when the worktree is first created and reused without a rebase, so later `projectx` commits reach it only through a merge or a new worktree ([openclaw-integration.md](openclaw-integration.md#what-the-agent-sees)) |
| Run shape | Up to 7 steps; each step is one synchronous Gateway run | One async run of up to 2 hours, polled about every 20 s |
| Result | JSON `{text, appliedRevision}`; or `{memoryCall}`, which the app runs and answers in the next step (at most 6 memory operations) | The last assistant text (≤ 60000 characters) plus a diffstat line of the worktree's uncommitted changes |
| Sub-chat progress | The run's public messages and tool names, copied after each step | Assistant text, `$ commands`, tool names with paths, and output or error tails, written while polling |
| Memory tools | `memory.search`, `memory.read`, `memory.write` | None |
| MCP servers | Yorozu's list | Yorozu's list (Codex); globally enabled OpenClaw servers only (Claude Code, an OpenClaw gap) |
| Changes to running work | Tries a live steer, else a follow-up turn after the step | Always a follow-up turn after the run |

Models per role are in [setup.md](setup.md#models). Thinking and coding work in the same topic can run side by side.

The coding prompt (`contract()` in `Harness.swift`) tells the worker: work in its worktree; check compilation with `swift build`; run no tests or CI; commit, merge, push or restart only when the request asks, committing in the worktree (Conventional Commits, signed), merging into `projectx` with `git -C <main checkout> merge --no-edit <branch>`, never force-pushing, and running `<main checkout>/scripts/build_native.sh --restart` as the last step; leave the owner's uncommitted files alone; treat `OWNER_DECISIONS.md` as read-only. It states that it overrides AGENTS.md and CLAUDE.md: no new worktrees, no fetch or pull, no pull requests unless asked. The prompt also carries the task revision, the run marker `[run projectx-code-<uuid>]` and the last 6 topic messages.

The coding poll gives up as `uncertain` after about 10 minutes of Gateway failures, 15 unreadable histories in a row, or 3 polls that find no active run.

## MCP servers and computer use

Yorozu declares which MCP servers its workers may use; the harness starts, connects and calls them, and Yorozu never runs a server or a tool call itself. `MCPServers.load` reads `mcp-servers.json` from the data root once per app run, creating it with the cua-driver default ([setup.md](setup.md#mcp-servers)). `OpenClawHarness` mirrors it into OpenClaw as `yorozu-<name>` servers that only Yorozu's sessions switch on ([openclaw-integration.md](openclaw-integration.md#mcp-servers)). A list that cannot be read or mirrored fails each worker run with the reason until the next attempt succeeds.

Computer use goes through the cua-driver server ([cua-integration.md](cua-integration.md)). Its rules are prompt policy: `OpenClawHarness.cuaRules(task)` sits in both the thinking and the coding contract (only the named apps, one window at a time, background delivery, a fresh cua session per run, fresh snapshot then verify, no blind retries, ask before outward-facing steps and the listed risky tools, no secrets). Nothing in code enforces them.

## Steer, stop, retry, correct, forget

Replies in quotes are the exact acknowledgments posted to the timeline.

| Action | What happens |
|---|---|
| `steer` | The work's revision goes up. Queued work that never ran gets the text appended to its instruction (amendment `queued_input`): "Added that to the task before it starts." Otherwise the work becomes `amendment_pending` and a live steer is tried. Admitted: "Sent that change to the running task." Thinking, not admitted: "I'll apply that right after the current step." Coding: "Claude Code can't take changes mid-run, so it gets this after its current run. Say stop to halt it now." (or Codex). |
| Follow-up turn | When a run ends with pending or unconfirmed amendments, `Store.finish` appends them to the instruction, keeps the old answer as a `superseded_result` event and runs the same task again in the same session. An answer that does not echo an accepted (live-steered) revision also triggers one follow-up turn, with that answer kept as `superseded_result`. |
| `stop` | Only for active or uncertain work, else "That isn't running." The work is suppressed first (queued and never run becomes `cancelled`; otherwise `cancellation_requested`), then the Gateway is asked to abort the run. "Stopped." or "Stopping it; not confirmed yet." A step still running locally settles the stop when it ends. |
| `retry` | Only for `failed` or `uncertain` work. With no run ID it counts as stopped. Otherwise the run is reconciled first: running or unknown refuses with "Retry has NOT started…"; completed delivers the result (or runs saved amendments: "The earlier run finished before your change, so I'm applying it now."); stopped retires the old work and delegates new work in the same topic and session with the original instruction, the saved amendments and "User requested retry: …". |
| `correct` | Wrong topic. The mistaken work is stopped or suppressed: "Got it, moving that to the right topic." Then the intended topic's active work of the same executor is steered, an uncertain one gets a saved `pending_reconciliation` amendment, or new work is delegated. History is never moved. |
| `forget` | Needs explicit wording (forget, delete, remove, 忘れ, 削除) and a `memoryID` from the retrieved hits. Queued extraction finishes first, the file is deleted after a SHA-256 check and the index is rebuilt: "Removed that memory from Markdown and refreshed its index. Original chat history is unchanged." |

## Restart and resume

On launch, `Store` rewrites unfinished work: rows without a run ID go back to `queued` (or `cancelled` if suppressed); rows with a run ID become `uncertain` with "App restarted while this was running." `Engine.resume` queues the first kind again and watches each uncertain run every 20 s for up to 360 checks (about 2 hours). A run found completed is delivered; one found stopped or still unresolved at the end gets "That task was interrupted by a restart. Say retry to continue."

Reconcile reads the session transcript, not only `agent.wait`: a thinking run is matched by its run ID on the reply, a coding run by its `<run>:user` turn or `[run <id>]` marker, taking the final non-tool assistant turn after it. That is why a coding worker that runs `build_native.sh --restart`, which kills the app mid-run, still has its result delivered by the relaunched app.

## Memory

Notes live under the memory root (`~/Yorozu/memory` in live mode) as `<UUID>.md`; automatic extraction writes `knowledge/<UUID>.md`.

- Format: line 1 is JSON metadata (`id`, `title`, `topicID`, `sources`, `evidence`, `knowledgeType`, `attribution`, `epistemicStatus`, `created`, `updated`, `lineage`), then a blank line, then the body. The file name must equal `id` + `.md`.
- `knowledgeType` is one of `user_fact`, `user_preference`, `user_decision`, `user_belief`, `source_claim`, `generated_analysis`, `topic_synthesis`, `tentative_hypothesis`; `attribution` is `user`, `assistant` or `quoted_source`; `epistemicStatus` is `user_stated`, `unverified` or `tentative`. A `user_*` note needs attribution `user`, status `user_stated` and an `evidence` quote found verbatim in a non-quoted user message among its `sources`. Generated analysis stays `assistant`; source claims stay `quoted_source`; hypotheses stay `tentative`.
- Limits: title ≤ 120 characters, body ≤ 8000 bytes, file ≤ 12000 bytes with lineage, ≤ 16 sources that must be existing message IDs, paths of at most 5 components of `[A-Za-z0-9_.-]`, no secret-shaped text.
- Writes: compare-and-swap on the file's SHA-256 (`null` means create only), an advisory `.writer.lock`, a temp file `.projectx-<uuid>.tmp` with fsync, then `renameat`. An overwrite keeps the note's identity, attribution and type and appends the previous body to `lineage`. A write that lands but fails to re-index returns `indexed: false` and must not be replayed.
- Index: `memory-index.sqlite` with a `discovery` table (id, title, summary = first 200 characters of the body, path) and an FTS5 `search` table. It is rebuilt from the Markdown at every launch, before and after every write, and after every forget. Search takes up to 24 terms of three or more letters or digits, ORs them, ranks by bm25 and returns at most 8 notes and 10 KB, read back from the Markdown. Matching is lexical over the title and summary only: it misses paraphrases, and Japanese or other unspaced text matches only as whole runs.
- Strictness: the rebuild reads every `.md` file under the root, and any file that breaks the rules above (a `README.md`, a symlink, malformed metadata) makes it throw. At launch that leaves the app open but not ready (the error shows in the window subtitle and sending is disabled); later it makes every memory write fail. Keep the memory directory to notes only.
- Extraction: runs serially on `conversation` and `result` messages (never acknowledgments, failures or secret-shaped text) as a raw run on the secretary model. A body over 5000 characters is sent as its first and last 2500. At most 4 proposals, each with a quote found verbatim in the source. Replacing an existing note needs correction wording (actually, correction, instead, changed, 訂正, 変更) and a currently retrieved note. A `memoryJobs` row per message (`saved`, `no_knowledge`, `error_no_replay`, `forget_request_not_extracted`) prevents re-extraction.
- Worker access: only thinking workers, only through `memoryCall`. Thinking workers also have a shell, so these rules hold for them by prompt, not by sandbox.

## State names

| Kind | Values |
|---|---|
| Work state | `queued`, `working`, `amendment_pending`, `cancellation_requested` (these four are active), `uncertain`, `failed`, `done`, `cancelled`, `superseded` |
| Amendment state | `queued_input`, `pending`, `accepted`, `applied`, `pending_reconciliation` |
| Message kind | `conversation`, `result`, `failure`, `acknowledgment`, `memory_receipt`; `amendment_unconfirmed_<revision>` is defined in `Store.complete` but not produced in practice, because `Store.finish` turns unconfirmed amendments into a follow-up turn first |
| Receipt kind | `runtime` (the single row with id `runtime-binding`), `routing`, `routing_escalation`, `gateway-request` (correlation only, see [openclaw-integration.md](openclaw-integration.md#request-receipts)) |
| Worker event kind | `lifecycle`, `tool`, `message`, `command`, `output`, `error`, `diff`, `superseded_result`, `fixture_progress` |

## Mac UI

- The window is the main chat: every message of every kind in one list. Each card shows "You" or "Yorozu" and a Copy button that copies the raw body. The composer sends on ⌘Return; Return adds a newline. The window subtitle shows the status notice.
- Toolbar: Sub-chats (a 480×620 popover listing topics with status symbols; each row pushes an inspect-only pane), Pair iPhone (live mode only), a small spinner "Working on it" while any work is active, and Connect native device (native transport only).
- Topic status symbols: `circle.dotted` working, queued or amendment pending; `checkmark.circle` done; `exclamationmark.circle` failed, uncertain, cancellation requested, or amendment pending with a result; `circle` otherwise.
- The inspection pane shows "Inspect only · <state>", the topic's conversation messages, then each work item: instruction, executor and state, amendments, events (monospaced for commands, output, errors and diffs), error, and the retained result as Markdown.

## iOS app

`RootView` shows the pairing flow until a host is linked, then the chat. Pairing takes a scanned or pasted link (or a `yorozu://pair` link) and has the user confirm the relay host and the Mac key fingerprint before saving. Going to the background closes the socket; coming back redials at once. The composer is v1's without attach, stash, model or Stop controls; it caps messages at 6000 bytes and its border turns vermilion while the Mac is working. A status dot always comes with a text label. Settings shows status, the Mac's name, Repair connection, Remove host and the version. The phone keeps its pairing in its own Keychain item and never reads v1's.

## Markdown rendering

`AttributedString(chatMarkdown:)` parses with `AttributedString(markdown:)` (returning partial parses, falling back to plain text) and flattens blocks itself, because SwiftUI `Text` ignores `presentationIntent`. Blocks are separated by newlines (a blank line between top-level blocks); headings render as bold title2, title3 or headline; code blocks are monospaced on a faint background; block quotes are secondary colour; table header rows are bold and cells in a row are tab-separated; list items get `• ` or `n. ` with four spaces per nesting level. Assistant text renders this way in one selectable `Text`, so a drag selects the whole message; user text stays verbatim.
