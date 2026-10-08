# Status

As of 2026-10-08, `projectx` at f154d58. Update this file when a part changes state; keep only the current picture. Past decisions are in [history/decisions-log.md](history/decisions-log.md).

## Parts

| Part | State | Evidence |
|---|---|---|
| Mac app (`build/Yorozu.app`) | Done | Tuist/Xcode build with the toolbar sub-chat popover, Copy button and native Markdown (2dbab14, acbd66e, eeb9c7c); hosts the iOS relay and the Pair iPhone sheet (488a478, 9533000). Current dev build: 0.6.1 (1). |
| Secretary routing | Done | Verified live 2026-10-08. Routing was tuned and replayed against 21 real messages twice: topic choice about 50% → 100%, action choice about 75–80% → 95% (c070aa2, 56df548). PAIOS, file and calendar questions go to a worker (865922d). |
| Thinking workers | Done | Verified live 2026-10-08: delegation, same-topic follow-up in the same session, and a change sent to a running task, applied as a follow-up turn with the first answer kept as `superseded_result`. |
| Markdown memory | Done; quality unmeasured | Automatic extraction writes `~/Yorozu/memory/knowledge/*.md`; index in Caches (12e0c4f). Extraction quality has not been evaluated. |
| Coding workers (R2) | Done | Verified live 2026-10-08 from the chat: Claude Code rewrote the README (d7e0b1d) and Codex added a note (bfb15d7); each committed, merged into `projectx`, ran `build_native.sh --restart`, and the relaunched app delivered the result. |
| iOS client and relay (0.6.x) | Shipped to internal TestFlight; device check pending | Latest upload 0.6.1 (5) after the icon commit; 0.6.1 (4) came before it, and 0.6.0 (10127) is expired. Live 2026-10-08: the Mac registered on the default relay ([setup.md](setup.md#environment-variables)), and a headless phone built on the app's `RelayClient` paired, passed the `yorozu-v2` check, received history, sent a message and got the receipt and the reply. On 2026-10-08 App Store Connect showed 0.6.1 (5) in beta testing for the Internal group. Nobody has tapped through the iOS UI on a device yet. |
| R3 computer use via cua | Not started | Design only: [cua-integration.md](cua-integration.md). No code on `projectx`. |

## Roadmap

1. R1, native thinking workspace: done.
2. R2, coding workers that develop Yorozu itself: done.
3. iOS client 0.6.x over the relay on internal TestFlight: shipped; the owner's on-device check is pending.
4. R3, cua integration so Yorozu operates the user's computer: next. Steps: choose how workers call cua; a worker operates an app on the Mac through cua; a live check from the chat.
5. Later, unscheduled: iOS push notifications, Stop, attachments and sub-chats (iOS 0.6.x has one thread and none of these); Mac distribution (notarization, an update feed); chat compaction; document import; vector retrieval; automatic topic merge and split.

## Open items

Each item has a default that holds until the owner answers.

| Item | Default |
|---|---|
| Install 0.6.1 (5) from TestFlight, pair it from the Mac's Pair iPhone sheet and send one message. | 0.6.x counts as shipped; a device bug becomes a 0.6.x fix. |
| When the iOS features in roadmap item 5 arrive. | After R3. |
| How R3 workers call cua. | The cua-driver MCP server, as [cua-integration.md](cua-integration.md) recommends. |
| The `cua` MCP entry in the OpenClaw config points at a missing app. | Leave it; R3 uses `cua-driver`. The owner fixes or removes it. |
| Model per role is not owner-decided. | Keep the code defaults listed in [setup.md](setup.md#models). |
| Replace the installed v1 `/Applications/Yorozu.app` with v2. | Leave v1 installed; the owner decides. |
| Commit f710949 published R1-era docs and OpenClaw template files (local paths, no personal facts); they are gone from the tree but remain in history. | No history rewrite. |
| The Mac signing identity in `apps/mac/Project.swift` carries the owner's legal name, and the routing policy in `Engine.swift` names the vault app; the owner decides whether to make them generic. | Leave the code as is. |
| Coding workers load the owner's personal Claude Code and Codex setup ([openclaw-integration.md](openclaw-integration.md#what-the-agent-sees)). | Accept it as known leakage. |

## Known limits

Each limit is described where its mechanism is documented.

- Thinking workers take a change after the current step, coding workers after the current run; no live steer ([openclaw-integration.md](openclaw-integration.md#methods-used), `tools.invoke`).
- Over the default CLI transport, sub-chat progress appears only when a step ends ([openclaw-integration.md](openclaw-integration.md#transport)).
- A coding result's diffstat misses committed work ([openclaw-integration.md](openclaw-integration.md#methods-used), `sessions.diff`).
- Memory search is lexical only ([architecture.md](architecture.md#memory), Index).
- A stray file or symlink in the memory directory leaves the app not ready ([architecture.md](architecture.md#memory), Strictness).
- Memory write rules bind thinking workers by prompt, not by sandbox ([architecture.md](architecture.md#memory), Worker access).
- A run interrupted by an app restart is watched for about 2 hours, then the user is asked to retry ([architecture.md](architecture.md#restart-and-resume)).
- Compaction, Mac distribution and the missing iOS features are roadmap item 5.
- The host Mac has no Simulator.app, so the iOS UI cannot be tapped through on it. `simctl` and iOS 27 runtimes are installed, so headless boot and screenshots work; full UI checks need a device.
