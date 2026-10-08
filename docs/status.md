# Status

As of 2026-10-09, `projectx` at 59a983e, with batch 1 of issue #310 (context budgets) on branch `context-budgets`. Update this file when a part changes state; keep only the current picture. Past decisions are in [history/decisions-log.md](history/decisions-log.md).

## Parts

| Part | State | Evidence |
|---|---|---|
| Mac app (`build/Yorozu.app`) | Done | Tuist/Xcode build with the toolbar sub-chat popover, Copy button and native Markdown (2dbab14, acbd66e, eeb9c7c); hosts the iOS relay and the Pair iPhone sheet (488a478, 9533000). Current dev build: 0.6.1 (1). |
| Secretary routing | Done | Verified live 2026-10-08. Routing was tuned and replayed against 21 real messages twice: topic choice about 50% → 100%, action choice about 75–80% → 95% (c070aa2, 56df548). PAIOS, file and calendar questions go to a worker (865922d). |
| Thinking workers | Done | Verified live 2026-10-08: delegation, same-topic follow-up in the same session, and a change sent to a running task, applied as a follow-up turn with the first answer kept as `superseded_result`. |
| Markdown memory | Done; quality unmeasured | Automatic extraction writes `~/Yorozu/memory/knowledge/*.md`; index in Caches (12e0c4f). Extraction quality has not been evaluated. |
| Coding workers (R2) | Done | Verified live 2026-10-08 from the chat: Claude Code rewrote the README (d7e0b1d) and Codex added a note (bfb15d7); each committed, merged into `projectx`, ran `build_native.sh --restart`, and the relaunched app delivered the result. |
| iOS client and relay (0.6.x) | Shipped to internal TestFlight; device check pending | Latest upload 0.6.1 (5) after the icon commit; 0.6.1 (4) came before it, and 0.6.0 (10127) is expired. Live 2026-10-08: the Mac registered on the default relay ([setup.md](setup.md#environment-variables)), and a headless phone built on the app's `RelayClient` paired, passed the `yorozu-v2` check, received history, sent a message and got the receipt and the reply. On 2026-10-08 App Store Connect showed 0.6.1 (5) in beta testing for the Internal group. Nobody has tapped through the iOS UI on a device yet. |
| Context budgets (issue #310) | Batch 1 done in code; live check pending | Thinking topic sessions are compacted at half the window and overflow fails with a specific message ([openclaw-integration.md](openclaw-integration.md#compaction)); coding workers get the user's message verbatim and byte-cut history; the routing view is slim and trimmed on the final prompt, with IDs checked against the full snapshot; uncertain blockers are reconciled (decision 7); extraction stays within the raw-prompt cap and records failure reasons; bad memory files are skipped and reported; old note versions move to `history/`; the stronger review has its own model setting ([architecture.md](architecture.md)). `contextWindow: 272000` is set for the two pool models in the host's OpenClaw config. Not yet rebuilt into `build/Yorozu.app` or checked from the chat. |
| R3 computer use via cua | Done for thinking workers; Claude Code left without Yorozu's MCP servers (owner decision) | 7f2e2f0, 67f6cce: Yorozu owns the MCP server list (`mcp-servers.json`, default cua-driver) and mirrors it into OpenClaw per session; "operate my Mac / use app X" is delegated; both worker contracts carry the cua rules. Verified live 2026-10-08: the TextEdit smoke test passed from the chat with TextEdit kept in the background, and an owner request drove Safari in the background ([cua-integration.md](cua-integration.md#smoke-test)). After 67f6cce a second smoke run passed with a per-run cua session label. Codex coding workers get the tools but were not exercised; Claude Code coding workers do not get them ([known limits](#known-limits)). |

## Roadmap

1. R1, native thinking workspace: done.
2. R2, coding workers that develop Yorozu itself: done.
3. iOS client 0.6.x over the relay on internal TestFlight: shipped; the owner's on-device check is pending.
4. R3, cua integration so Yorozu operates the user's computer: first step done (thinking workers, verified from the chat). Next: Claude Code coding workers once OpenClaw passes session tool settings to them; a dedicated computer executor only if collisions or timeouts show up.
5. Context budgets (issue #310), before the UI issue: batch 1 done in code, its live check pending. Batch 2 next: send the thinking session only what it has not seen, tool-output rules in the worker contract, topic-aware secretary context and topic list, Japanese-capable memory search, lighter coding-history polling, instruction growth on retry, and removing Yorozu's caps on worker answers (owner decision 2026-10-09).
6. Later, unscheduled: iOS push notifications, Stop, attachments and sub-chats (iOS 0.6.x has one thread and none of these); Mac distribution (notarization, an update feed); document import; vector retrieval; automatic topic merge and split; a dismiss action for stale uncertain tasks.

## Open items

Each item has a default that holds until the owner answers.

| Item | Default |
|---|---|
| Install 0.6.1 (5) from TestFlight, pair it from the Mac's Pair iPhone sheet and send one message. | 0.6.x counts as shipped; a device bug becomes a 0.6.x fix. |
| When the iOS features in roadmap item 6 arrive. | After R3. |
| The owner's own OpenClaw MCP entries (`cua-driver`, the broken `cua`, `computer-use`) stay global for other agents; Yorozu sessions switch them off. | Leave them; the owner fixes or removes `cua`. |
| An OpenClaw workspace plugin of the owner's gates cua-driver browser and input calls on browser pids for every agent, and its `/Arc/` pattern also matches non-browser apps such as Archive Utility. | Leave the plugin as is. |
| Batch 2 splits the "Worker contract" item: the tool-output rules stay and the answer-length rule goes. This reading of the 2026-10-09 decision is not owner-confirmed. | Keep the tool-output rules; they limit session growth, not answer size. |
| The secretary model's 8,192-token output cap can cut extraction JSON (issue #310, finding 13); computed model defaults come with the Settings issue. | Keep today's model ids until then, no interim assignment. |
| `chat.history` `maxChars` tops out at 500,000 UTF-16 units in the Gateway, which then appends its own truncation marker. | When batch 2 removes Yorozu's caps, read final answers at that maximum and show the Gateway's marker as is. |
| Replace the installed v1 `/Applications/Yorozu.app` with v2. | Leave v1 installed; the owner decides. |
| Commit f710949 published R1-era docs and OpenClaw template files (local paths, no personal facts); they are gone from the tree but remain in history. | No history rewrite. |
| The Mac signing identity in `apps/mac/Project.swift` carries the owner's legal name, and the routing policy in `Engine.swift` names the vault app; the owner decides whether to make them generic. | Leave the code as is. |
| Coding workers load the owner's personal Claude Code and Codex setup ([openclaw-integration.md](openclaw-integration.md#what-the-agent-sees)). | Accept it as known leakage. |

## Known limits

Each limit is described where its mechanism is documented.

- Thinking workers take a change after the current step, coding workers after the current run; no live steer ([openclaw-integration.md](openclaw-integration.md#methods-used), `tools.invoke`).
- Over the default CLI transport, sub-chat progress appears only when a step ends ([openclaw-integration.md](openclaw-integration.md#transport)).
- A coding result's diffstat misses committed work ([openclaw-integration.md](openclaw-integration.md#methods-used), `sessions.diff`).
- Memory search is lexical only, and Japanese queries match almost nothing until batch 2 ([architecture.md](architecture.md#memory), Index).
- A symlink or a duplicate note `id` in the memory directory leaves the app not ready; other bad files are skipped and listed in a launch notice ([architecture.md](architecture.md#memory), Strictness).
- Memory write rules bind thinking workers by prompt, not by sandbox ([architecture.md](architecture.md#memory), Worker access).
- A run interrupted by an app restart is watched for about 2 hours, then the user is asked to retry ([architecture.md](architecture.md#restart-and-resume)).
- Until batch 2 of issue #310, a thinking answer over 64000 bytes is refused and a coding result is cut at 60000 characters ([openclaw-integration.md](openclaw-integration.md#methods-used), `agent`; [architecture.md](architecture.md#workers)).
- An uncertain task whose run stays running or unknown blocks new work of its executor in its topic until it settles or is stopped; there is no dismiss action yet ([architecture.md](architecture.md#uncertain-blockers)).
- Mac distribution and the missing iOS features are roadmap item 6.
- Computer-use rules are prompt policy, not code. Tasks in different topics or with different executors run at once, even on the same app; CuaDriver serializes their input calls but not their sequences ([cua-integration.md](cua-integration.md#concurrency)).
- Claude Code coding workers do not get Yorozu's MCP servers, because OpenClaw 2026.9.6 does not pass session `toolOverrides` to its CLI runner; new coding work that needs an app goes to Codex (owner decision; [openclaw-integration.md](openclaw-integration.md#mcp-servers)).
- Yorozu's MCP list is read once per app run; a server added to OpenClaw while the app runs reaches Yorozu sessions until the next launch ([openclaw-integration.md](openclaw-integration.md#mcp-servers)).
- The host Mac has no Simulator.app, so the iOS UI cannot be tapped through on it. `simctl` and iOS 27 runtimes are installed, so headless boot and screenshots work; full UI checks need a device.
