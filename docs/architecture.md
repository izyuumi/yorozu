# Architecture

Yorozu is an OpenClaw chat channel. OpenClaw runs the agent, its sessions, memory and cron; Yorozu carries messages between the owner's devices and one OpenClaw agent, and runs no agent logic of its own. Product decisions are in [OWNER_DECISIONS.md](../OWNER_DECISIONS.md).

```
 iPhone / iPad / Mac client ──┐                                   ┌── OpenClaw Gateway (owner's computer)
 (apps/ios, SwiftUI)          │   wss, Ed25519-signed frames      │    plugins/openclaw-yorozu (TypeScript)
                              ├──────────► relay ◄────────────────┤    ↳ agent turns, sessions, transcripts, cron
 more paired devices ─────────┘   (apps/relay, Cloudflare Worker) └──  outbound connection only, no open port
            └──────────── Noise IK sessions, end to end; the relay sees sealed boxes only ────────────┘
```

## Components

| Part | Where | Role |
|---|---|---|
| Channel plugin | `plugins/openclaw-yorozu` | Runs inside the Gateway. Holds the host keys, registers as host of its relay room, answers handshakes from allowlisted devices, runs one agent turn per incoming message and sends the results to every device; answers history, title, read-mark, cron, device and attachment requests; sends pushes. Adds `openclaw yorozu pair`, `devices` and `devices remove` through Gateway methods (`yorozu.*`). File-by-file reference: its [README](../plugins/openclaw-yorozu/README.md); SDK facts: [openclaw-channel.md](openclaw-channel.md). |
| Relay | `apps/relay` | Rooms, joins, signed frames, offline buffer for device frames, APNs push, one-time mailboxes for pairing a Mac. Reads only its outer envelope. Deployed as a Cloudflare Worker; a Node variant exists ([README](../apps/relay/README.md)). |
| Client app | `apps/ios`, one multiplatform target `YorozuIOS` (iPhone, iPad, native SwiftUI Mac) | Pairing, conversation list, chat, Automations (crons), Settings, attachments, notifications. Screens in `Sources/YorozuIOS`; state, cache and transfers in `Sources/Client` (`AppModel`, `ConversationCache` and `Pairing` in `Store.swift`, `Transfers`). |
| Wire package | `packages/YorozuWire` | The client's side of the wire: Noise handshake, frames and boxes (`Wire.swift`), envelope (`WireEvent.swift`), relay link (`RelayConnection.swift`), pairing link (`Pairing.swift`), Mac pairing code (`DeviceCode.swift`), push previews, crypto primitives. |

### iPhone and iPad vs Mac

| | iPhone, iPad | Mac |
|---|---|---|
| Bundle id | `to.yumi.yorozu.ios` | `to.yumi.yorozu` |
| Pairing | Scans the host's QR or opens its link; can scan a Mac's code to add it | Opens a pairing link, or shows a code for a paired iPhone or iPad to scan |
| Notifications | APNs through the relay; a notification service extension (`YorozuNotificationService`) opens sealed previews | No relay push: local notifications while the app runs |
| Extensions | Share extension (`YorozuShare`), sending a share over a relay session of its own, or passing it to the app through the App Group; widgets, controls and the Live Activity's views (`YorozuWidgets`), reading only the App Group snapshot | None |
| Updates | TestFlight and the App Store | Sparkle ([release.md](release.md)) |
| Extra | — | Carries the plugin's source at `Yorozu.app/Contents/Resources/openclaw-channel` |

## Wire

Client and plugin speak the wire through the relay; [ios-relay-contract.md](ios-relay-contract.md) is the contract. In outline:

- **Pairing**: `openclaw yorozu pair` prints a QR and a `yorozu://pair?v=3&relay=…&key=…&token=…&room=…&secret=…` link. The client shows the host fingerprint to compare, joins the relay room with the one-time token, and proves the secret inside its first handshake; the plugin then adds the device to its allowlist (16 at most, the oldest making way). A paired device can ask the plugin for another code (`pair_invite`).
- **Sessions**: every connection runs a Noise IK handshake (the device knows the host's static key from the link), so every connection has fresh keys. Transport boxes are ChaCha20-Poly1305; relay frames are Ed25519-signed.
- **Envelope**: JSON `{kind, data}` per box. Unknown kinds and fields are ignored; optional features are announced in `peer_info.capabilities`; a change that cannot be expressed that way goes in phases: accept both, then send new, then drop old ([decisions](../OWNER_DECISIONS.md#versioning-rules)).

## Conversations and sessions

All paired devices are one channel peer, `owner`, so every conversation shows on every device. A conversation is one OpenClaw thread session of the configured agent (`channels.yorozu.agent`, default `main`):

```
agent:<agent>:yorozu:direct:owner:thread:<convId>
```

`convId` is a lowercase UUID the client makes for a new conversation. `/new` or `/reset` resets that session; other slash commands go to OpenClaw as typed. Only Yorozu thread sessions of that agent are listed.

## Message flow

1. The client seals a `message` and sends it; the relay's `accepted` is ✓ sent.
2. The plugin answers `delivered` (✓✓) to every device and runs one agent turn in the conversation's session (`runChannelInboundEvent`). A repeated `messageId` gets `delivered` again and is not run twice; the client resends undelivered messages in its next session.
3. `run_started` marks the message read; `typing` repeats while the run lasts; each tool call sends a `tool` row.
4. The reply arrives whole, one `reply` per `textChunkLimit` chunk, to every device with a session. Nothing is queued for devices without one: they catch up from history.
5. After the turn, one push through the relay's `notify`, preview sealed per device, skipping devices that have the conversation or the app in front and devices whose push is off.

A cron job with `delivery: {channel: "yorozu", to: "owner", threadId: <convId>}` arrives the same way as a `reply` and pushes once.

## History, titles, read marks, crons, attachments

Details of each are in the contract; in short:

- **History**: the Gateway transcript is the source of truth. The plugin reads the session store and transcript through the SDK and answers `conv_list` and paged `history`; the client caches pages and fills gaps on every new session, so a new device sees full history.
- **Titles, rename, archive, pin, delete**: on the session entry (`displayName` generated by OpenClaw's title generator, `label`, `archivedAt`, `pinnedAt`); every change from any device or the Gateway reaches every device as `conv_update`.
- **Read marks**: one forward-only cursor per conversation in the plugin's state, merged and sent to every device.
- **Automations**: `cron_list` returns the configured agent's jobs from the cron store, read-only; "Edit in Chat" drafts a message to the agent.
- **Attachments**: files both ways up to `mediaMaxBytes` (128 MB by default) in 160 KiB sealed chunks; uploads land in OpenClaw's media store, outbound files are downloaded by each device on request. The iOS share extension reads the pairing from the app's Keychain group, opens its own session (the host keeps one per device, so it replaces the app's, and an open app reconnects after), uploads and sends, and closes once the host answers `delivered` or `run_started`. On failure, Send Later writes the share into the App Group under the same message id; the app sends it through its outbox, reusing the share's IDs on retry, and deletes it once the host answers `delivered` or `run_started`.

## Data on each side

| Side | Data | Where | Protection |
|---|---|---|---|
| Plugin | Host keys: X25519 static (Noise) and Ed25519 (relay room, signed frames) | `<stateDir>/credentials/yorozu/host-keys.json` | `0600`; made once, never rewritten or logged. Deleting it means a new room: every device pairs again. |
| Plugin | Device allowlist, read cursors, push titles, stored attachments, last-message times, retried messages, reply targets, reactions | OpenClaw's keyed state store, `<stateDir>/state/openclaw.sqlite`, namespaces `devices`, `read`, `push-titles`, `attachments`, `message-times`, `retry`, `replies`, `reactions` | The OpenClaw state dir's file permissions; assume not encrypted at rest. |
| Plugin | Partial uploads | `<stateDir>/yorozu/upload-spool/<attachmentId>.part` and `.json` | Directory `0700`, files `0600`; dropped once stored, or after 24 hours idle. |
| Plugin | Device sessions, pending pairing secrets, alerted-device lists | Memory | Gone on Gateway restart: devices handshake again; an unused `pair` must be run again. |
| OpenClaw | Sessions, transcripts, generated titles | The agent's store under `<stateDir>/agents/<agent>/` | Plaintext, the same trust model as every OpenClaw channel. |
| OpenClaw | Attachment files | `<stateDir>/media/inbound`, `media/outbound` | As above. |
| Client | Pairing: the link's host data, this device's Ed25519 and X25519 keys | Keychain, the app's default group `<team>.to.yumi.yorozu.ios` (the share extension lists it too, to read), service `to.yumi.yorozu.ios`, account `pairing` (moved from `pairing-v3` on first launch) | Not synced, `AfterFirstUnlockThisDeviceOnly` so a background push can reconnect while locked. |
| Client (iOS) | Push-preview key (opens previews only) | Keychain group shared with the notification service extension, service `to.yumi.yorozu.v2.push-preview` | `AfterFirstUnlockThisDeviceOnly`; written on each connect, deleted on unpair. |
| Client | Conversation cache (`Conversations/`), files (`Attachments/`), both moved from their `-v3` names on first use | iOS: the app's Application Support. Mac: `~/Library/Application Support/to.yumi.yorozu/client/` | iOS: Data Protection `complete`, excluded from backup. Mac: the user account's protection (no per-file classes outside the sandbox). Wiped on unpair and on a new pairing. |
| Client (iOS) | Shares waiting for the app | App Group `group.to.yumi.yorozu`, `ShareInbox/` | Data Protection `complete`; holds no keys. |
| Client (iOS) | Widget snapshot: up to 12 conversation titles, pins, unread counts and reply times; the latest reply's first line only with Show Message Previews in Widgets | App Group `group.to.yumi.yorozu`, `WidgetSnapshot.json`, written by the app and the notification service | Data Protection `completeUntilFirstUserAuthentication`, so a push can update it while locked; holds no keys; none in demo mode, deleted on unpair. |
| Relay | Known device keys, join tokens, APNs tokens, device frames buffered while the host is away (5 MiB, 24 h) | Durable Object storage (Worker); memory (Node) | Sees only signed outer envelopes and sealed boxes. |

`<stateDir>` is OpenClaw's state directory: `~/.openclaw`, or `~/.openclaw-<name>` for `openclaw --profile <name>`.

Push previews (title and first line, at most 256 bytes) are sealed per device with a key derived from the host and device static keys; the relay and APNs see only the sealed box.
