# Status

As of 2026-10-09, `projectx` at 31c8367 (batches 1 and 2 of issue #310, context budgets, merged in #324 and #325), with phase A of issue #311 (UI) on branch `menu-bar-host`. Update this file when a part changes state; keep only the current picture. Past decisions are in [history/decisions-log.md](history/decisions-log.md).

## Parts

| Part | State | Evidence |
|---|---|---|
| Mac app (`build/Yorozu.app`) | Done; menu-bar host in code on `menu-bar-host` | Tuist/Xcode build with the toolbar sub-chat popover, Copy button and native Markdown (2dbab14, acbd66e, eeb9c7c); hosts the iOS relay and the Pair iPhone sheet (488a478, 9533000). On `menu-bar-host` it becomes a menu-bar popover with a Settings window and no sub-chat UI ([architecture.md](architecture.md#mac-ui)). Current dev build: 0.6.1 (1). |
| UI (issue #311) | Phase A done in code, not yet merged or checked live; phase B waits for the owner's approval of the Claude Design mockups | Phase A on `menu-bar-host` (f1c2cf5, 3c5e8c0, 5f1be80, 2e554ca, cc542e4): menu-bar host and popover, Settings shell with Pair iPhone and native enrollment, status line, sub-chats and toolbar removed, snapshot published only on change, Markdown parsed once per message; native transport by default with a CLI fallback per launch and background redial ([openclaw-integration.md](openclaw-integration.md#native-transport)); tool rows that name the tool and app ([openclaw-integration.md](openclaw-integration.md#tool-rows)); notice codes and kind `question` ([architecture.md](architecture.md#state-names)); the chat search index and `Engine.search` ([architecture.md](architecture.md#chat-search)). Phase B: message rows and reply headers (with the `Regarding` prefix dropped at the same time; it is still stored), day separators, stay-put scrolling and the pill, the ⌘F search UI, the shared block renderer, smart Enter, the attention dot and notifications, the global shortcut, localization, the iOS system look, `EngineBridge` changes for 0.6 phones, and the remaining docs. |
| Secretary routing | Done | Verified live 2026-10-08. Routing was tuned and replayed against 21 real messages twice: topic choice about 50% → 100%, action choice about 75–80% → 95% (c070aa2, 56df548). PAIOS, file and calendar questions go to a worker (865922d). |
| Thinking workers | Done | Verified live 2026-10-08: delegation, same-topic follow-up in the same session, and a change sent to a running task, applied as a follow-up turn with the first answer kept as `superseded_result`. |
| Markdown memory | Done; quality unmeasured | Automatic extraction writes `~/Yorozu/memory/knowledge/*.md`; index in Caches (12e0c4f). Extraction quality has not been evaluated. |
| Coding workers (R2) | Done | Verified live 2026-10-08 from the chat: Claude Code rewrote the README (d7e0b1d) and Codex added a note (bfb15d7); each committed, merged into `projectx`, ran `build_native.sh --restart`, and the relaunched app delivered the result. |
| iOS client and relay (0.6.x) | Shipped to internal TestFlight; device check pending | Latest upload 0.6.1 (5) after the icon commit; 0.6.1 (4) came before it, and 0.6.0 (10127) is expired. Live 2026-10-08: the Mac registered on the default relay ([setup.md](setup.md#environment-variables)), and a headless phone built on the app's `RelayClient` paired, passed the `yorozu-v2` check, received history, sent a message and got the receipt and the reply. On 2026-10-08 App Store Connect showed 0.6.1 (5) in beta testing for the Internal group. Nobody has tapped through the iOS UI on a device yet. |
| Context budgets (issue #310) | Done (batches 1 and 2), checked live | Thinking topic sessions are compacted at half the window and overflow fails with a specific message ([openclaw-integration.md](openclaw-integration.md#compaction)); coding workers get the user's message verbatim and byte-cut history; the routing view is slim and trimmed on the final prompt, with IDs checked against the full snapshot; uncertain blockers are reconciled (decision 7); extraction stays within the raw-prompt cap and records failure reasons; bad memory files are skipped and reported; old note versions move to `history/`; the stronger review has its own model setting ([architecture.md](architecture.md)). `contextWindow: 272000` is set for the two pool models in the host's OpenClaw config. Batch 1 checked live on 903a15b: the app launched ready, and a delegated question went through the slim routing view to a thinking worker and back; no compaction or overflow has been seen live yet. Batch 2: the thinking session gets only what it has not seen, as slim views, and a follow-up turn only its new amendments ([architecture.md](architecture.md#thinking-input)); both worker contracts carry tool-output rules; the secretary sees all topics and a topic-aware recent window; retry and redo instructions are bounded; memory search handles Japanese ([architecture.md](architecture.md#memory)); worker answers have no Yorozu cap and final replies are read whole ([openclaw-integration.md](openclaw-integration.md#reading-final-replies)); the coding poll reads smaller previews and the coding message is checked before dispatch. Batch 2 checked live on 31c8367: a Japanese follow-up was resolved from the topic-aware context, the topic session grew about 2.5k tokens for the task (11–39k before), and the memory index rebuilt into `search_trigram`. |
| R3 computer use via cua | Done for thinking workers; Claude Code left without Yorozu's MCP servers (owner decision) | 7f2e2f0, 67f6cce: Yorozu owns the MCP server list (`mcp-servers.json`, default cua-driver) and mirrors it into OpenClaw per session; "operate my Mac / use app X" is delegated; both worker contracts carry the cua rules. Verified live 2026-10-08: the TextEdit smoke test passed from the chat with TextEdit kept in the background, and an owner request drove Safari in the background ([cua-integration.md](cua-integration.md#smoke-test)). After 67f6cce a second smoke run passed with a per-run cua session label. Codex coding workers get the tools but were not exercised; Claude Code coding workers do not get them ([known limits](#known-limits)). |

## Roadmap

1. R1, native thinking workspace: done.
2. R2, coding workers that develop Yorozu itself: done.
3. iOS client 0.6.x over the relay on internal TestFlight: shipped; the owner's on-device check is pending.
4. R3, cua integration so Yorozu operates the user's computer: first step done (thinking workers, verified from the chat). Next: Claude Code coding workers once OpenClaw passes session tool settings to them; a dedicated computer executor only if collisions or timeouts show up.
5. Context budgets (issue #310), before the UI issue: done: batches 1 and 2 merged and checked live.
6. UI (issue #311): phase A done in code on `menu-bar-host`; phase B after the owner approves the Claude Design mockups. Then the Settings issue (#312).
7. Later, unscheduled: iOS push notifications, Stop, attachments and sub-chats (iOS 0.6.x has one thread and none of these); Mac distribution (notarization, an update feed); document import; vector retrieval; automatic topic merge and split; a dismiss action for stale uncertain tasks.

## Open items

Each item has a default that holds until the owner answers.

| Item | Default |
|---|---|
| Install 0.6.1 (5) from TestFlight, pair it from the Mac's Pair iPhone sheet and send one message. | 0.6.x counts as shipped; a device bug becomes a 0.6.x fix. |
| When the iOS features in roadmap item 7 arrive. | After R3. |
| The owner's own OpenClaw MCP entries (`cua-driver`, the broken `cua`, `computer-use`) stay global for other agents; Yorozu sessions switch them off. | Leave them; the owner fixes or removes `cua`. |
| An OpenClaw workspace plugin of the owner's gates cua-driver browser and input calls on browser pids for every agent, and its `/Arc/` pattern also matches non-browser apps such as Archive Utility. | Leave the plugin as is. |
| Batch 2 splits the "Worker contract" item: the tool-output rules stay and the answer-length rule goes. This reading of the 2026-10-09 decision is not owner-confirmed. | Default taken in batch 2: both contracts keep the tool-output rules; they limit session growth, not answer size. |
| The secretary model's 8,192-token output cap can cut extraction JSON (issue #310, finding 13); computed model defaults come with the Settings issue. | Default taken in batch 2: today's model ids stay until then, no interim assignment. |
| `chat.history` `maxChars` tops out at 500,000 UTF-16 units in the Gateway, which then appends its own truncation marker. | Default taken in batch 2, adapted: final replies are read whole through `chat.message.get` (up to 1,000,000 characters per text field) rather than at 500,000, because `chat.history` drops a message over 128 KiB at any `maxChars`; past the Gateway's limits its marker shows as is ([openclaw-integration.md](openclaw-integration.md#reading-final-replies)). |
| #311 question 1: removing the Mac sub-chats leaves no UI that shows a topic until phone sub-chats arrive with #313. | Default taken in phase A: removed as decided; the data stays in the store. |
| #311 question 2: the native transport is not enrolled or not reachable. | Default taken in phase A: that launch uses the CLI, with a one-line notice and "Connect…"; the composer is never blocked ([openclaw-integration.md](openclaw-integration.md#native-transport)). |
| #311 question 5: what counts as a question. | Default taken in phase A: routing questions are kind `question` with a question code, and `clarify` replies carry code `question`; no failure styling ([architecture.md](architecture.md#routing-behaviour)). |
| #311 question 3: the text of Mac notifications. | No message content: "Yorozu replied", "A task failed", "Yorozu has a question" (phase B). |
| #311 question 4: notification permission and noise. | Ask the first time a notification would be posted; post nothing while the popover is open and scrolled to the bottom; on by default, the switch comes with #312 (phase B). |
| #311 questions 6 and 7: the limits on progress events and the transport guards (stdout caps, native `maxPayload`, `maxChars`). | Keep them as progress, transport and harness limits; they are documented in [openclaw-integration.md](openclaw-integration.md#reading-final-replies). |
| #311 question 8: 0.6 phones before #313. | An over-size message goes as a head excerpt plus a note that the full answer is on the Mac (already in `EngineBridge`); a `> request excerpt` line on new results comes with phase B. |
| #311 question 9: remote images in Markdown. | Draw local image files only; remote URLs stay links (phase B). |
| #311 question 10: Mac search scope. | ⌘F on the Mac searches the main timeline; the phone's search covers sub-chats too (phase B). |
| #311 question 11: when the issue closes. | When Part 1 (phases A and B) is merged; each Part 2 item is built in the issue named next to it. |
| Replace the installed v1 `/Applications/Yorozu.app` with v2. | Leave v1 installed; the owner decides. |
| Commit f710949 published R1-era docs and OpenClaw template files (local paths, no personal facts); they are gone from the tree but remain in history. | No history rewrite. |
| The Mac signing identity in `apps/mac/Project.swift` carries the owner's legal name, and the routing policy in `Engine.swift` names the vault app; the owner decides whether to make them generic. | Leave the code as is. |
| Coding workers load the owner's personal Claude Code and Codex setup ([openclaw-integration.md](openclaw-integration.md#what-the-agent-sees)). | Accept it as known leakage. |

## Known limits

Each limit is described where its mechanism is documented.

- Thinking workers take a change after the current step, coding workers after the current run; no live steer ([openclaw-integration.md](openclaw-integration.md#methods-used), `tools.invoke`).
- A launch that falls back to the CLI transport shows sub-chat progress only when a step ends ([openclaw-integration.md](openclaw-integration.md#transport)).
- The Mac shows no sub-chats and phones get them only with #313, so until then no UI shows topics, work or events.
- A coding result's diffstat misses committed work ([openclaw-integration.md](openclaw-integration.md#methods-used), `sessions.diff`).
- Memory search is lexical over a note's title and summary only, so it misses paraphrases ([architecture.md](architecture.md#memory), Search).
- A symlink or a duplicate note `id` in the memory directory leaves the app not ready; other bad files are skipped and listed in a launch notice ([architecture.md](architecture.md#memory), Strictness).
- Memory write rules bind thinking workers by prompt, not by sandbox ([architecture.md](architecture.md#memory), Worker access).
- A run interrupted by an app restart is watched for about 2 hours, then the user is asked to retry ([architecture.md](architecture.md#restart-and-resume)).
- An uncertain task whose run stays running or unknown blocks new work of its executor in its topic until it settles or is stopped; there is no dismiss action yet ([architecture.md](architecture.md#uncertain-blockers)).
- Mac distribution and the missing iOS features are roadmap item 7.
- Computer-use rules are prompt policy, not code. Tasks in different topics or with different executors run at once, even on the same app; CuaDriver serializes their input calls but not their sequences ([cua-integration.md](cua-integration.md#concurrency)).
- Claude Code coding workers do not get Yorozu's MCP servers, because OpenClaw 2026.9.6 does not pass session `toolOverrides` to its CLI runner; new coding work that needs an app goes to Codex (owner decision; [openclaw-integration.md](openclaw-integration.md#mcp-servers)).
- Yorozu's MCP list is read once per app run; a server added to OpenClaw while the app runs reaches Yorozu sessions until the next launch ([openclaw-integration.md](openclaw-integration.md#mcp-servers)).
- The host Mac has no Simulator.app, so the iOS UI cannot be tapped through on it. `simctl` and iOS 27 runtimes are installed, so headless boot and screenshots work; full UI checks need a device.
