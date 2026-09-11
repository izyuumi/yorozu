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
