# Owner decisions

The owner's decisions that are in force now, by area. Each line ends with the date it was made or last changed. The full log, superseded entries included, is [docs/history/decisions-log.md](docs/history/decisions-log.md).

When the owner makes or changes a decision, rewrite the line here so no two lines contradict, and append the entry to the log. Open questions and their defaults live in [docs/status.md](docs/status.md).

## Product and UX

- One main timeline is the only place to type. Each topic has an inspect-only sub-chat. (2026-10-07)
- The main timeline shows no topic labels, IDs or routing controls. Sub-chats show their topic name. (2026-10-07)
- Layout: the Mac app is a menu-bar host. Clicking its icon opens a compact popover with the main timeline and its composer; the Mac has no sub-chat UI. The iPhone is the full client with sub-chats, controls and jobs (not yet implemented; phone sub-chats come with #313). The Mac is the single source of truth, is assumed always running and keeps running when its UI closes; only Quit ends it. Settings is a standard macOS Settings window, opened with ⌘, or from the menu-bar menu. (2026-10-09)
- Delegation posts no acknowledgment and no boilerplate such as "I'll work on that in the background". The menu-bar icon and the popover header show running work. Steer, stop, correction and failure notices stay short and factual, and app-generated notices never enter the secretary's context. (2026-10-09)
- Notices are compact system rows with an icon, distinct from answers; failures read in plain language with a Details disclosure for the raw error. New notices are stored as a code plus parameters and rendered in the user's language at display time. Storage is implemented; the rows and Details are not yet implemented. (2026-10-09)
- A finished result goes into the main timeline at once. A background completion does not change the active topic. Results are stored without the `Regarding “…”:` prefix and a quoted, tappable reply header is drawn from `replyTo` at display time; Copy copies only the answer, and old results keep their stored prefix. The prefix change and the header are not yet implemented. (2026-10-09)
- Worker activity (public messages, progress and tool events, never private reasoning) appears in the sub-chat at message granularity, never in the main timeline. A tool row names the real tool behind `tool_call` and the app it targets, never arguments, for example "cua: type_text in TextEdit". (2026-10-09)
- Timeline: day separators, the exact time on hover (Mac) or long-press (phone), and "sent … · delivered …" on delayed messages. The view stays put while the user reads, a "↓ N new" pill appears, and sending jumps to the bottom. Not yet implemented. (2026-10-09)
- Search covers everything on both devices: ⌘F in the Mac popover and a search field on the phone. The Mac searches its full history with a full-text index (SQLite FTS, like memory) and the phone sends its queries over the relay; a hit jumps to the message in context. The index and the engine call are implemented; the search UI is not yet implemented. (2026-10-09)
- Mac attention: a dot on the menu-bar icon and macOS notifications for results, failures and questions; tapping one opens the popover at that message. Both can be switched off in Settings, and a destination setting chooses this Mac, phones, or later a Mac client. Not yet implemented. (2026-10-09)
- An optional global shortcut opens the popover: preset ⌥Space, off by default, enabled or changed in Settings › General. Clicking the menu-bar icon is the default way in. Not yet implemented. (2026-10-09)
- Smart Enter is the default on the Mac popover and on hardware keyboards on iPhone and iPad: Enter sends a single-line draft; once the draft has more than one line, Enter adds a newline and ⌘Enter sends. A "⌘Enter to send" setting makes Enter always add a newline. The on-screen keyboard keeps its Send button. Not yet implemented. (2026-10-09)
- Phone: a long-press menu with Copy, Share and Show details; a draft over 6,000 bytes shows a hint and offers "Send as text file" (also on the Mac); an empty state says what Yorozu does with an example; Send always works (outbox). Not yet implemented. (2026-10-09)
- Interface text is in English and Japanese on both apps; the Mac gets a string catalog. Not yet implemented. (2026-10-09)
- On a worker failure or lost connection, post a brief notice; the user says "retry" to continue in the same sub-chat. There is no automatic retry, and a run's real status is reconciled before any retry so no duplicate starts. A context-overflow failure gets a specific message and no retry offer, since a plain retry would fail the same way. (2026-10-08)
- A new request blocked by an uncertain task reconciles that task's run first. Confirmed stopped: the task is retired with a notice and the new work starts. Completed: its result is delivered. Still running or unknown: it keeps blocking and the user is told why, so no run is duplicated. A dismiss action for stale uncertain tasks comes later. (2026-10-09)
- A message stays capped at 6,000 bytes; long text is a job for attachments, not a higher cap. (2026-10-08)
- No in-app memory view, editor or reindex control. Memory stays reachable as Markdown files. (2026-10-07)
- Input is conversation and pasted text only; no document import. (2026-10-07)
- The Mac app is native SwiftUI with selective AppKit, never a web UI or webview wrapper. Use native SwiftUI components wherever they fit. (2026-10-07)
- Both apps take the system look: native backgrounds, Liquid Glass bars, the vermilion accent and bubbles in system materials. The design is done in Claude Design, mockups first, before UI code. Not yet implemented; the mockups await the owner's approval. (2026-10-09)

## Routing

- A small secretary model reads each message with the last few messages, the topic list and memory search. It replies to quick turns, asks for clarification and coordinates, and running work never blocks it. (2026-10-07)
- Substantive thinking, analysis, research, tool use and code are delegated automatically; the secretary does not try them first. (2026-10-07)
- A clear follow-up goes to the latest user-discussion topic. If the target is still unclear, one internal review by a stronger model runs, then the user gets a short clarifying question. (2026-10-07)
- Topics are broad subjects or goals. The app's own UX, memory and code stay under one PROJECTX topic. No automatic topic merging or splitting. (2026-10-07)
- A change to running work steers that same task and never starts a separate one. (2026-10-07)
- Wrong-topic recovery stops the mistaken work if it is running, sends the instruction to the intended existing topic and leaves the mistaken history where it is. A stop is reported as confirmed only after it is acknowledged. (2026-10-07)

## Workers

- The secretary/worker split is core architecture: workers run in topic sub-chats in bounded parallel lanes. (2026-10-07)
- One persistent sub-chat per topic, reused for later requests. Before each thinking task Yorozu reads the topic session's token count and, at about half the model's usable window, compacts the session as its own step outside the task. The compaction is noted in the topic's sub-chat; a failed compaction posts a short failure notice in the main timeline. (2026-10-08)
- Coding executors are the ones the active harness offers (today Claude Code and Codex). They compact their own sessions; Yorozu detects a compaction, notes it in the sub-chat, and gives an overflow failure a clear error. (2026-10-09)
- Yorozu sets no size limit on what thinking and coding workers return: the UI renders any length and long results travel to the phone in chunks. The secretary and memory extraction get excerpts of results within their own budgets. Any length renders in full with proper formatting (code blocks that scroll sideways with Copy, real tables, rules, inline images) and no "Show more"; that renderer is not yet implemented. (2026-10-09)
- Topic workers run at full permission with OpenClaw's default tools. (2026-10-07)
- Workers carry a request through end to end, including commit, merge, push, rebuild and restart when the chat asks for it, and ask only for what only the owner can do (logins, approvals, secrets). They take no unrequested destructive or outward-facing action and leave the owner's uncommitted files untouched. (2026-10-08)
- Workers operate the Mac through cua: approach A first, with the computer-use rules in the thinking and coding worker prompts and no separate executor until collisions or timeouts call for one. (2026-10-08)
- Yorozu keeps the list of MCP servers its workers may use, so switching harness does not move tool registrations. The list is data only: harness adapters apply it, and Yorozu never starts servers or runs tool calls. Both thinking and coding workers get it. (2026-10-08)
- Computer-use concurrency stays in the prompts: each worker run uses its own cua session and never retries a timed-out action blindly. Across topics, two tasks may operate the same app at once until a code lane of one is added, which comes only if collisions or timeouts show up. (2026-10-08)
- Claude Code coding workers go without Yorozu's MCP servers until OpenClaw passes session tool settings to them; new coding work that needs an app or a browser goes to Codex unless the user names Claude Code, and work that continues a coding task keeps its executor. (2026-10-08)

## Memory

- Memory is automatic, persistent, owned by the user and the most important part of the product; the user never has to say "remember this". (2026-10-07)
- Keep useful topic knowledge as well as personal facts, preferences and decisions. Attribution stays separate: a pasted source claim or an assistant analysis never becomes a user belief or a verified fact. (2026-10-07)
- Markdown files are the single source of truth. The SQLite index is disposable and rebuilt from them; no filesystem watching. Vector retrieval may extend this later. (2026-10-07)
- Memory is global, not partitioned by topic, and retrieved selectively. (2026-10-07)
- Past versions of a note stay in the note until it would exceed its size cap; then the oldest move to a per-note history file, `<memory root>/history/<id>.md`, that search and the index skip. No version is lost. (2026-10-08)
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
- The native WebSocket Gateway transport is the default, so sub-chat progress is live. The Mac enrolls as a Gateway device once, during onboarding (#317, not yet implemented; until then from Settings). (2026-10-09)
- Model roles get defaults computed from the harness's model metadata, with no hard-coded model ids, and each role can be overridden in Settings › Advanced: the secretary and extraction take the cheapest allowed model with enough window and output cap; workers take the harness agent's primary model, else the most capable (highest-priced) one; the stronger routing review takes the most expensive allowed model that differs from the secretary's. Until that lands, today's ids stay and the stronger review has its own setting ([setup.md](docs/setup.md#models)). (2026-10-09)
- The OpenClaw config sets `contextWindow: 272000` for `openai-pool/gpt-6-sol` and `openai-pool/gpt-6-astra` (the owner's global file, approved). OpenClaw's global `contextPruning` stays off. (2026-10-08)
- Working rules the owner set live in [AGENTS.md](AGENTS.md#rules); their dates are in the log.

## Roadmap

- Order: R1 thinking workspace, then R2 coding workers that develop Yorozu itself, then the iOS client over the relay on internal TestFlight, then R3, cua (https://cua.ai) integration so Yorozu can operate the user's computer. Progress: [docs/status.md](docs/status.md#roadmap). (2026-10-08)
- Context budgets (issue #310) come before the UI work: batch 1, then batch 2. (2026-10-09)
