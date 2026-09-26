# Architecture

How Yorozu actually works: who answers a thread, how the two devices meet, and what the relay
can and cannot see. For building and shipping, see [releasing.md](releasing.md).

## Backends

A thread's `agent` is fixed when the thread is created and never changes.

| Agent | Who answers | Where it runs |
| --- | --- | --- |
| `yorozu` | the OpenClaw Gateway | loopback websocket, `ws://127.0.0.1:18789` by default |
| `claude-code` | Claude Agent SDK | in-process in the sidecar, one session per thread |
| `codex` | Codex SDK | in-process in the sidecar, one session per thread |

A thread with no `agent` on the wire is a `yorozu` thread — that is every thread created before
the field existed.

OpenClaw owns everything about execution for its threads: providers and credentials, model
choice, tools, permission prompts, skills, scheduling and PAIOS memory. Yorozu holds none of it.
On first launch the sidecar pairs a private Ed25519 client identity with the Gateway and stores
its device token at mode `0600` under `YOROZU_STATE_DIR`. That is client authentication only;
provider credentials never enter Yorozu.

A native-agent thread is the opposite: its own SDK session, in its own working directory under
`~/Projects` chosen at creation, with that agent's own tools and its own permission prompts.
Yorozu's dispatch does not sit in the middle of it.

## The sidecar

`packages/runtime` builds `yorozu-serve`, which the Mac app spawns and supervises. It loads or
creates the Mac's X25519 and Ed25519 keypairs, registers its relay room, mints a join token,
prints the pairing payload, and from then on bridges sealed relay frames to whichever backend
owns the thread.

Its stdout is a line protocol the Mac app parses:

| Line | Meaning |
| --- | --- |
| `STATE <state>` | a relay transition, drawn in the menu bar window |
| `QR <string>` | the pairing string to draw as a QR code |
| `PAIR <string>` | the same string, to show as copyable text |

`MINT` on its stdin mints the next join token — that is what the **New code** button sends.

A `keys.json` that exists but will not read stops the sidecar rather than minting a new identity,
since new keys would silently unpair every phone. Only an absent file is a first run.

Interactive remote terminal sessions are retired. Older clients receive an error for terminal
controls, and the host removes the old terminal opt-in at startup. Backend-owned shell tools
and their results remain available in agent threads.

## Pairing

The pairing code carries the Mac's X25519 key, the room ID and a one-time token as one compact
string:

```
yorozu://pair?v=1&relay=<urlencoded>&key=<base64url>&token=<base64url>&room=<base64url>
```

The QR encodes that same string, so one parser — `decodePairingString` in `packages/shared`,
`QrPayload.decode` in `packages/shared-swift` — serves the scanner, the paste field and the
`yorozu://` link a phone opens when the code is tapped in Messages.

The phone joins the room, announces its own X25519 key in one cleartext `hello` frame, and every
frame after that is ChaCha20-Poly1305 sealed. The X25519 secret yields one key per direction
(`deriveChannelKeys`: HKDF info `yorozu-channel/mac->device` and `device->mac`), so a box the
relay reflects to its own sender opens under no key it holds. Inside each box the plaintext is
`{"seq", "event"}`, `seq` counting up from 1 per sender and direction; a receiver drops any box
at or below the last `seq` it accepted, and both ends keep their counters across a restart —
the Mac in `channel-seq.json`, the phone in its Keychain pairing record. A phone that unpairs and
pairs again under new keys starts from zero, and a stale record dies
with the device (`device_remove` drops it from `devices.json`). A device waits for the Mac's
encrypted greeting before sending requests. Public 0.2.3 clients used one shared key and plain
events instead. The Mac greets an unidentified device in both formats, modern first, then sends
only the format it answers in. A modern box upgrades a legacy connection; old-format boxes cannot
switch that connection back. The current device client also accepts either greeting, so it works
with a Mac still on 0.2.3. The shared `deriveSessionKey` is also used for push preview boxes.

The relay checks each frame's signature — but the relay could have signed it itself, so the
runtime does not take the relay's word for who is enrolling. The pairing string carries a
`secret` the Mac minted and the relay never sees, and a `hello` for keys not already on file is
accepted only with `proof`, a hash over that secret and both announced keys (`helloProof`,
byte-identical in both languages). The Mac honours the last four secrets it drew and spends them
all on a pairing.

## Multiple hosts on one client

iOS and client Macs keep one `HostSession` per authenticated Mac X25519 public key. A relay
URL, room ID, computer name or thread ID cannot substitute for that identity. Each session owns
its own device identity, channel counters, `RelayClient`, `ChatModel`, cache key, encrypted
history and outbox. `MultiHostModel` combines their thread lists, search results and unread
counts; actions resolve a `(hostID, threadID)` pair back to its owning model. Identical thread
IDs on different Macs remain separate chats.

All sessions connect while the app is active. iOS suspends their sockets together and uses
APNs/background catch-up for every paired host. With one saved host, host names and pickers
stay hidden and new threads and shares use that destination automatically. With multiple
saved hosts, rows show host labels and New Thread remembers its last destination and offers
a host picker; projects and agents come from that destination. Share Sheet New Session then
requires an explicit host choice. Existing share destinations always carry both host and
thread IDs. Saved connections still count while offline or being repaired.

Settings → Connection holds Add Host, connection and compatibility states, repair and removal.
With multiple saved connections it becomes Hosts and also shows names and nicknames.
A pairing link opened by a paired client asks to add the host and shows its relay and
key fingerprint. A duplicate key is detected before its one-time token is consumed and offers
explicit repair. Removal clears only that host's keys, counters, cache, outbox, preview key and
pending notifications. Existing single-host records migrate with their keys and persisted
counters intact; cache migration retains the original encryption key and files.

Peer information travels inside the encrypted channel using bounded typed fields on existing
`thread_list` messages. App versions are diagnostic; protocol ranges and capabilities determine
compatibility. Peers negotiate support before the host sends its macOS computer name. Older
peers retain legacy chat, with a stable `Mac · [fingerprint]` label when no authenticated name
is available. A local nickname overrides the supplied name. A required protocol or security
mismatch blocks that host with **Update required** while other hosts continue working.

## The relay

The relay forwards ciphertext between Mac and phone and can read none of it. Rooms are keyed by
`base64url(sha256(macPublicKey))`. The Mac registers by signing a server-issued nonce with its
Ed25519 key, then mints one-time join tokens that the phone redeems with a signature over the
token.

Every frame carries a signature from the sender's registered key; unsigned or mis-signed frames
close the connection. The limits live in `apps/relay/src/protocol.ts`:

| Limit | Value |
| --- | --- |
| Join token TTL | 10 minutes |
| Offline buffer TTL | 24 hours |
| Offline buffer cap | 5 MB per room, oldest dropped first |
| Rate limit | 60 frames/second per socket |

While the Mac is offline, phone frames are buffered per room and replayed in order on reconnect,
each tagged with a `seq` the Mac acks; an unacked frame is replayed to the next registration
rather than lost. Mac frames are never buffered: the phone treats the socket as a fast path only,
and on every join asks the Mac for the thread list, a sync, and the devices, so nothing depends
on the socket having been up. The Mac's fan-out to every paired phone travels as one `frames`
batch and costs one token.

Clients pass the room as `?room=<roomId>` on the websocket URL. The room only appears on the wire
inside `register`/`join`, which is too late for a relay that must route the socket before reading
it; both clients know the ID before they dial. The Node relay ignores the query.

Both relays log one JSON line per socket event (`registered`, `joined`, `close`, `drop`, `drain`,
`buffer-trim`, `apns`) with no payloads or keys.

There are two implementations of the one protocol, sharing its pure policy — limits, close codes,
envelope shapes, rate limit, buffer trim — in `apps/relay/src/protocol.ts`:

- **Hosted** — `src/worker.ts`, a Cloudflare Worker with one Durable Object per room, which is
  what `wss://relay.yumi.to` runs. Sockets use the Hibernation API, tokens and the offline buffer
  live in DO storage, and the buffer's TTL is swept by a DO alarm.
- **Self-hosted** — `src/index.ts`, a plain `ws` server with everything in memory (`PORT`,
  default 8787).

## Push notifications

APNs alerts every registered phone. What that costs in privacy is the point of the design, so it
is worth being exact about it.

A server-open socket is not proof the iOS app is visible — a suspended app can leave one behind —
so the app suppresses presentation while foregrounded instead of the relay guessing.

Beside every sealed frame the Mac sends the relay one `notify`: a cleartext class (`reply`,
`approval`, `done` or `failed`) and an opaque `threadRef`. A reply also includes one ChaChaPoly
preview box per paired phone, addressed by the Ed25519 key the relay already knows and sealed
under that phone's existing session key. The reference is the first eight characters of
`base64url(sha256(threadId))`, and a thread ID is a random UUID, so it is a handle the relay can
match and cannot invert. Phones register their APNs token the same way (`push`), filed against
the Ed25519 key the relay knows each device by — so `revoke` drops the token with the device.

So the relay learns: that a device exists and how to wake it, that something of one of four
classes happened, which opaque reference it happened under, ciphertext length, and roughly when.
It never sees message text, tool names or arguments, approval details, summaries or thread
titles — those travel sealed, in the frame beside the notify, under a key the relay does not
hold. APNs receives a fixed fallback body plus that opaque box. The iOS Notification Service
Extension opens a valid reply box locally and replaces the fallback; missing keys, malformed
boxes and failed authentication leave the fallback unchanged. The extension tries the per-host
preview keys and accepts only a unique authenticated match; relay-written host metadata cannot
select the destination. The app repeats that verification before any lock-screen approval.
Notification titles remain **Yorozu**. A legacy silent push with no authenticated host selection
causes catch-up across all hosts; ambiguous thread links never choose an arbitrary host.

Running commentary — deltas, tool traffic — is never notified at all, so a turn's every tool call
does not become a push. Only a turn arriving somewhere a person has to be told about is worth a
wake-up.

The hosted relay needs an Apple auth key for this, as three Wrangler secrets: `APNS_KEY_ID`,
`APNS_TEAM_ID` and `APNS_KEY_P8` (the .p8 itself). Without them it forwards frames exactly as
before and wakes nobody, which is what the self-hosted `src/index.ts` does always — it accepts
the same messages and holds no key.

## Threads and sync

A thread is an append-only log: `<state dir>/threads/<id>.jsonl`, one event per line, with
`threads.json` beside it as the index carrying titles, pins, archive state, the thread's agent
and — for native agents — its working directory and session ID.

Only conversation events are logged: `message`, `thought`, `tool_call`, `tool_result`,
`approval_card`, `approval_answer`, `question_card`, `question_answer`, `progress_card`. Sync and
thread admin are control traffic and leave no trace.

An absent index is a first run. An unreadable, malformed or structurally invalid index stops the
operation and leaves the file untouched: restore from backup or repair the original before
restarting, because logs alone cannot recover native session metadata safely.

Threads are created on demand and nobody is asked to name one. `+` creates a thread with an empty
title, the lists draw it as "New chat", and as the first message lands the sidecar asks the Mac's
on-device model (Apple's Foundation Models framework, through `yorozu-native`) for a 3-5 word title
from it, alongside the turn rather than after it — falling back to the first five words of the
message when the model is unavailable or does not answer within 15 s. Not the configured chain: a
label is no reason to send the opening message to a cloud model. Only an
empty title is ever filled in, which is also the whole of the rule that a title typed with Rename
is never overwritten.

`sync_request` carries `lastSeen`, a replay cursor per thread, and is answered with one
`sync_delta` holding everything after those cursors across every live thread — at most 200 events
per thread, and cut where the next event would take the frame past 512 KB. A truncated delta sets
`more`, which tells the phone to ask again: its `lastSeen` has moved to the end of what it got, so
the next page carries on from there and reaches the threads this one did not.

Routine sync starts at pairing time on a new device. Opening a thread sends a scoped
`sync_request` with `threadId`: the sidecar pages that thread's complete log, including events
before pairing. The client tracks this history cursor separately from routine sync and saves
completion in its encrypted cache, so unopened threads are not backfilled and reopening a loaded
thread does not fetch it again.

Replayed events carry an opaque `syncCursor` identifying their exact log occurrence,
so updates that reuse a progress card's ID cannot skip intervening history. Phones advance their
cursor only from replayed events and save it with the encrypted history, so live replies and
unsent messages cannot move it past unseen pages. An invalid cursor replays from the start.

Routine sync also names the open conversation as `focusThreadId`. The host puts its current reply
and still-actionable cards in `sync_delta.current`, sending cards that exceed the snapshot budget
as paced individual events before the delta, and scans that thread first. Paced sends rotate
among devices, replace an older request from the same device, and stop on reconnect or re-pair.
Current events never
advance `lastSeen`; older replay cannot replace a newer or final version of the same reply.
Subsequent replay pages skip that snapshot and retain open-thread
priority, so long backfills do not repeatedly scan the full log. Peers without these optional
fields keep ordinary replay.

Live agent replies send their first partial immediately, then keep only the latest unsent
revision per thread. A round-robin sender allows at most ten partial broadcasts per second
across threads and slows further when a broadcast splits into several relay batches. Final
replies bypass this queue and discard superseded partials; interrupted turns keep their last
queued draft. The host still
keeps the full current reply for reconnect catch-up and writes the final to durable history.
The host sends each live broadcast's sealed phone copies in relay frame batches of at most
16 entries and under 900 KB, so multiple paired phones do not multiply relay rate-limit cost.
Verbose thought, tool, and progress events use a separate relay budget: a 30-batch burst, then
ten batches per second. Critical replies, cards, and acknowledgments bypass that queue. The
queued trace is capped at 64 events or 512 KB and pauses when the host relay socket already
has more than 512 KB buffered. The host keeps durable trace history; if live queue pressure
skips an event, an empty `sync_delta` with `more` asks paired clients to replay from their own
cursors. The local Mac socket continues receiving traces immediately.

Sync builds an in-memory byte-offset index on the first read of a log, then seeks directly to each
page without re-parsing prior messages; file changes invalidate the index, metadata for 16
recently synced logs is retained, and message bodies are not cached.
`node scripts/benchmark-sync.mjs` compares a full drain against the previous full-log scan using a
temporary 10,000-event fixture.

## Several phones at once

The sidecar keeps directional and legacy shared keys per device, keyed by the X25519 key that phone
announced in its `hello`. Agent events are sealed once per device and broadcast; relay frames
carry no sender, so an inbound box is attributed to whichever device's receive key opens it,
which is also how a `sync_request` is answered to just the phone that asked. Because every phone receives the copies meant for the
others, `RelayClient` drops a frame it cannot open silently rather than reporting it.

Join tokens stay one-time, but a burnt one is replaced immediately: pairing mints the next token
and prints a fresh `QR` line, so the menu bar is always showing a code a second device can use.

Devices outlive a restart in `<state dir>/devices.json`, one record each: the X25519 key the
channel keys are agreed from, the Ed25519 key the relay knows it by, when it was last heard from,
and the platform name announced in an encrypted `device_list` request, such as `iPadOS 27.0`.
The two `seq` counters live
in `channel-seq.json`; the send counter is reserved 1000 ahead so streaming costs no writes.
The Mac shows the platform name in Devices, using a short key for older unnamed records, and
lists them
over the local socket — `device_list`, pushed whenever a device comes or
goes — with "online" meaning *said something in the last 90 seconds*, which is the only honest
answer the runtime has: the relay tells phones whether the Mac is up, never the other way round.
`device_remove` forgets one, and sends the relay a `revoke` so it cannot rejoin against the nonce
either. Both relays implement it.

## The iOS app

`apps/ios` is a real app target (bundle ID `to.yumi.yorozu.ios`, iOS 18+) depending on
`packages/shared-swift` by local path. Its Xcode project is generated by Tuist from
`apps/ios/Project.swift` and is not checked in — two manifests are fewer files than the eleven
`tuist generate` emits, and they cannot drift from the sources.

An unpaired phone opens on a splash and offers the two ways in: **Scan QR**, or the code pasted
into a text field. A tapped `yorozu://pair` link pairs without either, through `onOpenURL` — but
only a phone with no pairing pairs on the spot. One that already holds pairings is shown
the link's relay host and the Mac key fingerprint and asked **Add host**, because a link is a
line of text anyone can send. A duplicate offers **Repair connection**. A client Mac asks the
same question, and a hosting Mac is told it would stop hosting. Whichever way the code
arrived, it must name a `wss://` relay (`ws://` only to loopback), and it is stored together
with a freshly generated device identity — Ed25519 for frame signatures, X25519 for the session
key — in the Keychain.

Replies stream: the sidecar re-sends one message event per delta under a stable event ID, each
carrying the whole text so far, and the phone replaces that message in place rather than
appending. The relay answers `joined` with `ownerOnline` and pushes `{"type":"owner","online":…}`
whenever a room's Mac connects or drops; that drives the "Mac offline" toast — after five continuous
seconds of interruption (`ConnectionPresentation`), so a blip is never announced and the toast
overlays the list or transcript rather than moving them. Status lines (the Mac sidebar, Settings,
the multi-host count) read each host's `ChatModel.link`, which keeps its last settled wording through
the same grace, and only a paired link with the Mac present counts as connected. Presence is routing
state the relay already keeps to decide whether to forward or buffer, so it stays blind to the
ciphertext.

### Cache

`ThreadCache` keeps the thread list and one file per thread in a host-specific Application
Support directory, each sealed with AES-GCM under that host's 32-byte cache key in the Keychain.
The former single-host `Application Support/threads` directory is migrated on upgrade.
Application Support is readable by
anything that reaches the container, so the encryption — not the location — is what protects it.
A cache is only a cache: a missing, tampered or wrong-key file reads back empty, and the
`sync_request` sent on connect refills it. Unpairing deletes the files and the key.

That is what makes the app work offline: the list and every thread are read from disk at launch,
before the relay is even reachable.

### Outbox

Messages and controls are saved in the encrypted outbox before transmission. A socket send leaves
delivery uncertain; the runtime's durable receipt or operation outcome settles it. Queued and
confirming bubbles remain visible, and missing receipts or transient errors retry with the same
ID using jittered backoff. Independent threads can progress while one is waiting. A new thread's
creation stays ahead of its first message. The host deduplicates accepted IDs across restarts.

An unaccepted message has a host-enforced 30-minute admission deadline. It stays visible after
expiry and needs **Still send?** to create a new intent; an accepted task keeps running. Legacy
messages without a host deadline wait through the old relay buffer lifetime before they can be
reconfirmed. Approval answers and Stop requests likewise stay pending until their exact host
outcomes arrive. The outbox does not discard content to meet a count limit.

The relay client watches native network-path changes and redials promptly when a path switches.
An idle socket uses economical pings; a dial or online-host handshake that stalls is bounded.
Reconnect attempts use capped jittered backoff. Link presentation waits five continuous seconds
of detected interruption before showing a nonblocking toast; the raw transport and outbox react
immediately.

### List, export and link previews

The list is **Pinned**, then a section per stretch of time — Today, Yesterday, This week,
Earlier — with the archive folded away at the bottom. A thread's context menu and the chat's
**…** both offer **Export as Markdown**: the transcript with roles and timestamps, tool runs and
delegations folded into `<details>` notes, written out as a real `.md` by `ShareLink`.

The first bare URL in a reply — not one already inside a Markdown link or a code span — gets a
compact preview row under the bubble, fetched on device by `LPMetadataProvider` with a 5 second
timeout and cached under `Caches/Yorozu/link-previews`, keyed by the SHA-256 of the URL so a
directory listing is not a reading list. Nothing about it blocks the thread.

### Share sheet

`YorozuShare` puts Yorozu in the share sheet for selected text, a web link or one picture. The
composer shows what was shared as itself, takes an optional note, and offers the five most recent
threads, labeled with their host, plus **New session**. A new session requires an explicit host
choice before sending; it never silently uses the normal composer's last-used host.

The extension never touches the relay. It writes a `SharePayload` into the App Group container
(`group.to.yumi.yorozu`) and opens `yorozu://share?token=…`; the app, which owns the socket and
the outbox, is what sends it. That keeps the pairing's private keys out of a second process — and
because the payload is already on disk, an `open` that iOS declines to deliver costs nothing: the
app drains the container on every foreground. The token is a file name, checked to be a UUID
before it is joined onto a path, and a share is removed as it is read so it is never sent twice.

The picker's titles are the one thing that has to cross over: the extension cannot read the
encrypted `ThreadCache`, having no Keychain access group on purpose, so the app writes the five
host-qualified IDs, host labels and titles into the container, without pairing secrets or
transcripts. Removing a host removes its destinations and pending shares alone.

## The Mac app

A Mac is a **host** or a **client**, chosen on the first page of onboarding and stored as
`macRole` in `UserDefaults`. An install from build 139 or earlier had no such preference and
always hosted, so it is migrated to `host` rather than being asked.

A **host** runs OpenClaw and the sidecar, owns the thread logs, and is what phones and client
Macs pair with. Only a host spawns the sidecar, offers never-sleep, or shows the Devices and
Permissions settings sections.

A **client** Mac is the phone's twin: it pairs with hosts by pasting codes, talks over the same
blind relay through one `RelayClient` per host, and keeps separate encrypted caches. It runs no
sidecar, no OpenClaw and no agent.

### Host: the local socket

A host's chat skips the relay entirely. The sidecar opens a second way in beside its websocket:
a Unix domain socket at `<state dir>/local.sock`, carrying the
same newline-delimited `YorozuEvent` JSON in the clear. Nothing is encrypted because there is
nothing to encrypt against — the app and the sidecar are the same user on the same machine — so
the socket's mode is the access control, `0600` and nothing else. A socket file left by a killed
sidecar is removed before the bind.

Each connection is one more device in the sidecar's session map, so it costs nothing to reach:
`broadcast` already sends every reply and thread list to every paired device, and a local client
is simply one that needed no session key. Connecting is all the pairing there is.

| Client | Transport | Keys | Cache |
| --- | --- | --- | --- |
| iOS | `RelayClient` over the blind relay | X25519 session key per device | encrypted `ThreadCache`, so the phone reads offline |
| Mac, client | `RelayClient`, the same one | X25519 session key per device | encrypted `MacCacheStore` |
| Mac, host | `LocalSocketTransport` — `local.sock` | none | none: this machine's thread logs are the originals |

`ChatTransport` is the seam, and it is all the two apps disagree about. `ChatModel`, `ChatView`,
`ThreadListView`, the trace views and the cards all live in `packages/shared-swift` and compile
for both platforms. What is iOS-only is the pairing lifecycle — `Session`, `PairingStore`,
`CacheStore`, the QR scanner — and the end-to-end harness.

The menu bar window is a `NavigationSplitView`: threads left, chat right, the detail half in its
own `NavigationStack` so trace pages have somewhere to push. Everything that is not chat lives in
a standard `Settings` scene, reachable with ⌘, or from the gear at the foot of the sidebar, in
three sections: **General** (which also holds the relay URL and the YOLO toggle), **Devices** and
**Permissions**. A client that is not the host sees General alone. Provider, model, tool, permission,
browser, schedule and PAIOS controls all belong to OpenClaw. The model is built and connected
from `applicationDidFinishLaunching` rather than from the window, because a menu bar window only
exists while it is open and replies have to keep arriving either way.

### Permissions

`apps/mac/Sources/YorozuPermissions/Permission.swift` is one enum over everything the wizard and
the Permissions settings section walk — fourteen macOS privacy grants plus two settings of
Yorozu's own:

| Kind | Cases |
| --- | --- |
| TCC grants | Accessibility, Screen Recording, Input Monitoring, Full Disk Access, Calendars, Reminders, Contacts, Photos, Music, Location, Camera, Microphone, Files & Folders, Automation |
| Yorozu's own (`isAppSetting`) | Start at Login, Never Sleep |

`Permission.requestable` is the first group — the grants `yorozu-native` can report on and ask
for. The app's own two settings are in the same list only because to the user they are the same
list of things to turn on.

Onboarding presents the whole list on one page, all of it optional ("Grant only capabilities you
want; you can return anytime"), rather than gating Continue on each grant. Each row reads its own
state through the `yorozu-native` helper, deep-links to its System Settings pane, and re-checks
every two seconds while it is on screen, since macOS posts no notification when a grant changes.
The wizard opens on first launch (`onboardingCompleted` in `UserDefaults`) and again from
Settings → **Permissions**, which is the same list.

Never-sleep is a `caffeinate -dims` child process the app owns — no `pmset`, no sudo, and the
assertion dies with the app. The choice is remembered in `neverSleep` and restored at launch on a
host Mac only.

### Staying alive

A Mac that answers a phone has to be running Yorozu at all times, and on one morning it was not:
no crash report, no log line, no login item to bring it back, and three releases it had never
picked up. `YorozuKeepalive` is the answer to each of those, and everything below writes to one
file — `~/Library/Logs/Yorozu/app.log` — so `tail` over ssh is the whole diagnosis.

| Failure | What brings it back |
| --- | --- |
| The Mac restarted | the login item, `SMAppService.mainApp` |
| Yorozu died | the watchdog LaunchAgent, within a minute |
| The Node sidecar died | the app respawns it, backing off 1s → 60s |
| An update downloaded but never installed | Sparkle installs and relaunches while no chat window is open |

**Start at login** is `SMAppService.mainApp`: no helper and no plist of ours, revocable in System
Settings › General › Login Items. Settings → **General** shows `SMAppService`'s own status rather
than a preference of ours — macOS owns this one, and a second copy of the answer would be a copy
that could be wrong.

**Keep Yorozu running** is a user LaunchAgent, `to.yumi.yorozu.watchdog`, written to
`~/Library/LaunchAgents` on every launch and bootstrapped into `gui/$UID`. Every 60 seconds it
runs `Contents/Resources/watchdog.sh`: if no process is running out of the app's `Contents/MacOS`,
`open -a` the bundle and say so in the log. It is deliberately outside the app — the failure it
exists for is the app being gone, so nothing inside the app can be what notices — and
`StartInterval` rather than launchd's `KeepAlive`, which would own the app's process and fight
`open`, Dock activation and Sparkle's relaunch.

Every path in the agent comes from the running bundle, never `/Applications`, so a test build
under its own `BUNDLE_ID` supervises itself under its own label and cannot touch the real one.

**Quitting still quits.** ⌘Q unloads the watchdog; a crash gets nowhere near that code, so the
watchdog remains loaded and relaunches the app. Sparkle's update relaunch does not unload it: if
installation fails, the watchdog is exactly who should notice.

Native-agent turns keep their original user-operation ID and a running marker in `threads.json`.
After a host restart, the sidecar resumes an unfinished turn in its saved agent session with the
original request and recent host results, asking it to verify prior effects before repeating
work. The same reply ID completes the turn; no second user message is logged. Three unsuccessful
recovery attempts pause it across restarts with **Couldn't resume automatically** and Retry. A new
completed tool result resets that budget. A persisted Stop prevents automatic recovery.
If a host restart leaves a native Stop impossible to confirm, the host reports that uncertainty
and retires the recovery marker; the client keeps a warning with the cached conversation and
never labels the task Stopped.

## Approvals, questions and progress

The shipped approval surface is narrower than the wire protocol suggests, and the gap is worth
stating plainly.

**Native-agent threads** (`claude-code`, `codex`) raise real cards. `native-cards.ts` translates
the SDK's own permission and question prompts into `approval_card` and `question_card` events,
parks the turn until an `approval_answer` or `question_answer` comes back, and settles every open
card on interrupt. These carry no Yorozu rules, floors or task grants — the SDK is asking, and the
card is how the question reaches a phone. The **YOLO** toggle in Settings → General is passed to
these agents as a bypass.

Pairing is the grant: `approval_settings { yolo: true, hours }` from any paired device — phone or
Mac — is applied at once and broadcast. On is never for good: every grant stores `yoloUntil`
(default 8 h, cap 24 h), `loadSettings` reads a passed expiry as off, one timer in `serve.ts` flips
it off and broadcasts the change (re-armed at start), and `yolo: false` from any device applies
immediately. Turning YOLO on also reaches turns already running: native agents read it on each
prompt rather than once per turn, and every card still waiting is answered `yes` (echoed as
`approval_answer`) — except a Yorozu card raised by the floor, which YOLO never bypasses.

An approval can be answered from the notification. The Mac marks a `notify` with `actions: true`
when the action is quick-approvable, and the relay sets the notification category to
`approval-quick`, which the app registers with **Allow** and **Don't allow** buttons; anything
else gets `approval-review`, whose only button opens the card. A button answer launches the app in
the background, finds the card the push's opaque `event` reference names, sends the same
`approval_answer` the card would — tagged `source: "notification"` — and hangs up. The runtime
honours a notification-sourced answer only for a card it judged quick-approvable itself: a relay
that put **Allow** under a purchase card gets a rejected approval status rather than a purchase.

Approval answers stay in the encrypted per-host outbox, ahead of ordinary messages, until the
host returns `approval_status`; a `receipt` alone does not mark the card answered. Each random
`actionId` belongs to one live card in one thread and backend invocation. The host applies an
answer only while that card is still pending, rejects answer intent older than 30 minutes, and
returns `no-longer-needed` if the card expired or was replaced. Outcomes are flushed to thread
history before acknowledgment; a retry of a recorded answer ID returns that outcome after restart.
Negotiating peers require `offline-approval-v1`; older clients receive an upgrade message rather
than a receipt for a stale answer.

**`yorozu` threads have no Yorozu approval gate.** OpenClaw owns permission prompts for them.
`progress_card` events are live on this path, translated from the Gateway's plan stream by
`openclaw.ts`; `thought`, `tool_call`, `tool_result` and `message` come the same way and drive the
work rows and trace pages.

OpenClaw turns retain their Gateway run ID and original input in the sidecar's pending ledger.
After restart, the sidecar reattaches to an active run or safely resends an input with no Gateway
receipt. A consumed input with no active run, final answer, or delegated announcement for five
seconds is continued in the same Gateway session with the original request and bounded history
of prior tool effects. The same Yorozu user event and final ID remain in use. Three lost
continuations pause the turn for Retry or Dismiss; Gateway connection retries do not use this
budget. A new successful tool result resets it. Delegated task and announcement delivery states
are checked with Gateway before continuation; late events from a settled child cannot finish the
new run. A Stop fences continuation before sending.

The approval **rule engine** in `approval.ts` — the floor, action classes, structured scopes,
rules with `always`/`never` precedence, rule proposals — is fully implemented, wire-supported
(`rule_list`, `rule_update`, `rule_delete`) and covered by tests, but it is only consulted by the
dormant legacy loop. Rules can be stored and are never enforced on a shipped launch, and neither
app currently exposes an entry point to `RuleEditorView`. Treat it as unwired, not as protection.
See [legacy-runtime.md](legacy-runtime.md).

## Event trace rendering

`packages/shared-swift/Sources/YorozuShared/AgentTrace.swift` turns a thread's events into what is
drawn, as pure functions both platforms share:

| Function | Result |
| --- | --- |
| `delegationCards(from:)` | one card per delegation — name, running/done, its events |
| `chatRows(from:)` | the thread in order: bubbles, grouped tool activity, and each card where it was raised |
| `mainTrace(from:)` | the main agent's own thoughts, tool calls and results |
| `toolActivities(from:)` | each `tool_call` paired with the `tool_result` that answered it |
| `traceEntries(from:)` | a trace page in order, with unbroken runs of tool use grouped |
| `unifiedDiff(in:)` | a tool's output read as a diff, or nil when it is not one |

Everything an agent does between one message and the next is one row in the thread: `WorkRowView`
over a `TurnWork`. While the turn runs it is a single live line — a spinner and what is happening
right now — that replaces itself as the work moves on. When the turn is over it collapses to
`N steps · 2m` (and `n failed`) and opens to the whole trace: thoughts, tool runs with a one-line
argument summary and how long each took, delegation cards, progress cards. Cards that need a
person close the work row and stand below it; they are never folded away.

A result that is a unified diff is drawn as one, coloured, with its `+n −m` counts on the
collapsed row. `unifiedDiff(in:)` decides that on the hunk header, because a `+` at the start of a
line is ordinary enough in ordinary output. Long output is cut to twelve lines behind **Show
all**, capped so one `cat` cannot become the whole screen.

Navigation is by value: `.agentTraceDestination { model.events }` resolves a `TraceTarget` against
the *live* event list, so an open trace keeps streaming rather than showing the snapshot the link
was built from.
