# Yorozu

Out-of-box personal AI assistant for macOS, remote-controlled from iOS through a blind end-to-end encrypted relay. Install, grant permissions once, scan one QR, start talking.

- Spec: `docs/spec-v1.html`
- Tickets: `tickets.md`

## Layout

- `apps/mac` — SwiftUI menu bar app, native tool host (SwiftPM executable, macOS 15+).
- `apps/ios` — SwiftUI iOS app (Tuist-generated Xcode project, iOS 18+).
- `apps/relay` — blind websocket relay that forwards ciphertext between Mac and phone.
- `packages/runtime` — Node agent loop, provider adapters, tools, memory, scheduler.
- `packages/shared` — protocol event types shared by the TypeScript workspaces.
- `packages/shared-swift` — SwiftUI views shared by the Mac and iOS apps.

## Runtime sidecar

`pnpm --filter @yorozu/runtime serve` (installed as the `yorozu-serve` bin) is what the Mac app
spawns. It loads or creates the Mac's X25519 and Ed25519 keypairs, registers its relay room, mints
a join token, prints the pairing payload, then answers each sealed message with the agent loop.
Stdout is the protocol the Mac app reads: `STATE <state>` per relay transition, `QR <json>` per
pairing payload.

| Variable | Default |
| --- | --- |
| `YOROZU_STATE_DIR` | `~/Library/Application Support/Yorozu` (holds `keys.json`, mode 600) |
| `YOROZU_RELAY_URL` | `ws://127.0.0.1:8787` |
| `YOROZU_BASE_URL` / `YOROZU_API_KEY` / `YOROZU_MODEL` | `https://api.openai.com/v1`, unset, `gpt-4o-mini` |

Pairing: the QR carries the Mac's X25519 key, the room ID and a one-time token. The phone joins the
room, announces its own X25519 key in one cleartext `hello` frame (authenticated by the relay's
per-frame signature check), and every frame after that is ChaCha20-Poly1305 sealed under the derived
session key.

## Mac app

```sh
pnpm --filter @yorozu/runtime build            # sidecar must be built first
docker run -p 8787:8787 yorozu-relay &         # or any relay
swift run --package-path apps/mac
```

The menu bar window shows the relay state and the pairing QR. The sidecar command is
`YOROZU_RUNTIME_CMD`, run through `/bin/sh -c`, defaulting to
`node ../../packages/runtime/dist/serve.js` (relative to `apps/mac`, i.e. the dev checkout layout);
the shipped app will point it at the bundled runtime. The sidecar is killed when the app quits.

## Memory

Facts live as one markdown file per fact in `YOROZU_MEMORY_DIR` (default
`<YOROZU_STATE_DIR>/memory`, itself defaulting to `~/Library/Application Support/Yorozu`).
Frontmatter carries `kind` (`preference`, `decision`, `correction`, `fact`, `approval`),
`created`, `threadId` and `agentId`. The files are the truth: edit them by hand or in Obsidian.

The SQLite FTS5 index next to them (`.index.sqlite`) is derived, and is rebuilt from the files
whenever it is missing or their mtimes have moved. The agent writes facts with the `remember`
tool; `recallForPrompt` returns a compact block that `runAgent` prepends to the system prompt
when given a `memory`. Vector recall is not implemented yet: `searchByEmbedding` returns nothing
until sqlite-vec or provider embeddings land.

## Providers

Three cards, as in the spec: Claude, Codex, OpenAI-compatible. Any one green is enough.

| Adapter | Spec prefix | How it authenticates |
| --- | --- | --- |
| `claudeCli` | `claude-cli/<model>` | the installed `claude` binary and its subscription login (`claude auth status --json`) |
| `codexCli` | `codex-cli/<model>` | the installed `codex` binary and its subscription login (`codex login status`) |
| `openaiCompat` | `openai/<model>` | `YOROZU_BASE_URL` + `YOROZU_API_KEY` |

Both CLI adapters use the vendor SDK for auth and streaming only — the runtime keeps its own
loop. The Claude adapter hands our `ToolDef`s to the SDK as an in-process MCP server and then
*denies* every call from `canUseTool`: the attempted call is the `tool_call` event the loop
wants, and the loop, not the CLI, runs the tool. (A tool named in `allowedTools` would be
auto-approved and executed in-process, which is why none are listed.) The Codex SDK has no
custom-tool mechanism, so that adapter streams text and ignores `tools`; keep a tool-capable
provider behind it in the chain.

`YOROZU_MODEL_CHAIN` is a comma list, primary first:

```sh
YOROZU_MODEL_CHAIN=claude-cli/claude-sonnet-5,codex-cli/gpt-5.6,openai/gpt-4o-mini
```

The first provider to emit an event wins. Anything that fails *before* its first event — auth,
HTTP 401/403/429, transport — advances to the next one; after the first event the turn is
half-spoken, so failures propagate rather than replay. Unset, the chain is the single
OpenAI-compatible adapter, as before.

`node dist/serve.js probe` prints one JSON line (`{"claude":{"ok":true},…,"chain":"…"}`) with
each card's state and never prints a secret. The Mac app's menu bar window uses it to colour the
cards, offers a Terminal.app login for the two CLIs (both logins are interactive browser round
trips), stores the OpenAI-compatible key in the Keychain, and passes base URL, key and chain to
the sidecar as environment variables.

Note that `@openai/codex-sdk` depends on `@openai/codex`, which vendors a ~277 MB platform
binary; the SDK is pointed at the user's own `codex` on PATH when there is one.

## Relay

The relay forwards ciphertext between Mac and phone and can read none of it. Rooms are keyed by
`base64url(sha256(macPublicKey))`. The Mac registers by signing a server-issued nonce with its
Ed25519 key, then mints one-time join tokens (10 minute TTL) that the phone redeems with a
signature over the token. Every frame carries a signature from the sender's registered key;
unsigned or mis-signed frames close the connection. While the Mac is offline, frames are buffered
in memory per room (24h TTL, 5 MB cap, oldest dropped first) and drained in order on reconnect.
Each room is rate limited to 60 frames per second.

Run it with one command (`PORT` defaults to 8787):

```sh
docker build -t yorozu-relay -f apps/relay/Dockerfile . && docker run -p 8787:8787 yorozu-relay
```

## Permissions and never-sleep

`apps/mac/Sources/YorozuMac/Permissions.swift` holds every grant check as a plain function, and
`Onboarding.swift` walks them one page at a time: Accessibility, Screen Recording, Full Disk
Access, Automation, Input Monitoring, Never Sleep. Each page deep-links to its System Settings
pane, re-checks every two seconds, and only unlocks Continue once the check is green or the step
is explicitly skipped. The wizard opens on first launch (`onboardingCompleted` in `UserDefaults`)
and again from **Set Up Permissions…** in the menu bar window.

| Grant | Check |
| --- | --- |
| Accessibility | `AXIsProcessTrusted()` |
| Screen Recording | `CGPreflightScreenCaptureAccess()` |
| Full Disk Access | opening `~/Library/Safari/Bookmarks.plist` or the TCC database |
| Automation | `NSAppleScript` probe per app; error `-1743` means denied |
| Input Monitoring | `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` |

Never-sleep is a `caffeinate -dims` child process the app owns — no `pmset`, no sudo, and the
assertion dies with the app. Toggle it in the wizard or the menu bar window; the choice is
remembered in `neverSleep`.

### Dev bundle

TCC keys grants by bundle ID and code signature, and a bare `swift run` binary has neither, so
every rebuild would look like a new app. `scripts/dev-bundle.sh` wraps the build product in a
minimal `.app` (bundle ID `to.yumi.yorozu`, `LSUIElement`, usage descriptions) and ad-hoc signs
it, so grants stick across rebuilds:

```sh
./scripts/dev-bundle.sh                      # prints apps/mac/.build/Yorozu.app
open apps/mac/.build/Yorozu.app              # or run the binary directly to see the checks
```

Every launch prints one `CHECK <grant> granted|denied` line per grant to stdout.

## Scheduler and transcripts

Jobs live as JSON in `<YOROZU_STATE_DIR>/schedule.json`: an ID, the thread the job fires in, the
instruction, either a `when` (ISO 8601 one-shot) or a `cron`, who created it and when it last ran.
The agent manages them with `schedule(instruction, at | cron)`, `unschedule(id)` and
`list_schedule`. Cron is a 5-field expression (`minute hour day-of-month month day-of-week`)
matched against local time by `src/cron.ts` — numbers, `*`, `*/n`, lists and ranges, no dependency.

There is no heartbeat: `startScheduler` wakes every 30s, asks which jobs are due, and hands each to
the sidecar, which runs it as a turn in the job's own thread and emits the reply to the phone
exactly as if the user had typed it. One-shots are dropped once fired; cron jobs record `lastRun`
so a second tick inside the same minute cannot double-fire them.

Every event the sidecar sees is appended to `<YOROZU_STATE_DIR>/transcripts/YYYY-MM-DD.jsonl`
(UTC day), readable back with `readTranscripts(since)` and by the agent through the
`read_transcripts` tool. A fresh schedule is seeded with the nightly consolidation job
(`0 3 * * *`, thread `system`), which tells the agent to read the last 24h and `remember` the
durable facts memory does not already hold. Unschedule it and it stays gone.

## iOS app

`apps/ios` is a real app target (bundle ID `to.yumi.yorozu.ios`, iOS 18+) depending on
`packages/shared-swift` by local path. Its Xcode project is generated from `apps/ios/Project.swift`
by Tuist and is not checked in — two manifests are fewer files than the eleven `tuist generate`
emits, and they cannot drift from the sources.

```sh
tuist generate --no-open --path apps/ios       # writes Yorozu.xcworkspace
xcodebuild build -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Scanning the QR from the Mac's menu bar stores the payload together with a freshly generated
device identity — Ed25519 for relay frame signatures, X25519 for the session key — in the
Keychain, then opens the one `Home` thread. `RelayClient` in `packages/shared-swift` is the phone
half of the relay protocol (join, cleartext `hello`, sealed events); it owns no UI state, so the
Mac app can reuse it for local chat later.

Replies stream: the sidecar re-sends one message event per delta under a stable event id, each
carrying the whole text so far, and the phone replaces that message in place rather than appending.
The relay answers `joined` with `ownerOnline` and pushes `{"type":"owner","online":…}` whenever a
room's Mac connects or drops; that drives the "Mac offline" banner. Presence is routing state the
relay already keeps to decide whether to forward or buffer, so it stays blind to the ciphertext.

Join tokens are one-time, so re-pairing needs a fresh QR once the phone's socket has closed. Token
refresh belongs with the Threads ticket, which gives each device a lasting identity.

### End-to-end proof

`apps/ios/e2e/run.sh` is a test helper, not product code. It starts the relay, a fake
OpenAI-compatible provider (`e2e/fake-provider.mjs`, pointed at by `YOROZU_BASE_URL`) and the
runtime sidecar, creates a throwaway iPhone simulator, builds and installs the app, injects the
sidecar's pairing QR with `-yorozuPair '<json>'` (the simulator has no camera) plus `-yorozuSend hi`,
and asserts the streamed reply reaches the phone. The simulator is shut down and deleted on exit.

Unlike the CI compile check above, that build keeps code signing on: ad-hoc simulator signing is
what gives the app its `application-identifier` entitlement, and without one every Keychain write
fails with `-34018` (`errSecMissingEntitlement`), so pairing never persists. It needs no developer
account.

## Threads

A thread is an append-only log: `<YOROZU_STATE_DIR>/threads/<id>.jsonl`, one event per line,
with `threads.json` beside it as the index (`id`, `title`, `createdAt`, `archived`). `home` is
seeded on first run, is pinned, and never archives — `archiveThread("home")` refuses, and a
hand-edited index claiming otherwise is repaired on the next read. Only conversation events are
logged (`message`, `thought`, `tool_call`, `tool_result`, `approval_card`, `approval_answer`);
sync and thread admin are control traffic and leave no trace.

Every turn runs in its own thread and is given that thread's history as context: `threadHistory`
replays the last 40 messages and nothing cleverer yet (there is a `TODO` in `src/threads.ts` for
summarising what falls off the front). A turn nobody typed — a due job, a background delegation —
is recorded as the user message it stands in for, so the thread reads back whole.

The phone drives it with the events the protocol already has: `thread_create` (optional title),
`thread_archive` (the thread is the event's own `threadId`), and `thread_list`, which the sidecar
also sends unprompted the moment a device pairs. `sync_request` carries `lastSeen`, a last-held
event id per thread, and is answered with one `sync_delta` holding everything after those ids
across *every* live thread — capped at 200 events each, and an id the log no longer has means the
tail rather than nothing.

### Several phones at once

The sidecar keeps one session key per device, keyed by the X25519 key that phone announced in its
`hello`, instead of the single newest-wins key it had before. Agent events are sealed once per
device and broadcast; relay frames carry no sender, so an inbound box is attributed to whichever
session key opens it, which is also how a `sync_request` is answered to just the phone that asked.
Because every phone receives the copies meant for the others, `RelayClient` drops a frame it
cannot open silently rather than reporting it.

Join tokens stay one-time, but a burnt one is now replaced immediately: pairing mints the next
token and prints a fresh `QR` line, so the Mac's menu bar is always showing a code a second device
can use.

### Phone-side cache

`ThreadCache` in `packages/shared-swift` keeps the thread list and one file per thread under
`Application Support/threads`, each sealed with AES-GCM (CryptoKit) under a 32-byte key the app
stores in the Keychain (`CacheStore`, next to the pairing in `Keychain`). Application Support is
readable by anything that reaches the container, so the encryption — not the location — is what
protects it. A cache is only a cache: a missing, tampered or wrong-key file reads back empty, and
the `sync_request` the app sends on connect refills it. Unpairing deletes the files and the key.

That is what makes the app work offline: the list and every thread are read from disk at launch,
before the relay is even reachable.

## Browser

`packages/runtime/src/tools/browser.ts` drives a Chromium-family browser over CDP — the protocol
is JSON over one WebSocket and `ws` is already a dependency, so there is no puppeteer or
playwright here. The browser is launched with `--remote-debugging-port=<free port>`,
`--user-data-dir=<YOROZU_STATE_DIR>/browser-profile` and `--no-first-run`: a profile of the
agent's own, so the user's tabs, cookies and logins are never touched.

| Tool | What it does |
| --- | --- |
| `browser.open(url)` | opens a tab already navigated to `url`, returns its tab ID |
| `browser.snapshot(tabId)` | title, URL, visible text, and every interactive element numbered |
| `browser.click(tabId, ref)` | clicks the element with that number from the latest snapshot |
| `browser.type(tabId, ref, text)` | focuses it, sets its value, fires `input` and `change` |
| `browser.eval(tabId, js)` | evaluates JavaScript and returns the result as JSON |
| `browser.close(tabId)` | closes a tab the agent opened |

A snapshot parks the interactive elements on `window.__yorozu` and numbers them, so `click` and
`type` name one by number instead of the model inventing a selector; a stale number is an error
telling it to snapshot again. Only tabs the agent opened are tracked, and `close` refuses any
other tab — the sidecar closes all of them (and the process) on shutdown.

`YOROZU_BROWSER` carries the Mac app's **Browser** picker:

| Value | Meaning |
| --- | --- |
| `bundled` | Chrome for Testing, downloaded into `<YOROZU_STATE_DIR>/chrome` on first use |
| an absolute path | that executable, e.g. `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser` |
| unset | the first installed browser detected, else bundled |

Detection looks for Chrome, Chromium, Brave, Edge and Arc at their known bundle paths under
`/Applications`. The bundled download resolves the `mac-arm64` Stable build from the official
[Chrome for Testing endpoint](https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json),
logs its progress, checks the zip against its declared length, expands it with `ditto` (which
preserves the bundle's signature, and which Node's stdlib cannot do), and fails loudly rather
than leaving a partial download behind.

Tests run against an in-process fake CDP server that answers the Target and Runtime methods, so
they need no browser and pass on Linux CI. The real-launch test is skipped unless
`YOROZU_BROWSER` is set:

```sh
YOROZU_BROWSER=/Applications/Brave\ Browser.app/Contents/MacOS/Brave\ Browser \
  pnpm --filter @yorozu/runtime test
```

## Agents, delegation and skills

Every agent is a markdown file in `<YOROZU_STATE_DIR>/agents/<name>.md`: the body is its system
prompt, the frontmatter is opt-in restriction only. `model` is a provider spec the way
`YOROZU_MODEL_CHAIN` takes one, `tools` is an allowlist of tool names, `memory` is a
subdirectory of the memory directory to recall from, and `description` is the one line the main
agent sees when choosing. An absent field inherits the main agent's, so the shortest useful
specialist is a file with no frontmatter at all. `main.md` is the main agent's own prompt.

The five bundled agents (`main`, `calendar`, `email`, `browser`, `reservation`) live in
`packages/runtime/agents/` and are copied into the state directory on first run; a file you
edited is never written over, and one you delete comes back on the next start.

The main agent has one handle on the rest: `delegate(agent, task, background?)`. It runs the
specialist with its own message list seeded with `task` and returns its final text. Depth is
hard-capped at 2 — the specialist's tool list never contains `delegate`, so a specialist that
needs another specialist says what it needs and the main agent re-delegates. With
`background: true` the call returns a `delegation <id> started` line immediately and the result
arrives later as a new turn in the same thread (`delegation <id> finished: <result>`), through
the same programmatic-turn path the scheduler uses. Every event a specialist emits carries
`agentId: <specialist>` and `parentAgentId: "main"`, which is what the phone's drill-down will
render.

An `interrupt` event from the phone aborts the whole tree: the sidecar holds one `AbortController`
per running turn, `runAgent` takes the signal and stops at the next event, tool call or turn
boundary, and `delegate` passes the same signal to its children. An interrupted turn emits no
reply.

Skills are read in the AgentSkills format from `<YOROZU_STATE_DIR>/skills/<name>/SKILL.md` —
existing skill directories drop in unchanged, nothing is copied or rewritten. On startup their
names and descriptions are listed into the main system prompt; the body loads on demand through
the `skill(name)` tool. Agent and skill names from the model are resolved against the listing
rather than joined into a path.

## Native tools

`packages/runtime/src/tools/shell.ts` and `fs.ts` are plain Node: a command line through
`/bin/sh` with its combined output and exit status, and unrestricted file access running as the
user. Both cap a result at 20 000 characters — a result the model cannot afford is no use to
it. A non-zero exit is returned, not thrown: the model asked what happens, and the output plus
the status is the answer.

Screen and input need frameworks Node cannot reach, so `apps/mac` builds a second executable
beside the menu bar app: `yorozu-native`, which speaks one JSON request per line on stdin and
one response per line on stdout. The runtime spawns it once and multiplexes every call over
that pipe, matching each reply by the `rid` the helper echoes back (`rid`, not `id`: an element
ID travels as `id`, and the two must not collide).

| Tool | Helper command | What it does |
| --- | --- | --- |
| `shell` | — | a command through `/bin/sh`, combined output, optional `cwd` and timeout |
| `fs_read` / `fs_write` / `fs_list` | — | read a file, write one creating parents, list a directory |
| `screen_read` | `ax.read` | frontmost window as an indented tree: element ID, role, label, value, bounds |
| `screen_capture` | `screen.capture` | ScreenCaptureKit grab of the main display, saved as a PNG |
| `input_click` | `input.click` | CGEvent click on an element ID or on screen coordinates |
| `input_type` | `input.type` | CGEvent Unicode typing, so it is keyboard-layout independent |
| `input_key` | `input.key` | one key plus `cmd`/`shift`/`ctrl`/`alt`/`fn`, for shortcuts |

These names use `_` where the spec writes `.`, because provider function names are limited to
`[A-Za-z0-9_-]` and `screen.read` would be rejected.

Element IDs (`e1`, `e2`, …) are handed out by `ax.read` and live only inside the helper: an
`AXUIElement` reference means nothing to any other process, so only the IDs cross the pipe.
They stay valid until the next read. The walk is bounded at depth 12 and 400 nodes and skips
hidden and zero-sized elements with their subtrees — nothing clickable is lost, and a real tree
stays readable (Finder's window comes back as 400 nodes even so).

`screen_read` falls back to a screenshot on its own when the frontmost window exposes no tree,
as the spec asks, so the model gets something to work with rather than a dead end it has to
notice. `screen_capture` saves the PNG under `<YOROZU_STATE_DIR>/screenshots` and returns its
path rather than image content: none of the three adapters can carry an image back into a turn
today — the OpenAI-compatible one sends tool results as plain strings, the Claude one denies
every call and never sees a result, and Codex takes no tools at all — so an image-bearing tool
result would be plumbing with nothing on the other end.

`YOROZU_NATIVE_CMD` is the helper command, run through `/bin/sh`, defaulting to the
`swift build` product (`apps/mac/.build/debug/yorozu-native`) resolved from the runtime's
`dist/tools`. The Mac app overrides it with the copy inside its own bundle, which is also what
makes the grants stick: TCC keys Accessibility and Screen Recording on the bundle's signature,
so `scripts/dev-bundle.sh` copies the helper in next to the app binary. Without a bundle the
helper still works wherever the parent process already holds those grants.

The native tools are tested against a fake helper speaking the same line protocol, so they need
no AX, no display and no Mac; the `shell` and `fs` tests are real.

## Subagent drill-down

Everything the loop does now reaches the phone, not just the reply: `runTurn` and `delegate`
share `eventPayload`, so the main agent's tool calls and results travel as `tool_call` and
`tool_result` events tagged `agentId: "main"`, and a specialist's carry its own name plus
`parentAgentId`. (`thought` has no producer yet — the runtime's loop emits no thoughts — but
the views render one the moment something does.)

A delegation ends with the specialist's last message carrying `done: true` in `MessageData`.
That flag is the whole protocol addition: a delegation's end *is* its final message, so it
needed a field rather than a kind, and the flag is emitted from a `finally` so a specialist
that threw or was interrupted still closes its card instead of spinning forever.

`packages/shared-swift/Sources/YorozuShared/AgentTrace.swift` turns a thread's events into what
is drawn, as pure functions the Mac reuses:

| Function | Result |
| --- | --- |
| `delegationCards(from:)` | one `DelegationCard` per delegation — name, running/done, its events |
| `chatRows(from:)` | the thread in order: message bubbles, plus each card where its delegation started |
| `mainTrace(from:)` | the main agent's own thoughts, tool calls and results |

Cards are grouped by agent *and* delegation, not by agent alone: a card closes on its `done`
message, so the same specialist called twice is two cards. An event counts as delegated when it
carries a `parentAgentId`, which is what the runtime tags with and which can never catch the
phone's own events.

`TraceViews.swift` holds the three views: `DelegationCardView` (the inline card),
`MainActivityRow` (the collapsed `working… <tool>` line under the latest message, which draws
nothing until the main agent has run something), and `AgentTraceView` (the page both push).
Navigation is by value — `.agentTraceDestination { model.events }` on the stack resolves a
`TraceTarget` against the *live* event list, so an open trace keeps streaming rather than
showing the snapshot the link was built from.

The e2e harness proves the wire path: `e2e/fake-provider.mjs` calls `echo` on its first turn,
and `run.sh` waits for the phone to log `YOROZU-E2E-TOOL echo` beside the streamed reply.

## Approvals

Every tool with an effect outside the runtime declares an `actionClass` — the spec's list:
`send-message`, `purchase`, `delete-file`, `book`, `transfer-money`, `run-command`,
`edit-file`. Today that is `shell` (`run-command`) and `fs_write` (`edit-file`); the browser
tools stay undeclared until a later ticket decides which of their verbs actually reach the
world. A tool with no `actionClass` only reads, and is never gated. Alongside it each tool
carries a small extractor that turns the call's arguments into what the card names
(`{ target, amount? }`), so `shell` cards say which command and `fs_write` cards say which file.

The gate sits in the agent loop, before the tool runs, and returns one of three verdicts:

1. **The floor**, set during onboarding and kept in `<state dir>/approval.json`: any action at
   or above `moneyThreshold`, and any `delete-file` outside the state directory when
   `confirmIrreversibleDeletes` is on. The floor always asks. A `never` rule cannot reach it —
   that is the whole point of having one, so "stop asking me" can never end up spending money
   or deleting files on its own.
2. **The rules**, in the same file. A rule naming a target beats the class-level rule, because
   it is the more specific promise. `never` denies, `always` allows.
3. **Precedent**, from `<state dir>/approvals.jsonl` — one append-only row per answer. Three
   consistent yeses for a class and the agent stops asking about it. Mixed answers, fewer than
   three, or none: ask.

Asking means the sidecar emits an `approval_card` to every paired device and parks the tool
call until an `approval_answer` carrying that `actionId` comes back. Unanswered after ten
minutes it resolves as a refusal rather than hanging the turn, and an interrupt settles any
card still on screen. **Yes** runs the tool, **No** refuses it, and **Never** writes a
permanent rule — class-level, narrowed to the target only when the user actually named one.
**Discuss** decides nothing: it logs nothing, hands the agent a note asking it to explain
itself, and the card comes back with a fresh `actionId` when the agent tries again. A typed
`yes`, `no` or `never` in the thread answers the card the buttons would have.

`ApprovalCardView` lives in `packages/shared-swift` and renders the four buttons for both
platforms; the phone wires it into the thread today, and the Mac chat picks it up unchanged
when the local chat UI lands. The two floor settings are the last step of the Mac onboarding
wizard, which read-modify-writes `approval.json` so the rules the runtime learned are not lost.

No new event kind was needed: `approval_card` and `approval_answer` were already mirrored in
both `events.ts` and `Events.swift`.

## Model catalog and auto-assign

`catalog/models.json` is the catalog: one row per model, keyed by the same provider spec
`YOROZU_MODEL_CHAIN` takes (`claude-cli/claude-opus-5`, `openai/gpt-5.6-sol`), carrying price per
million tokens, context in thousands, strengths and the date the row was checked. A price nobody
publishes is `null` rather than a guess — that is what the two subscription-CLI rows and the
custom OpenAI-compatible endpoint say, since their cost is a login or the operator's own bill.

`.github/workflows/catalog.yml` uploads the file to a rolling release tagged `catalog` on every
push to `main` that touches `catalog/`, so clients have one stable URL to fetch:

| Source | When it is used |
| --- | --- |
| `<YOROZU_STATE_DIR>/catalog.json` | the cached asset, while it is under 24h old |
| `YOROZU_CATALOG_URL` (default the `catalog` release asset) | when the cache is missing or a day old |
| the stale cache, then `catalog/models.json` in the repo | when that fetch fails — offline is not empty |
| `<YOROZU_STATE_DIR>/catalog.overlay.json` | always, merged over the result field by field, by id |

The overlay is the only file research mode writes; the catalog is never rewritten, so a local
correction survives every refresh and a bad overlay is one file to delete.

`autoAssign` hands the default model every agent file and the catalog and asks for one model per
agent with a one-line reason. Each pick is written into that file's `model:` frontmatter — the
rest of the file, head and body, is left exactly as it was — and the run returns a unified diff.
The texts it replaced go to `assign.backup.json`, which is what Revert puts back.

In `research` mode the model first goes at the web through the agent loop with the runtime's
web-facing tools (`web_search` and `fetch` when the search ticket lands them, the browser tools
until then) and its answer is merged into the overlay before the picks are made.

It runs three ways: the `auto_assign_models` tool, so the agent can be told to do it and the
`schedule` tool can file it for later; `node dist/serve.js assign [catalog|research]`, which the
Mac app's **Assign now** button runs, showing the diff in a sheet with **Revert**; and the cron
field beside it, which is `assign-cron`, one job with a fixed id that the field creates, updates
or removes rather than piling up duplicates.

```sh
node dist/serve.js assign research   # refresh prices, assign, print the diff
node dist/serve.js assign-revert     # put the last run's files back
node dist/serve.js assign-cron '0 4 * * 1' catalog
```
## Calendar, reminders, mail, fetch and search

Calendar and reminders are EventKit, mail is AppleScript, and both live in the same
`yorozu-native` helper for the same reason the screen tools do: Node can reach neither.
`apps/mac/Sources/YorozuNative/Apple.swift` adds eleven commands to the line protocol.

| Tool | Helper command | What it does |
| --- | --- | --- |
| `calendar_list` | `calendar.list` | the user's calendars and whether each is writable |
| `calendar_events` | `calendar.events` | events in a window, defaulting to the next seven days |
| `calendar_create` | `calendar.create` | a new event, returning the id the others take |
| `calendar_update` | `calendar.update` | changes only the fields given |
| `calendar_delete` | `calendar.delete` | one event — one occurrence of a series, not the series |
| `reminders_list` | `reminders.list` | open reminders, soonest due first |
| `reminders_create` | `reminders.create` | a new reminder, with an optional due date and list |
| `reminders_complete` | `reminders.complete` | marks one done |
| `mail_unread` | `mail.unread` | unread inbox messages, with the id `mail_read` takes |
| `mail_read` | `mail.read` | one message, header line then body |
| `mail_send` | `mail.send` | sends from the user's Mail account |

EventKit is asked for access through the macOS 14+ full-access APIs
(`requestFullAccessToEvents`, `requestFullAccessToReminders`): write needs them, and asking
for less would turn every create into a failure later instead of a refusal now. That grant
is keyed on the Info.plist, so `scripts/dev-bundle.sh` carries the two `…FullAccess…` usage
descriptions beside the older ones.

Mail has no framework — its scripting dictionary is the only way in — so those three go
through `NSAppleScript`. Automation is a separate TCC grant, and on a Mac that has never
given it the Apple event comes back as **-1743**. That one code is translated into a sentence
naming the setting to change, so the model reports something the user can act on rather than
crashing or guessing. Dates cross the pipe as ISO 8601; a string with no zone is read as the
user's own local time, which is what a model writing `2026-09-12T14:00` means.

`fetch(url)` is plain Node: GET, redirects followed, and the readability pass is a heuristic
rather than a dependency. Scripts, styles and `<head>` go with their contents, nav, header,
footer, aside and form go as boilerplate, and when a page marks its own content with
`<article>` or `<main>` that subtree is all that is kept — unless it is a tenth the size of
the body, which means the wrapper is a stub and the body is the article. What is left is
tags off, entities decoded, whitespace collapsed, capped at 20 000 characters like every
other tool result. The URL reported back is where the redirects ended, not where they began.

`web_search(query)` follows the spec's two paths. `Provider.search` is a new optional
capability on the adapter interface: a provider that has native search implements it, the
chain forwards to the first one that does, and `claudeCli` implements it with Claude Code's
own `WebSearch` — the one call that *wants* the CLI to run a tool, so it is allowed rather
than denied the way `stream` denies everything. With no such provider, or when the native
search fails, the fallback drives DuckDuckGo's no-JavaScript endpoint through the agent's own
browser profile and reads the results off the page, unwrapping DuckDuckGo's redirector to the
real URLs. Top 8 either way, and the tab is closed again whichever way it goes.

Tests: `fetch` runs against a local HTTP server, `web_search` against a fake CDP endpoint
serving a canned DuckDuckGo page, and the calendar, reminders and mail tools against a fake
helper speaking the line protocol — including one that answers every mail command with
-1743, so the denied-Automation path is covered without needing a Mac that denies it.

## Mac local chat

The Mac runs the same chat as the phone, without the relay in the middle. The sidecar opens a
second way in beside its websocket: a Unix domain socket at `<state dir>/local.sock`, carrying
the same newline-delimited `YorozuEvent` JSON, in the clear. Nothing is encrypted because there
is nothing to encrypt against — the app and the sidecar are the same user on the same machine —
so the socket's mode is the access control, `0600` and nothing else. A socket file left by a
killed sidecar is removed before the bind; the live one goes away with `close()`.

Each connection is one more device in the sidecar's session map, so it costs nothing to reach:
`broadcast` already sends every reply, approval card and thread list to every paired device, and
a local client is simply one that needed no session key. Connecting is all the pairing there is,
and it is answered with the thread list the way a phone's `hello` is. The per-device event
handling that used to live inside the websocket's frame handler is now one `handleEvent` both
paths call, so the two cannot drift: thread admin broadcasts, `thread_list` and `sync_request`
answer the one device that asked, a typed `yes` still answers a card, and anything else is a turn.

| Client | Transport | Keys | Cache |
| --- | --- | --- | --- |
| iOS | `RelayTransport` — the existing `RelayClient` over the blind relay | X25519 session key per device | encrypted `ThreadCache`, so the phone reads offline |
| Mac | `LocalSocketTransport` — `local.sock` | none | none: this machine's thread logs are the originals |

`ChatTransport` is the seam, and it is all the two apps disagree about. `ChatModel`, `ChatView`,
`ThreadListView`, the trace views and the approval card now all live in `packages/shared-swift`
and compile for both platforms; what was iOS-only and stayed there is the pairing lifecycle
(`Session`, `PairingStore`, `CacheStore`, the QR scanner) and the end-to-end harness. The model
grew no knowledge of either platform: it takes a transport, an optional cache, and the device
name to tag its own events with. Three optional hooks — `onPaired`, `onThreads`, `onEvent` —
are how the iOS harness drives its first message and how the Mac logs that the list arrived,
which keeps the test scaffolding out of the shared model.

Making the views cross-platform cost two UIKit colours (`.secondarySystemBackground` became the
semantic `.quaternary` fill) and one `#if os(iOS)` around `navigationBarTitleDisplayMode`. The
phone's list pushes its chat; the Mac shows it beside the list, so `ThreadSidebar` is a second
list view — selection instead of a push, context menu instead of a swipe — sharing the ordering
(`visibleThreads`) and the `+` (`NewThreadButton`) with `ThreadListView` rather than copying them.

The menu bar window is now a `NavigationSplitView`: threads left, chat right, the detail half in
its own `NavigationStack` so the subagent drill-down and trace pages have somewhere to push.
Pairing QR, providers, browser and models moved into a standard `Settings` scene, reachable with
⌘, or from the gear at the foot of the sidebar, which also holds the permissions wizard, quit,
and the sidecar's relay state. The model is built and connected from `applicationDidFinishLaunching`
rather than from the window, because a menu bar window only exists while it is open and replies
and approval cards have to keep arriving either way.

Tests: `local.test.ts` round-trips a turn over the socket and checks that a broadcast reaches it,
that the mode is `0600`, and that the socket is gone once the sidecar closes; `ChatModelTests`
drives the model over a fake transport, which is the protocol's whole point. One thing the tests
pinned down: the model sends each event in a task of its own, so the order they reach the
transport in is not fixed — every event carries its own ids and the runtime matches on those.

## Install

The fresh-Mac walkthrough, in the order spec section 10 asks for:

1. Download `Yorozu-<version>.dmg` from the [Releases](https://github.com/izyuumi/yorozu/releases)
   page.
2. Open it and drag **Yorozu** onto the Applications shortcut beside it. Eject the disk image
   and launch Yorozu from Applications — it is a menu bar app, so it appears as an icon in the
   status bar rather than a window in the Dock.
3. The permission wizard opens on first launch and walks one grant per page: Accessibility,
   Screen Recording, Full Disk Access, Automation, Input Monitoring. Each page deep-links to
   its System Settings pane and re-checks every two seconds, so Continue unlocks on its own
   once the grant is green. Any step can be skipped and redone later from
   **Set Up Permissions…**.
4. Provider cards: one green card is enough. Claude and Codex log in through their own CLIs in
   Terminal; the OpenAI-compatible card takes a base URL and an API key, which is stored in the
   Keychain.
5. Set the two approval floor settings — what the agent may do unasked, and what always needs a
   yes.
6. Pick the browser the agent drives: the bundled Chromium (downloaded on first use) or one of
   your installed browsers. Either way it runs in a profile of its own.
7. Consent to never-sleep if you want the Mac reachable while it is idle. It is a `caffeinate`
   process the app owns, and it dies with the app.
8. Settings → **Pairing** is now showing a pairing QR. Open the Yorozu iOS app and scan it. Done.
   The menu bar window itself is the chat; ⌘, or the gear at the foot of the sidebar is the way
   to everything else.

Updates are Sparkle: **Check for Updates…** in the gear menu at the foot of the sidebar, against
the appcast published beside each release.

### The relay

The Mac and the phone only ever meet through a relay, so one has to be reachable from both. The
app's Settings → **Relay** field is the URL the sidecar dials; it defaults to
`ws://100.100.1.1:8787`, the Mac mini above over Tailscale, and moves to the hosted relay later.

Self-host it either way:

```sh
docker build -t yorozu-relay -f apps/relay/Dockerfile . && docker run -p 8787:8787 yorozu-relay
```

or, to keep it running on a Mac you already own, as a LaunchAgent:

```sh
pnpm --filter @yorozu/relay build
./scripts/install-relay-launchagent.sh          # writes ~/Library/LaunchAgents/to.yumi.yorozu.relay.plist
```

That one binds every interface on `PORT` (8787), keeps itself alive across crashes and reboots,
and logs to `~/Library/Logs/yorozu-relay.log`. Reach it over Tailscale rather than a forwarded
port: the relay is blind, but it is still a service, and Tailscale is what keeps it off the
public internet. `launchctl bootout gui/$(id -u)/to.yumi.yorozu.relay` stops it.

## Building the DMG

`scripts/build-mac.sh` is the shipping build, as against `scripts/dev-bundle.sh` above:

```sh
VERSION=0.1.0 ./scripts/build-mac.sh          # prints dist/Yorozu-0.1.0.dmg
```

It builds the workspace and the Swift release binaries, then assembles `Yorozu.app` with the
runtime *inside* it — the official `node` for this platform downloaded to
`Contents/Resources/node`, and the sidecar plus its production dependencies deployed next to
it — so the app needs nothing installed to run. `YOROZU_RUNTIME_CMD` defaults to that bundled
pair whenever the app finds it, and falls back to the dev checkout layout otherwise.

It is deliberately not *this machine's* `node`: a Homebrew node is a stub linked against
`@rpath/libnode.<abi>.dylib` and a dozen other Homebrew dylibs that no `.app` carries, so a
bundle built around one dies at launch with "Library not loaded" — and because the app only
checks that the bundled node *exists* before preferring it, that failure is silent: the
sidecar never starts and the menu bar sits at `starting`. The nodejs.org build links nothing
but system frameworks. The tarball is cached in `dist/`, and the build runs `node --version`
once before signing so a node that cannot start fails the build rather than the user.

The bundle is Developer ID signed with the hardened runtime and `apps/mac/Yorozu.entitlements`,
which is only the three exceptions Node needs: JIT, unsigned executable memory, and library
validation off (the bundled `node` links Homebrew's dylibs). There is no sandbox — the agent
drives the whole Mac. The DMG is signed too.

Note that the bundled runtime is large: `@openai/codex` and `@anthropic-ai/claude-agent-sdk`
vendor ~277 MB and ~194 MB of platform binaries respectively, which is most of the DMG. Moving
those to a first-run download is what the distribution ticket means by "runtime downloads on
first run".

### Notarizing

Notarization needs an App Store Connect API key — the `.p8`, its key ID, and the **issuer ID**
from the Users and Access → Integrations page. Store it once as a keychain profile and
`build-mac.sh` picks it up. Without one it prints `notarization skipped: no profile` and
carries on, leaving the DMG Developer ID signed but not notarized — Gatekeeper then asks on
first launch instead of opening silently.

```sh
xcrun notarytool store-credentials yorozu-notary \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
```

### Sparkle

The update feed is signed with an EdDSA key whose private half lives in the login keychain and
never leaves it:

```sh
./apps/mac/.build/artifacts/sparkle/Sparkle/bin/generate_keys   # once, prints the public key
./scripts/appcast.sh                                            # writes dist/appcast.xml
```

The public key goes in `SU_PUBLIC_KEY` in `build-mac.sh`, which writes it into the app's
`Info.plist` beside `SUFeedURL`. `.github/workflows/release.yml` runs the whole chain on a `v*`
tag and uploads the DMG and the appcast to the release.

## TestFlight

`scripts/build-ios.sh` is the phone's counterpart to `build-mac.sh`, and it is much the
shorter of the two because Xcode does by hand what that one assembles: signing, packaging
and the upload itself.

```sh
ASC_KEY_ID=<KEYID> ASC_ISSUER_ID=<ISSUER-UUID> VERSION=0.1.0 ./scripts/build-ios.sh
```

Signing is automatic. `apps/ios/Project.swift` carries `DEVELOPMENT_TEAM` and
`CODE_SIGN_STYLE = Automatic`, and given `-allowProvisioningUpdates` plus an App Store
Connect key, `xcodebuild` issues the distribution certificate and the App Store profile on
its own — so there is no `.p12` and no `.mobileprovision` anywhere, in the repo or in CI.
The same key authenticates the upload, which is why the export options say
`destination: upload` rather than writing an `.ipa` for a second tool to send: one
invocation, one credential, nothing on disk to leak. The key may be a path
(`ASC_KEY_PATH`, defaulting to `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`) or
base64 in `ASC_KEY_P8`, which is how CI carries it; that one is written out at mode 600 and
removed on exit.

The build number is `git rev-list --count HEAD`. It has to rise with every upload and never
repeat, and the commit count does both without a file to bump and without differing between
two checkouts of the same commit.

`.github/workflows/testflight.yml` runs the whole thing on a `v*` tag from
`ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8`.

### The app record has to be made by hand, once

Registering the bundle ID is an API call, and `scripts/asc.mjs` — a JWT signer and a `fetch`,
`node:crypto` and nothing else — is enough for it:

```sh
node scripts/asc.mjs POST /v1/bundleIds '{"data":{"type":"bundleIds","attributes":
  {"identifier":"to.yumi.yorozu.ios","name":"Yorozu iOS","platform":"IOS","seedId":"AN5KM8QGEF"}}}'
```

Creating the *app record* is not. `POST /v1/apps` answers
`The resource 'apps' does not allow 'CREATE'`, and `fastlane produce` is no way round it:
with an API key spaceship talks to that same endpoint, so it gets the same refusal. The only
thing that can create one is an Apple ID web session, which means 2FA and a person. So the
first upload for a new app needs one visit to
[App Store Connect](https://appstoreconnect.apple.com/apps) → **+** → **New App**: iOS,
name **Yorozu**, primary language English (U.S.), the bundle ID above, SKU `yorozu-ios`.
Until that exists `xcodebuild -exportArchive` stops before it uploads, with
`IDEDistributionFetchAppRecordStep … missingApp(bundleId: "to.yumi.yorozu.ios")` in its
distribution log. Everything after it — certificate, profile, upload, every later release —
is automatic.

### External testers

Internal testers (the team's own Apple IDs) can install a build the moment it finishes
processing. A public link needs a beta group with external testing on, which is two more
`asc.mjs` calls once the app record exists — `<APP-ID>` is the numeric id from
`node scripts/asc.mjs GET '/v1/apps?filter[bundleId]=to.yumi.yorozu.ios'`:

```sh
node scripts/asc.mjs POST /v1/betaGroups '{"data":{"type":"betaGroups","attributes":
  {"name":"Public","publicLinkEnabled":true,"publicLinkLimitEnabled":false},
  "relationships":{"app":{"data":{"type":"apps","id":"<APP-ID>"}}}}}'
node scripts/asc.mjs GET '/v1/apps/<APP-ID>/betaGroups'   # publicLink is in the response
```

The link only starts working once the build passes Beta App Review, which is a separate
submission from App Review and usually a day or less.
