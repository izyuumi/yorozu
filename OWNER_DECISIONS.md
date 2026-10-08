# Owner decisions

The owner's decisions that are in force now, by area. Each line ends with the date it was made or last changed. The full log, superseded entries included, is [docs/history/decisions-log.md](docs/history/decisions-log.md).

When the owner makes or changes a decision, rewrite the line here so no two lines contradict, and append the entry to the log. Open questions and their defaults live in [docs/status.md](docs/status.md).

## Product and UX

- One main timeline is the only place to type. Each topic has an inspect-only sub-chat. (2026-10-07)
- The main timeline shows no topic labels, IDs or routing controls. Sub-chats show their topic name. (2026-10-07)
- Layout: the main conversation fills the window with its composer always available. Sub-chats open from the toolbar as a popup listing topic-named sub-chats with simple running/done indicators; selecting one shows its inspect-only timeline there. (2026-10-07)
- Delegation posts no acknowledgment and no boilerplate such as "I'll work on that in the background". A toolbar progress indicator shows running work. Steer, stop, correction and failure notices stay short and factual, and app-generated notices never enter the secretary's context. (2026-10-08)
- A finished result goes into the main timeline at once and names the request it answers. A background completion does not change the active topic. (2026-10-07)
- Worker activity (public messages, progress and tool events, never private reasoning) appears in the sub-chat at message granularity, never in the main timeline. (2026-10-07)
- On a worker failure or lost connection, post a brief notice; the user says "retry" to continue in the same sub-chat. There is no automatic retry, and a run's real status is reconciled before any retry so no duplicate starts. (2026-10-07)
- No in-app memory view, editor or reindex control. Memory stays reachable as Markdown files. (2026-10-07)
- Input is conversation and pasted text only; no document import. (2026-10-07)
- The Mac app is native SwiftUI with selective AppKit, never a web UI or webview wrapper. Use native SwiftUI components wherever they fit, so the app gets the system look (Liquid Glass). (2026-10-07)

## Routing

- A small secretary model reads each message with the last few messages, the topic list and memory search. It replies to quick turns, asks for clarification and coordinates, and running work never blocks it. (2026-10-07)
- Substantive thinking, analysis, research, tool use and code are delegated automatically; the secretary does not try them first. (2026-10-07)
- A clear follow-up goes to the latest user-discussion topic. If the target is still unclear, one internal review by a stronger model runs, then the user gets a short clarifying question. (2026-10-07)
- Topics are broad subjects or goals. The app's own UX, memory and code stay under one PROJECTX topic. No automatic topic merging or splitting. (2026-10-07)
- A change to running work steers that same task and never starts a separate one. (2026-10-07)
- Wrong-topic recovery stops the mistaken work if it is running, sends the instruction to the intended existing topic and leaves the mistaken history where it is. A stop is reported as confirmed only after it is acknowledged. (2026-10-07)

## Workers

- The secretary/worker split is core architecture: workers run in topic sub-chats in bounded parallel lanes. (2026-10-07)
- One persistent sub-chat per topic, reused for later requests. Its worker session keeps growing; how to compact it is to be discussed later. (2026-10-07)
- Topic workers run at full permission with OpenClaw's default tools. (2026-10-07)
- Workers carry a request through end to end, including commit, merge, push, rebuild and restart when the chat asks for it, and ask only for what only the owner can do (logins, approvals, secrets). They take no unrequested destructive or outward-facing action and leave the owner's uncommitted files untouched. (2026-10-08)
- Workers operate the Mac through cua: approach A first, with the computer-use rules in the thinking and coding worker prompts and no separate executor until collisions or timeouts call for one. (2026-10-08)
- Yorozu keeps the list of MCP servers its workers may use, so switching harness does not move tool registrations. The list is data only: harness adapters apply it, and Yorozu never starts servers or runs tool calls. Both thinking and coding workers get it. (2026-10-08)

## Memory

- Memory is automatic, persistent, owned by the user and the most important part of the product; the user never has to say "remember this". (2026-10-07)
- Keep useful topic knowledge as well as personal facts, preferences and decisions. Attribution stays separate: a pasted source claim or an assistant analysis never becomes a user belief or a verified fact. (2026-10-07)
- Markdown files are the single source of truth. The SQLite index is disposable and rebuilt from them; no filesystem watching. Vector retrieval may extend this later. (2026-10-07)
- Memory is global, not partitioned by topic, and retrieved selectively. (2026-10-07)
- Forgetting deletes the Markdown memory and refreshes the index. Chat history is never deleted, redacted or rewritten. (2026-10-07)
- Workers may edit memory files, scoped to the memory directory. (2026-10-07)
- App state goes in Application Support and the index in Caches (Apple guidance); the Markdown memory is visible in `~/Yorozu/memory`. The app has no migration code; data moves are done by hand. Paths: [docs/setup.md](docs/setup.md#where-data-lives). (2026-10-07)

## Platform and release

- The Mac app is a Tuist-generated Xcode project and takes v1's identity (bundle id, signing team, entitlements), so v2 installs as an update of v1. (2026-10-07)
- iPhones are clients of the host Mac through v1's end-to-end-encrypted Cloudflare Workers relay, reused as a deployed service, with v1's chat input UI. New client and host code stays Swift. The relay may be changed when that is the better design. (2026-10-08)
- iOS ships to internal TestFlight only. Build numbers are per version, start at 1 and ascend. (2026-10-08)
- The app icon is v1's Icon Composer mark (blob-identical to 1e2f1fba). (2026-10-08)
- CuaDriver stays a separately installed app. Yorozu does not bundle it or keep its daemon running; `cua-driver mcp` starts the daemon itself. (2026-10-08)

## Engineering

- Stack: SwiftUI with selective AppKit, structured concurrency, GRDB/SQLite, Markdown memory with an FTS5 index, and a Swift OpenClaw harness. Not used: Electron, Tauri, web frontends, SwiftData, Core Data, agent orchestration frameworks, vector services, plugin loaders, Python or HTTP sidecars. (2026-10-07)
- Working rules the owner set live in [AGENTS.md](AGENTS.md#rules); their dates are in the log.

## Roadmap

- Order: R1 thinking workspace, then R2 coding workers that develop Yorozu itself, then the iOS client over the relay on internal TestFlight, then R3, cua (https://cua.ai) integration so Yorozu can operate the user's computer. Progress: [docs/status.md](docs/status.md#roadmap). (2026-10-08)
