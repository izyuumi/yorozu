# Yorozu

Out-of-box personal AI assistant for macOS, remote-controlled from iOS through a blind end-to-end encrypted relay. Install, grant permissions once, scan one QR, start talking.

- Specs: `docs/spec-v1.html`, `docs/spec-v1.5.md`
- Tickets: `tickets.md`

## Layout

- `apps/mac` — SwiftUI menu bar app, native tool host (SwiftPM executable, macOS 15+).
- `apps/ios` — SwiftUI iOS app (Tuist-generated Xcode project, iOS 18+).
- `apps/relay` — blind websocket relay that forwards ciphertext between Mac and phone.
- `packages/runtime` — encrypted device relay bridge and thin OpenClaw Gateway client. Legacy
  provider-loop modules remain only for explicit injected test/development backends.
- `packages/shared` — protocol event types shared by the TypeScript workspaces.
- `packages/shared-swift` — SwiftUI views shared by the Mac and iOS apps.

## Runtime sidecar

`pnpm --filter @yorozu/runtime serve` (installed as the `yorozu-serve` bin) is what the Mac app
spawns. It loads or creates the Mac's X25519 and Ed25519 keypairs, registers its relay room, mints
a join token, prints the pairing payload, then forwards each sealed message to its own OpenClaw
Gateway session. OpenClaw owns agent execution, providers, tools, permissions, and PAIOS.
Stdout is the protocol the Mac app reads: `STATE <state>` per relay transition and, per pairing
payload, `QR <string>` to draw plus `PAIR <string>` to copy — the same string both times. `MINT`
on its stdin mints the next join token, which is what the Mac's **New code** button sends.

| Variable | Default |
| --- | --- |
| `YOROZU_STATE_DIR` | `~/Library/Application Support/Yorozu` (holds runtime state and derived indexes) |
| `YOROZU_RELAY_URL` | `wss://relay.yumi.to` (the hosted relay) |

On first launch, Yorozu pairs a private Ed25519 client identity with the loopback OpenClaw
Gateway and stores its device token at mode `0600` under `YOROZU_STATE_DIR`. This is client
authentication only; provider credentials never enter Yorozu.

Pairing: the code carries the Mac's X25519 key, the room ID and a one-time token, as one compact
string — `yorozu://pair?v=1&relay=<urlencoded>&key=<base64url>&token=<base64url>&room=<base64url>`.
The QR encodes that same string, so one parser (`decodePairingString` in `packages/shared`,
`QrPayload.decode` in `packages/shared-swift`) serves the scanner, the paste field and the
`yorozu://` link a phone opens when it is tapped in Messages.

The phone joins the room, announces its own X25519 key in one cleartext `hello` frame, and every
frame after that is ChaCha20-Poly1305 sealed under the derived session key. The relay checks the
frame's signature, but the relay could have signed it itself, so the runtime does not take the
relay's word for who is enrolling: the pairing string carries a `secret` the Mac minted and the
relay never sees, and a `hello` for keys not already on file is accepted only with `proof`, a
hash over that secret and both announced keys (`helloProof`, byte-identical in both languages).
The Mac honours the last four secrets it drew and spends them all on a pairing. A `keys.json`
that exists but will not read stops the sidecar instead of minting a new identity, since new keys
would silently unpair every phone; only an absent file is a first run.

## Mac app

```sh
pnpm --filter @yorozu/runtime build            # sidecar must be built first
swift run --package-path apps/mac              # dials wss://relay.yumi.to by default
```

The menu bar window shows the relay state, the pairing QR, the same code as selectable monospace
text with a **Copy** button, and **New code** to mint a fresh token. The sidecar command is
`YOROZU_RUNTIME_CMD`, run through `/bin/sh -c`, defaulting to
`node ../../packages/runtime/dist/serve.js` (relative to `apps/mac`, i.e. the dev checkout layout);
the shipped app will point it at the bundled runtime. The sidecar is killed when the app quits.

## Legacy injected backend

The sections below document modules retained for tests and explicit callers that pass
`ServeOptions.provider`. Shipped Yorozu does not activate them. OpenClaw owns memory, provider
credentials, model availability, skills, scheduling, approval policy, and browser/tool settings.
The legacy loop lives in `packages/runtime/src/legacy.ts` and loads only for an explicit
`ServeOptions.provider` or `--direct-provider`. Ordinary launches do not install its agent files
or start its scheduler. Legacy modules remain supported for injected tests/development callers.

### Legacy memory

PAIOS Markdown is memory's source of truth. Yorozu recursively indexes `YOROZU_PAIOS_DIR`, using an
existing PAIOS folder from Obsidian or creating `~/Documents/PAIOS` by default. New facts go to
`Workspace/Yorozu Memory`, visible in Finder and editable in any text editor. Frontmatter carries
`kind` (`preference`, `decision`, `correction`, `fact`, `approval`), `created`, `threadId` and
`agentId`. `YOROZU_MEMORY_DIR` remains available as a legacy storage override.

The SQLite FTS5 index stays in `YOROZU_STATE_DIR`; it is derived and rebuilt from the files
whenever it is missing or their mtimes have moved. The agent writes facts with the `remember`
tool; `recallForPrompt` returns a compact block that `runAgent` prepends to the system prompt
when given a `memory`. Vector recall is not implemented yet: `searchByEmbedding` returns nothing
until sqlite-vec or provider embeddings land.

### Legacy providers

Three adapters, as in the spec: Claude, Codex, OpenAI-compatible. Any one signed in is enough.
Which of them are configured, in what order, and with which models is a list the user owns —
`<state dir>/providers.json` — not three cards the code knows about:

```json
[{ "id": "claude", "kind": "claude-cli", "label": "Claude", "models": ["claude-opus-5"], "enabled": true },
 { "id": "work", "kind": "openai-compat", "label": "Work", "baseUrl": "https://…/v1", "keyRef": "work", "models": ["gpt-5.6"], "enabled": true }]
```

Order is chain order, each entry's models are tried in order, and every spec is
`<id>/<model>` — in the chain, in an agent's `model:` frontmatter, and in the catalog. No secret
is ever in that file: `keyRef` names a Keychain item, and the Mac app hands the sidecar the key
as `YOROZU_KEY_<KEYREF>` (the old single `YOROZU_API_KEY` still works as a fallback).

| Adapter | Spec prefix | How it authenticates |
| --- | --- | --- |
| `claudeCli` | `claude-cli/<model>` | the installed `claude` binary and its subscription login (`claude auth status --json`) |
| `codexCli` | `codex-cli/<model>` | the installed `codex` binary and its subscription login (`codex login status`) |
| `openaiCompat` | `openai/<model>` | `YOROZU_BASE_URL` + `YOROZU_API_KEY` |

Both CLI adapters use the vendor SDK for auth and streaming only — the runtime keeps its own
loop. The Claude adapter hands our `ToolDef`s to the SDK as an in-process MCP server and then
*denies* every call from `canUseTool`: the attempted call is the `tool_call` event the loop
wants, and the loop, not the CLI, runs the tool. (A tool named in `allowedTools` would be
auto-approved and executed in-process, which is why none are listed.) Codex takes tools only
from an MCP server, so the same `ToolDef`s go in as a local stdio bridge (`yorozu-mcp`,
`mcp-bridge.ts`) that executes nothing: it forwards each `tools/call` over a Unix socket to the
adapter, which emits it as a `tool_call` event and leaves the Codex turn waiting until the loop
comes back with the result. Same catalog, same approval gate, no Codex-specific permissions.

`YOROZU_MODEL_CHAIN` overrides the file. It is a comma list, primary first, and accepts both
entry ids and the three built-in kind names, so a chain written before `providers.json` existed
still resolves:

```sh
YOROZU_MODEL_CHAIN=claude-cli/claude-sonnet-5,codex-cli/gpt-5.6,openai/gpt-4o-mini
```

The first provider to emit an event wins. Anything that fails *before* its first event — auth,
HTTP 401/403/429, transport — advances to the next one; after the first event the turn is
half-spoken, so failures propagate rather than replay.

With neither the variable nor a `providers.json`, the runtime probes instead of guessing: the
providers that answer become the chain, preferring the subscription CLIs over a paid key, and
`providers.json` is seeded from that first probe. With none of them usable it says so once —
`STATE no-provider`, which the Mac app draws as *No provider signed in* — rather than failing
every turn with `auth failed: /models 401`.

`node dist/serve.js probe` prints one JSON line (`{"claude":{"ok":true},…,"providers":[…],"status":{…}}`)
with each provider's state and never prints a secret; `node dist/serve.js models <id>` prints what
one `openai-compat` entry's `/models` publishes. Settings → **Providers** is that list: add and
remove entries, drag to reorder, edit each one's models (fetched from `/models` for an endpoint,
a curated default for the CLIs), pick the default model — which is just the head of the chain —
and log in to the two CLIs through Terminal.app, since both logins are interactive browser round
trips.

Note that `@openai/codex-sdk` depends on `@openai/codex`, which vendors a ~277 MB platform
binary; the SDK is pointed at the user's own `codex` on PATH when there is one.

## Relay

The relay forwards ciphertext between Mac and phone and can read none of it. Rooms are keyed by
`base64url(sha256(macPublicKey))`. The Mac registers by signing a server-issued nonce with its
Ed25519 key, then mints one-time join tokens (10 minute TTL) that the phone redeems with a
signature over the token. Every frame carries a signature from the sender's registered key;
unsigned or mis-signed frames close the connection. While the Mac is offline, phone frames are
buffered per room (24h TTL, 5 MB cap, oldest dropped first) and replayed in order on reconnect,
each tagged with a `seq` the Mac acks (`{"type":"ack","seq"}`) once handled; an unacked frame is
replayed to the next registration rather than lost. Mac frames are never buffered: the phone
treats the socket as a fast path only, and on every join asks the Mac for the thread list, a
sync, the devices and the rules, so nothing depends on the socket having been up. Each socket is
rate limited to 60 frames per second, so a flooding phone closes only itself; the Mac's fan-out to
every paired phone travels as one `frames` batch and costs one token. Expired join tokens are
swept rather than kept until redeemed, and a push to APNs is given five seconds and runs off the
room's message chain, so a slow Apple delays no frame. Both relays log one JSON line per socket event
(`registered`, `joined`, `close`, `drop`, `drain`, `buffer-trim`, `apns`) with no payloads or keys.

Clients pass the room as `?room=<roomId>` on the websocket URL. The room only appears on the wire
inside `register`/`join`, which is too late for a relay that must route the socket before reading
it; both clients know the ID before they dial. The Node relay ignores the query.

There are two implementations of that one protocol, sharing its pure policy (limits, close codes,
envelope shapes, rate limit, buffer trim) in `apps/relay/src/protocol.ts`:

- **Hosted** — `src/worker.ts`, a Cloudflare Worker with one Durable Object per room, which is what
  `wss://relay.yumi.to` runs. Sockets use the Hibernation API, tokens and the offline buffer live in
  DO storage, and the buffer's TTL is swept by a DO alarm.
- **Self-hosted** — `src/index.ts`, a plain `ws` server with everything in memory (`PORT`, default
  8787).

```sh
docker build -t yorozu-relay -f apps/relay/Dockerfile . && docker run -p 8787:8787 yorozu-relay
```

To run the hosted one on your own Cloudflare account, edit the `routes` block in
`apps/relay/wrangler.toml` to your own hostname and deploy:

```sh
pnpm --filter @yorozu/relay exec wrangler deploy
```

### Notifications

APNs alerts every registered phone. What that costs in privacy is the point of the design, so it is
worth being exact about it. A server-open socket is not proof the iOS app is visible: suspended apps
can leave one behind. The app suppresses presentation while foregrounded instead.

Beside every sealed frame the Mac sends the relay one `notify`: a cleartext class — `reply`,
`approval`, `done` or `failed` — and an opaque `threadRef`. A reply also includes one ChaChaPoly
preview box per paired phone, addressed by the Ed25519 key the relay already knows; each is sealed
under that phone's existing session key. The reference is the first eight
characters of `base64url(sha256(threadId))`, and a thread id is a random UUID, so it is a handle the
relay can match and cannot invert. Phones register their APNs token the same way (`push`), filed
against the Ed25519 key the relay already knows each device by — so `revoke` drops the token with
the device, and a revoked phone stops being woken.

So the relay learns: that a device exists and how to wake it, that something of one of four classes
happened, which opaque reference it happened under, ciphertext length, and roughly when. It never sees message text,
tool names or arguments, approval details, rule scopes, summaries or thread titles — those travel
sealed, in the frame beside the notify, under a key the relay does not hold. APNs receives a fixed
fallback body plus that opaque box. The iOS Notification Service Extension opens a valid reply box
locally and replaces the fallback; missing keys, malformed boxes and failed authentication leave
the fallback unchanged. Tapping routes on the reference, which the phone resolves against the
thread ids it already holds — the one end that can.

An approval can be answered from the notification. The Mac marks a `notify` with `actions: true`
when the action is quick-approvable — below every floor and not an external commitment (no
message, purchase, booking or transfer) — and the relay sets the notification category to
`approval-quick`, which the app registers with **Allow** and **Don't allow** buttons; anything
else gets `approval-review`, whose only button opens the card. A button answer launches the app
in the background, which dials the relay, finds the card the push's opaque `event` reference
names (from its cache, or from the sync connecting asks for), sends the same `approval_answer`
the card would — tagged `source: "notification"` — and hangs up. Approvals are also a
background-wake class now, so the card is usually already cached by the time a button is pressed.
The runtime honours a notification-sourced answer only for a card it judged quick-approvable
itself: the relay chooses which buttons a push draws, and a relay that put **Allow** under a
purchase card gets `notification-answer-refused` rather than a purchase. The relay also learns a
reply's length to within the 256-byte preview cap, and how often events land in each thread.

A phone holding a live socket still receives the alert because iOS may have suspended it; a visible
app suppresses that alert locally. Nor is the running commentary — deltas, tool traffic, a delegated agent finishing — ever notified at all, so a
turn's every tool call does not become a push: only a turn arriving somewhere a person has to be
told about is worth a wake-up.

The hosted relay needs an Apple auth key for this, as three Wrangler secrets — `APNS_KEY_ID`,
`APNS_TEAM_ID` and `APNS_KEY_P8` (the .p8 itself). Without them the relay forwards frames exactly as
before and wakes nobody, which is what the self-hosted `src/index.ts` does always: it accepts the
same messages and holds no key.

## Permissions and never-sleep

`apps/mac/Sources/YorozuMac/Permissions.swift` holds every grant check as a plain function, and
`Onboarding.swift` walks them one page at a time: Accessibility, Screen Recording, Full Disk
Access, Automation, Input Monitoring, Start at Login, Never Sleep. Each page deep-links to its System Settings
pane, re-checks every two seconds, and only unlocks Continue once the check is green or the step
is explicitly skipped. The wizard opens on first launch (`onboardingCompleted` in `UserDefaults`)
and again from **Run Setup Wizard…** in Settings → **Permissions**, which is the same checks as a
live list: each row polls its own grant and deep-links to the same pane.

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

## Staying alive

A Mac that answers a phone has to be running Yorozu at all times, and on one morning it was
not: no crash report, no log line, no login item to bring it back, and three releases it had
never picked up. `apps/mac/Sources/YorozuKeepalive/Keepalive.swift` is the answer to each of
those, and everything below writes to one file — `~/Library/Logs/Yorozu/app.log` — so `tail`
over ssh is the whole diagnosis.

| Failure | What brings it back |
| --- | --- |
| The Mac restarted | the login item, `SMAppService.mainApp` |
| Yorozu died | the watchdog LaunchAgent, within a minute |
| The Node sidecar died | the app respawns it, backing off 1s → 60s |
| An update was downloaded and never installed | Sparkle installs and relaunches while no chat window is open |

**Start at login** is `SMAppService.mainApp`: no helper and no plist of ours, and the user can
see and revoke it in System Settings › General › Login Items. It is registered by the wizard's
own step (on by default) and toggled in Settings → **General**, which shows `SMAppService`'s
status rather than a preference of ours — macOS owns this one, and a second copy of the answer
would be a copy that could be wrong.

**Keep Yorozu running** is a user LaunchAgent, `to.yumi.yorozu.watchdog`, written to
`~/Library/LaunchAgents` on every launch and bootstrapped into `gui/$UID`. Every 60 seconds it
runs `Contents/Resources/watchdog.sh`, which is four lines: if no process is running out of the
app's `Contents/MacOS`, `open -a` the bundle and say so in the log. It is deliberately outside
the app — the failure it exists for is the app being gone, so nothing inside the app can be
what notices — and `StartInterval` rather than launchd's `KeepAlive`, which would own the app's
process and fight `open`, Dock activation and Sparkle's relaunch.

Every path in the agent comes from the running bundle, never `/Applications`, so a test build
under its own `BUNDLE_ID` supervises itself under its own label and cannot touch the real one:

```sh
BUNDLE_ID=to.yumi.yorozu.t46test ./scripts/build-mac.sh
```

**Quitting still quits.** ⌘Q unloads the watchdog; a crash gets nowhere near that code, so the
watchdog remains loaded and relaunches the app. The next manual or login-item launch installs
the watchdog again. Sparkle's update relaunch does not unload it: if installation fails, the
watchdog is exactly who should notice.

The agent and watchdog script are unit-tested —
`env -u SDKROOT swift test --package-path apps/mac`.

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

An unpaired phone opens on a splash — icon, name, tagline, **Get started** — and its pair screen
offers the two ways in: **Scan QR**, or the code pasted into a text field. A tapped `yorozu://`
link pairs without either, through `onOpenURL`. However the code arrived, it is stored together
with a freshly generated device identity — Ed25519 for relay frame signatures, X25519 for the
session key — in the Keychain, then opens the one `Home` thread. `RelayClient` in `packages/shared-swift` is the phone
half of the relay protocol (join, cleartext `hello`, sealed events); it owns no UI state, so the
Mac app can reuse it for local chat later.

Replies stream: the sidecar re-sends one message event per delta under a stable event id, each
carrying the whole text so far, and the phone replaces that message in place rather than appending.
The relay answers `joined` with `ownerOnline` and pushes `{"type":"owner","online":…}` whenever a
room's Mac connects or drops; that drives the "Mac offline" banner. Presence is routing state the
relay already keeps to decide whether to forward or buffer, so it stays blind to the ciphertext.

Join tokens are one-time, so re-pairing needs a fresh code once the phone's socket has closed. Token
refresh belongs with the Threads ticket, which gives each device a lasting identity.

### End-to-end proof

`apps/ios/e2e/run.sh` is a test helper, not product code. It starts the relay, a fake
OpenAI-compatible provider (`e2e/fake-provider.mjs`, pointed at by `YOROZU_BASE_URL`) and the
runtime sidecar, creates a throwaway iPhone simulator, builds and installs the app, injects the
sidecar's `PAIR` string with `-yorozuPair '<string>'` (the simulator has no camera) plus
`-yorozuSend hi`, and asserts the streamed reply reaches the phone. The simulator is shut down and deleted on exit.

Unlike the CI compile check above, that build keeps code signing on: ad-hoc simulator signing is
what gives the app its `application-identifier` entitlement, and without one every Keychain write
fails with `-34018` (`errSecMissingEntitlement`), so pairing never persists. It needs no developer
account.

## Threads

A thread is an append-only log: `<YOROZU_STATE_DIR>/threads/<id>.jsonl`, one event per line,
with `threads.json` beside it as the index, including native-agent working directories and
session IDs. Threads are created on demand. A legacy `home` with history becomes an ordinary,
archivable thread; an empty one is removed during migration. An absent index is a first run.
An unreadable, malformed or structurally invalid index stops the operation and stays untouched:
restore it from backup or repair the original file before restarting. Logs alone cannot recover
native session metadata safely. Only conversation events are
logged (`message`, `thought`, `tool_call`, `tool_result`, `approval_card`, `approval_answer`,
`question_card`, `question_answer`, `progress_card`);
sync and thread admin are control traffic and leave no trace.

Every turn runs in its own thread and is given that thread's history as context: the system
prompt, then a rolling summary of whatever has scrolled out, then the last 40 messages
(`contextFor` in `src/summary.ts`). A turn nobody typed — a due job, a background delegation —
is recorded as the user message it stands in for, so the thread reads back whole.

### Rolling summary

Once a thread outgrows the 40-message window, what falls off the front is summarised rather than
dropped: `<state dir>/threads/<id>.summary.md`, a few hundred words in front of the window as
`Earlier in this thread: …`. It is regenerated incrementally — one cheap completion folds the
newly evicted messages into the summary already on disk, and a marker on the file's first line
records how many messages it accounts for — so the cost is per eviction, not per turn. It runs
after the reply has been sent and is never awaited, so it cannot delay an answer, and a provider
that fails leaves the summary that was there for the next turn to try again. The file is derived:
delete it and the next eviction rebuilds it from the log.

### One thread, one model

A thread can be put on a model of its own: `thread_set_model` carries a `<id>/<model>` spec (or
null, for the default), the sidecar keeps it in `threads.json` and hands it back on every
`ThreadSummary`, and that thread's turns run on a chain with that spec in front and the
configured chain behind it — so one unreachable provider is a slower turn rather than a thread
that cannot answer. The models on offer travel to the phones as `model_list`, pushed alongside
`thread_list` so the picker in the chat's "…" menu has real names the moment it is opened. A
thread not on the default says which model under its title; a thread on the default says nothing.

The phone drives it with the events the protocol already has: `thread_create` (optional title),
`thread_rename`, `thread_archive` (the thread is the event's own `threadId`), and `thread_list`,
which the sidecar also sends unprompted the moment a device pairs.

Nobody is asked to name a thread. `+` creates one with an empty title, the lists draw it as
"New chat", and after the first completed reply the sidecar spends one small extra completion on
the same provider — "reply with a 3-5 word title", shown the opening exchange truncated to 500
characters — then writes the answer into `threads.json` and broadcasts a fresh `thread_list`. It
is never awaited and gives up after 5s, so a slow or broken titler costs the reply nothing and
leaves the thread untitled. Only an empty title is filled in, which is also the whole of the rule
that a title the user typed with Rename is never overwritten. `sync_request` carries `lastSeen`, a replay
cursor per thread, and is answered with one `sync_delta` holding everything after those cursors
across *every* live thread — capped at 200 events each. Replayed events include an opaque
`syncCursor` identifying their exact log occurrence, so updates that reuse a progress card's ID
cannot skip intervening history. Older clients and runtimes can still exchange event IDs.
Phones advance their cursor only from replayed events and save it with the encrypted history;
live replies and unsent messages cannot move it past unseen pages. An invalid cursor replays from
the start. Sync builds an in-memory byte-offset index on the first read of a
log, then seeks directly to each page without re-parsing prior messages. File changes invalidate
the index. Metadata for 16 recently synced logs is retained; message bodies are not cached.
`pnpm --filter @yorozu/runtime build && node scripts/benchmark-sync.mjs` compares a full drain
against the previous full-log scan using a temporary 10,000-event fixture.

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

Those devices outlive a restart in `<state dir>/devices.json`, one record per device: the X25519
key the session is agreed from, the Ed25519 key the relay knows it by (announced alongside it in
`hello`), and when it was last heard from. The Mac app lists them over the local socket —
`device_list`, pushed whenever a device comes or goes and askable at any time — with "online"
meaning *said something in the last 90 seconds*, which is the only honest answer the runtime has:
the relay tells phones whether the Mac is up, never the other way round. `device_remove` forgets
one: dropped from `devices.json`, and a `revoke` message to the relay, which forgets the device
and closes its socket, so it cannot rejoin against the nonce either. Both relays implement it.

### Phone-side cache

`ThreadCache` in `packages/shared-swift` keeps the thread list and one file per thread under
`Application Support/threads`, each sealed with AES-GCM (CryptoKit) under a 32-byte key the app
stores in the Keychain (`CacheStore`, next to the pairing in `Keychain`). Application Support is
readable by anything that reaches the container, so the encryption — not the location — is what
protects it. A cache is only a cache: a missing, tampered or wrong-key file reads back empty, and
the `sync_request` the app sends on connect refills it. Unpairing deletes the files and the key.

That is what makes the app work offline: the list and every thread are read from disk at launch,
before the relay is even reachable.

### Outbox

Every message and archive request goes through the outbox (`Outbox` in
`packages/shared-swift`), link or no link, and leaves it only when the runtime's `receipt` names
its id: a socket that accepted a send is not a runtime that received it, and iOS can leave a
socket half-open with the Mac long gone. With the Mac asleep, or before the relay has paired the
socket, the bubble is captioned **Queued**; on a live link there is no caption, since nothing is
known to be wrong yet. The queue is flushed in order whenever `paired` and `ownerOnline` are both
true, and a flush re-sends everything still unreceipted. The events keep the ids they were given,
so a copy that did land is dropped by the runtime rather than applied twice — it keeps a window of
the last two thousand command ids for exactly this, and the thread log for messages — and a
thread started offline carries its `thread_create` ahead of the message that created it. Three
refusals and the caption becomes **Not sent — tap to retry**; the queue steps over it and carries on.
It holds 50 messages and stops re-sending one by itself after 48 hours. It is sealed in the same
`ThreadCache`, so a phone closed on the underground still has it in the morning.

### Thread list, export and link previews

The phone's list is **Pinned**, then a section per stretch of time — Today, Yesterday, This week,
Earlier — with the archive folded away at the bottom (`threadSections`, pure and table-tested).
A thread's context menu and the chat's **…** both offer **Export as Markdown**: `threadMarkdown`
renders the transcript with roles and timestamps and folds tool runs and delegations into
`<details>` notes, and `ShareLink` writes it out as a real `.md`. The first bare URL in a reply —
not one already inside a Markdown link or a code span — gets a compact preview row under the
bubble, fetched on device by `LPMetadataProvider` with a 5 second timeout and cached in memory and
under `Caches/Yorozu/link-previews`, keyed by the SHA-256 of the URL so a directory listing is not
a reading list. Nothing about it blocks the thread: the row appears if and when the metadata lands,
and a site that never answers leaves no gap.

### Share sheet

`YorozuShare` puts Yorozu in the share sheet for selected text, a web link or one picture
(`NSExtensionActivationRule`, so it stays out of the sheets it has nothing to offer). The composer
shows what was shared as itself — a link as a link, a selection as a quotation, a photo as a
thumbnail — takes an optional note, and offers the five most recent threads plus **New session**,
with New session selected: a link is rarely meant for whatever was last talked about.

The extension never touches the relay. It writes a `SharePayload` into the App Group container
(`group.to.yumi.yorozu`) and opens `yorozu://share?token=…`; the app, which owns the socket and the
outbox, is what sends it. That keeps the pairing's private keys out of a second process and the
room down to one device per phone — and because the payload is already on disk, an `open` that iOS
declines to deliver costs nothing: the app drains the container on every foreground, so the share
goes out the next time Yorozu is opened. The token is a file name, checked to be a UUID before it
is joined onto a path, and a share is removed as it is read so it is never sent twice.

The picker's titles are the one thing that has to cross over: the extension cannot read the
encrypted `ThreadCache`, having no Keychain access group on purpose, so the app writes the five
ids and titles into the container and nothing else. Unpairing empties it along with the cache.

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

The six bundled agents (`main`, `general`, `calendar`, `email`, `browser`, `reservation`) live in
`packages/runtime/agents/` and are copied into the state directory on first run; a file you
edited is never written over, and one you delete comes back on the next start.

The main agent stays user-facing and delegates execution by default: to the closest fixed
specialist, or to `general` when none fits. Independent slices can start together, with one
shared four-worker ceiling across foreground and background turns. Its one handle on workers is
`delegate(agent, task, background?)`; each worker gets its own message list seeded with `task`
and returns its final text. Depth is hard-capped at 2 — a worker's tool list never contains
`delegate`, so one needing another specialist says what it needs and the main agent re-delegates.
With `background: true` the call returns a `delegation <id> started` line immediately and the result
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
every call and never sees a result, and the Codex bridge returns them as MCP text content — so
an image-bearing tool result would be plumbing with nothing on the other end.

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
| `chatRows(from:)` | the thread in order: bubbles, grouped tool activity, and each card where it was raised |
| `mainTrace(from:)` | the main agent's own thoughts, tool calls and results |
| `toolActivities(from:)` | each `tool_call` paired with the `tool_result` that answered it |
| `traceEntries(from:)` | a trace page in order, with unbroken runs of tool use grouped |
| `unifiedDiff(in:)` | a tool's output read as a diff, or nil when it is not one |

Cards are grouped by agent *and* delegation, not by agent alone: a card closes on its `done`
message, so the same specialist called twice is two cards. An event counts as delegated when it
carries a `parentAgentId`, which is what the runtime tags with and which can never catch the
phone's own events.

`TraceViews.swift` holds `DelegationCardView` (the inline card) and `AgentTraceView` (the page
it pushes). Navigation is by value — `.agentTraceDestination { model.events }` on the stack
resolves a `TraceTarget` against the *live* event list, so an open trace keeps streaming rather
than showing the snapshot the link was built from.

Everything the main agent does between one message and the next is one row in the thread:
`WorkRowView`, over a `TurnWork`. While the turn runs it is a single live line — a spinner and
what is happening right now: the newest thought, the running tool, the delegated agent, or a
progress card's title and percentage — that replaces itself as the work moves on. When the turn
is over it collapses to `N steps · 2m` (and `n failed`), and opens to the whole trace in order:
thoughts, `ToolGroupView` runs (a row per call with the tool's family symbol, a one-line
argument summary, how it went and how long it took, opening to the arguments in full and
whatever the tool printed), delegation cards, and progress cards. Approval, question and rule
proposal cards close the work row and stand below it: they need a person, so they are never
folded away. `chatRows(from:generating:)` marks the last work row live only while the thread is
generating; the events alone cannot tell paused from finished. A result that is a unified diff is drawn as one, coloured, with
its `+n −m` counts on the collapsed row; `unifiedDiff(in:)` decides that on the hunk header,
because a `+` at the start of a line is ordinary enough in ordinary output. Long output is cut
to twelve lines behind **Show all**, which is also the only thing that makes a scroll view
inside the thread, capped so one `cat` cannot become the whole screen. A specialist's tool use
stays behind its delegation card: showing it twice would be showing it twice.

The e2e harness proves the wire path: `e2e/fake-provider.mjs` calls `echo` on its first turn,
and `run.sh` waits for the phone to log `YOROZU-E2E-TOOL echo` beside the streamed reply.

## Approvals

Every tool with an effect outside the runtime declares an `actionClass` — the spec's list:
`send-message`, `purchase`, `delete-file`, `book`, `transfer-money`, `run-command`,
`edit-file`, `interact-web`, `interact-app`, `edit-calendar`, `edit-reminder`, `visit-url`.
Browser click/type/eval and the Calendar/Reminders mutations use their distinct classes so an
older broad shell/file rule cannot authorize them. `fetch` and `browser.open` carry `visit-url`:
the one class allowed by default, because a GET is a read until the server decides otherwise —
a `never` rule fences a host, and a URL that looks like it acts on arrival (a token or code in
the query; a confirm/verify/unsubscribe/activate/reset/magic/login/auth path) is confirmed fresh
past any rule and past YOLO. Snapshot, search and the other read-only siblings stay ungated.

Alongside it each tool carries an extractor that turns the call's arguments into the
**structured scope** of the action: the `target` and whichever of `operation`, `recipient`,
`account`, `merchant`, `category`, `quantity`, `amount`, `contentSummary` and `consequence` it
can honestly fill in. That is what the card shows and what a rule matches on, so a tool that
fills in more is a tool the user can write a narrower rule about. The scope describes the
payload being committed rather than the tool doing the committing — `consequence` is one line
the tool declares about what happens afterwards, and `contentSummary` is the first 200
characters of what would be sent.

A tool may also declare a **batch**: `batch(args)` returns the exact items one decision covers,
and the card lists them. The runtime keeps a hash of that list, so an item added or changed
afterwards is not covered by the answer.

The gate sits in the agent loop, before the tool runs, and returns one of three verdicts:

1. **The floor**, partly set during onboarding and kept in `<state dir>/approval.json`: any
   action at or above `moneyThreshold`, any `delete-file` outside the state directory when
   `confirmIrreversibleDeletes` is on, and — whatever is stored — every subscription, transfer,
   securities trade and anything in the `crypto` category. The floor always asks. No rule and no
   grant can reach it, which is the whole point of having one: "stop asking me" can never end up
   spending money, moving it, or deleting files on its own.
2. **The rules**, in the same file. A rule is global — it matches on the structured scope and
   never on which agent is acting, so delegating work does not change what is authorized. Each
   field it constrains carries a pattern (`exact`, `prefix` or `glob`, matched
   case-insensitively) and it may carry a `maxAmount` cap; a field it leaves out is not checked
   at all. The most specific matching rules decide, and **among those a `never` beats an
   `always`**: a broad deny is overridden by a narrower allow, since the narrower rule is the
   more deliberate one, but a deny as specific as the allow wins the tie (`decide` in
   `approval.ts`, test 24). A rule can be switched off (`enabled: false`) without being
   lost, and the runtime keeps `lastUsed` and `useCount` on it so Settings can show what it is
   actually doing.
3. **Ask.** Nothing is inferred from history here. Repeated approvals produce a *proposal*, never
   an automatic allow.

Every decision lands in `<state dir>/approvals.jsonl`, one append-only row carrying the scope it
was judged against, who was acting, and — on an automatic allow — the `ruleId` that authorized
it. That last field is the audit trail: it is how the user finds out which rule is doing
something and what to revoke to stop it.

Asking means the sidecar emits an `approval_card` to every paired device and parks that tool
call until an `approval_answer` carrying the `actionId` comes back. Unanswered after ten minutes
it resolves as a refusal rather than hanging the turn, and an interrupt settles any card still
on screen. **A pending card parks the whole turn**: tool calls run one after another in the
order the model asked, so nothing lands while a card is being read. (Until 2026-09-18 the loop
started every call together and only the gated one waited; with approvals answerable from the
lock screen the wait is seconds, and a paused world is the easier one to trust.)

There are three ways to say yes:

- **Allow once** (`yes`) covers this one action.
- **Allow for this task** (`task`) covers the same class and scope for the rest of this turn and
  everything it delegates to, then expires — the grants live in a `TaskGrants` object created per
  turn and passed down the tree, so nothing outlives the turn because nothing stores it.
- **Always allow** opens a rule editor prefilled with the narrowest rule that covers the action
  (`send-message` to *this recipient*, `purchase` at *this merchant* up to *half again* the
  price). The user can widen any field to "Any" before saving, and the saved rule travels back on
  the answer. It persists until revoked. The editor refuses to save a rule that pins nothing
  down: blanket authorization across an action class is not offered. A batch card offers no rule
  at all, because no standing rule can mean "exactly these items".

**Don't allow** refuses this one action only. **Discuss** decides nothing: it logs nothing, hands
the agent a note asking it to explain itself, and the card comes back with a fresh `actionId`
when the agent tries again. A typed `yes`, `no`, `for this task`, or `always` / `never ask
again` / `don't ask again` in the thread answers the card the buttons would have; a bare `never`
is the one-off refusal it sounds like.

After `PRECEDENT` (three) matching approvals inside 30 days, and only while no stored rule
covers them already, the runtime emits a `rule_proposal` — "Yorozu noticed you always allow
this. Make it a rule?", with **Review** (which opens the editor) and **Not now**. It activates
nothing by itself: the proposal is a card, and only the editor's Save writes anything.

A tool that commits money or messages calls `verifyApproved(actionId, finalScope)` immediately
before committing, with the values it is actually about to use. Any change to price, quantity,
recipient, account or batch membership between the card and that moment invalidates the
approval, and the tool hands the model a note telling it to present the action again with the
final values. The `actionId` reaches the tool on its `TurnContext`, set for the duration of that
one approved call.

`ApprovalCardView`, `RuleEditorView`, `RuleProposalCardView` and `RuleRowView` live in
`packages/shared-swift`, so both platforms draw the same card, the same editor and the same
rule rows. The Mac's Settings gains a **Rules** tab — list, enable/disable, edit, revoke, with
each row's last use and count — which read-modify-writes `approval.json` directly, because the
Mac and the runtime share a disk and the runtime re-reads that file on every decision. The
phone's Settings gains a **Rules** row over the wire instead: `rule_list` asks for them,
`rule_update` saves one and `rule_delete` revokes one, and any change is broadcast as a fresh
`rule_list`. Four new event kinds — `rule_proposal`, `rule_list`, `rule_update`, `rule_delete` —
are mirrored in both `events.ts` and `Events.swift`; `approval_card` and `approval_answer` grew
optional fields, so a runtime or a phone from before v1.5 still decodes them.

## Questions and progress

Two things the agent could only do in prose before, and now does with a card. Both tools are
built per turn in `serve.ts`, the way `delegate` is, rather than living in `defaultTools`: they
draw on the paired devices, so they only exist where there is somebody to draw for.

`ask_user(question, options[], allowOther?)` emits a `question_card` and parks the call until a
`question_answer` carrying that `questionId` comes back — the answer text *is* the tool's
result, so the turn carries on with what the user chose. Unanswered after ten minutes it
resolves as `no answer` rather than hanging the turn, and an interrupt settles every question
still on screen. The waiting lives in `questionDesk` in `tools/cards.ts`, apart from the socket,
so its expiry is testable without a sidecar and without waiting ten minutes. `main.md` tells the
agent to reach for it whenever a choice is the user's to make.

`report_progress(cardId, title, steps[], percent?)` emits a `progress_card`: a title, a thin bar
and a step list, each step `pending`, `running`, `done` or `failed`. Calling it again with the
same `cardId` moves that card rather than stacking another under it — the runtime re-emits it
under the card id *as the event id*, and every client already upserts events by id, so
update-in-place needed no protocol of its own. Every field is model output and is normalised
before anyone draws it: a state this build has never heard of is a step not started yet, and a
percent out of range is clamped. A background `delegate` raises one automatically — title the
task, running until it is done or failed — because nobody is watching a background job finish.

`QuestionCardView` and `ProgressCardView` sit in `packages/shared-swift` beside
`ApprovalCardView` and are shaped like it, so the three read as one family. A card raised
inside a delegation is never folded away behind that delegation's card: the agent is parked on
it, and nothing happens until it is answered.

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
Everything that is not chat moved into a standard `Settings` scene, reachable with ⌘, or from the
gear at the foot of the sidebar, which also holds quit and the sidecar's relay state. Current
tabs are **General**, **Devices**, and **Permissions**. Provider, model, tool, approval, browser,
schedule, and PAIOS controls belong to OpenClaw. The model is built and connected from
`applicationDidFinishLaunching`
rather than from the window, because a menu bar window only exists while it is open and replies
and approval cards have to keep arriving either way.

One reply is one frame. A reply used to reach the socket twice — once as the text delta and
again as the finished message, identical but for `done` — because a model that answers in a
single chunk yields one `text` event and then a `final` with the same words in it. Streaming now
runs one delta behind: a delta broadcasts the reply *so far*, and the finished frame, which is
sent whatever happens because it is the one carrying `done`, stands in for the last of them. A
reply that streamed is still a frame per delta; a reply that did not is one frame.

Tests: `local.test.ts` round-trips a turn over the socket, checks that one turn puts one agent
message on it, that `ask_user` and `report_progress` reach it and come back, that a broadcast
arrives, that the mode is `0600`, and that the socket is gone once the sidecar closes; `ChatModelTests`
drives the model over a fake transport, which is the protocol's whole point. One thing the tests
pinned down: the model sends each event in a task of its own, so the order they reach the
transport in is not fixed — every event carries its own ids and the runtime matches on those.

## Install

The fresh-Mac walkthrough, in the order spec section 10 asks for:

1. Download the newest DMG from https://yorozu.yumi.to/mac.
2. Open it and drag **Yorozu** onto the Applications shortcut beside it. Eject the disk image
   and launch Yorozu from Applications — it is a menu bar app, so it appears as an icon in the
   status bar rather than a window in the Dock.
3. The permission wizard opens on first launch and walks one grant per page: Accessibility,
   Screen Recording, Full Disk Access, Automation, Input Monitoring. Each page deep-links to
   its System Settings pane and re-checks every two seconds, so Continue unlocks on its own
   once the grant is green. Any step can be skipped and redone later from
   **Set Up Permissions…**.
4. Ensure OpenClaw is running and configured. Yorozu connects to its loopback Gateway; provider
   credentials, models, tools, permissions, browser, schedules, and PAIOS stay in OpenClaw.
5. Consent to never-sleep if you want the Mac reachable while it is idle. It is a `caffeinate`
   process the app owns, and it dies with the app.
6. Settings → **Devices** → **Pair Another Device…** shows a pairing code. Open the Yorozu iOS
   app and scan the QR, or press **Copy** and paste the string into the app — or message it to yourself and tap it. Done.
   The menu bar window itself is the chat; ⌘, or the gear at the foot of the sidebar is the way
   to everything else.

Updates are Sparkle, and they happen on their own: the app checks the appcast hourly,
downloads a newer build in the background, and installs it — no dialog, no download, no drag —
the next time it is not the frontmost app, relaunching itself when it is done. The sidecar
comes back on the same `~/Library/Application Support/Yorozu`, so the room, the keys and every
paired phone are exactly where they were. Settings → **General** has the toggle (on) and a
**Check for Updates…** button for the impatient.

### The relay

The Mac and the phone only ever meet through a relay, so one has to be reachable from both. The
app's Settings → **Relay** field is the URL the sidecar dials; it defaults to the hosted relay,
`wss://relay.yumi.to`. It is blind either way, so the only reason to move is to keep the traffic on
your own network: `ws://100.100.1.1:8787` is the Mac mini above over Tailscale.

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
./scripts/build-mac.sh          # prints dist/Yorozu-0.1.0-54.dmg, version 0.1.0 build 54
```

Neither number is typed: the marketing version is the latest `v*` tag and `CFBundleVersion` is
the commit count, which rises with every commit and never repeats. Sparkle compares
`CFBundleVersion`, so that is what makes one build newer than another, and the build number is
in the DMG's name so two builds of one tag are two files rather than one URL with two meanings.
`scripts/build-ios.sh` derives both the same way.

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
`Info.plist` beside `SUFeedURL`, along with the keys that make updates automatic
(`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, `SUAllowsAutomaticUpdates`, and an hourly
`SUScheduledCheckInterval`). Those are only a *default*, for a Mac that has never run the app;
`apps/mac/Sources/YorozuMac/Updater.swift` turns the same three on once per machine so an
answer given to an older build's "check automatically?" prompt does not keep the Mac on an old
version forever.

Sparkle's scheduling is opaque from the outside — the Mac that sat three releases behind said
nothing about why — so `Updates.logStatus()` writes one line to `~/Library/Logs/Yorozu/app.log`
at launch and every hour: `canCheck`, whether automatic checks and downloads are on, the
interval, and how long ago the last check was. If it cannot check it logs why (a session
already running, or the updater not ready), and a check overdue by more than two intervals is
nudged with `checkForUpdatesInBackground()`. Installing does not wait for a quit: with no chat
window open Sparkle is told to install immediately, and never to postpone the relaunch. See
[Staying alive](#staying-alive).

A release is one command, from a checkout standing on the tag:

```sh
git tag -a v0.2.0 -m v0.2.0
./scripts/release.sh
```

It builds, notarizes, signs the appcast, and uploads the DMGs the appcast offers, a stable
`Yorozu.dmg` and `appcast.xml` to this repo's rolling `mac` release, which
`yorozu.yumi.to/mac`, `/appcast.xml` and `/download/*` redirect to. It also uploads everything
to that version tag's GitHub release with `--clobber`. Releases run locally, where the
Developer ID identity, the notary profile and the Sparkle key live; CI holds no signing secrets.

## TestFlight

Internal testing only: team members are added to the "Internal" beta group in App Store Connect and install through the TestFlight app. No public link.

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

It runs locally with `ASC_KEY_ID` and `ASC_ISSUER_ID` set; the key itself is read from
`~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8`.

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
