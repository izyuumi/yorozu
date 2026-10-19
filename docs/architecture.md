# Architecture

Yorozu is an OpenClaw chat channel, a peer of Signal or Telegram (#415). OpenClaw runs the agent, its sessions, memory and cron; Yorozu only carries messages between the owner's devices and one OpenClaw agent, with Signal-like status marks. Yorozu runs no model, router, worker or scheduler of its own, and has no Mac host process. The decisions behind this are in [OWNER_DECISIONS.md](../OWNER_DECISIONS.md); the secretary system it replaced is in [history/secretary-architecture.md](history/secretary-architecture.md).

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
| Channel plugin | `plugins/openclaw-yorozu` | Runs inside the Gateway. Holds the host keys, registers as host of its relay room, answers handshakes from allowlisted devices, runs one agent turn per incoming message, and sends replies, typing, tool rows, history, titles, read marks, cron rows, attachments and pushes. Adds `openclaw yorozu pair` and `openclaw yorozu devices`. Its [README](../plugins/openclaw-yorozu/README.md) is the reference for each file's behaviour; SDK facts and the choices made are in [openclaw-channel.md](openclaw-channel.md). |
| Relay | `apps/relay` (a copy; `main` is the source and the only deploy origin) | Rooms, joins, signed frames, offline buffer for device frames, APNs push. Reads only its outer envelope; serves v1 users too, so changes stay backward compatible ([apps/relay/README.md](../apps/relay/README.md)). |
| Client app | `apps/ios` (one multiplatform target `YorozuIOS`: iPhone, iPad, native SwiftUI Mac) | Pairing, conversation list, chat, Crons tab, attachments, push. Screens in `Sources/YorozuIOS`, state and cache in `Sources/Client` (`V3Model`, `V3Store`, `V3Transfers`). iOS only: notification service extension (`YorozuNotificationService`) and share extension (`YorozuShare`). |
| Wire package | `packages/YorozuWire` | Swift side of wire v3: Noise handshake and boxes (`WireV3.swift`), envelope (`V3Event.swift`), the relay link (`V3Connection.swift`), pairing link (`Pairing.swift`), push previews, crypto primitives. The plugin's twin is `src/wire.ts` and `src/envelope.ts`. |

## Wire v3

The client and the plugin speak wire v3 through the relay; [ios-relay-contract.md](ios-relay-contract.md) is the contract both sides implement, with known-answer vectors. In outline:

- **Pairing**: `openclaw yorozu pair` prints a QR and a `yorozu://pair?v=3&relay=…&key=…&token=…&room=…&secret=…` link. The client checks the host fingerprint with the owner, joins the relay room with the one-time token, and proves the secret inside its first handshake; the plugin then adds the device to its allowlist (at most 16 devices).
- **Sessions**: every connection runs a Noise IK handshake (the device knows the host's static key from the QR), so every connection has fresh keys. Transport boxes are ChaCha20-Poly1305; relay frames are Ed25519-signed.
- **Envelope**: JSON `{kind, data}` per box. Unknown kinds and fields are ignored; optional features are announced in `peer_info.capabilities`; a change that cannot be expressed that way raises the protocol version in `peer_info` ([release.md](release.md#version)).

## Conversations and sessions

All paired devices are one channel peer, `owner`, so every conversation shows on every device. A conversation is one OpenClaw thread session of the configured agent (`channels.yorozu.agent`, default `main`):

```
agent:<agent>:yorozu:direct:owner:thread:<convId>
```

`convId` is a lowercase UUID the client makes when the owner taps "+". `/new` (or `/reset`) in a conversation resets that session in place; other slash commands go to OpenClaw as typed. Only Yorozu thread sessions of that agent are listed; other channels' sessions never are.

## Message flow

1. The client seals a `message` (`convId`, `messageId`, text, attachment ids) and sends it. The relay's `accepted` is ✓ sent.
2. The plugin opens the box and answers `delivered` (✓✓) to every device, then runs one agent turn in the conversation's session (`runChannelInboundEvent`). A repeated `messageId` gets `delivered` again and is not run twice; the client resends undelivered messages on its next session.
3. `run_started` marks the message read; `typing` repeats while the run lasts; each tool call sends a `tool` row (`running`, then `done` or `failed`), shown collapsed.
4. The reply arrives whole, one `reply` per chunk of `textChunkLimit` characters (no streaming edits), to every device with a live session. Nothing is queued for offline devices: they backfill from history on reconnect.
5. After the last chunk, one push per finished reply goes through the relay's `notify`, with a preview sealed per device, skipping devices that have that conversation in the foreground.

A cron job with `delivery: {channel: "yorozu", to: "owner", threadId: <convId>}` arrives the same way as a `reply`, mirrored into that session's transcript, and pushes once.

## History, titles, read marks, crons, attachments

- **History**: the Gateway transcript is the source of truth. A client sends `conv_list` and pages `history` per conversation; the plugin reads the session store and transcript directly (not `chat.history`, which truncates). The client keeps a cache and fills gaps on open and reconnect, so a new device sees full history.
- **Titles, rename, archive, delete**: after a conversation's first turn the plugin asks OpenClaw's title generator (`generateConversationLabel`, on the agent's `utilityModel`) and writes the session's `displayName`; a rename sets `label`, which wins. Archive sets `archivedAt`; delete archives the transcript as `sessions.delete` does. Every change, from any device or the Gateway, reaches every device as `conv_update`.
- **Read marks**: one forward-only cursor per conversation in the plugin's state, merged from any device and sent to all; unread badges count agent replies after it. Mark as Unread is a flag on the cursor.
- **Crons tab**: `cron_list` returns every job of the configured agent, read from the cron store. Yorozu makes no admin calls: "Edit in Chat" opens a conversation with a draft for the agent, which edits the job with its own cron tool.
- **Attachments**: files both ways up to `mediaMaxMb` (8 MB), in 160 KiB sealed chunks. Uploads land in OpenClaw's media store and reach the turn as media; a reply's `MEDIA:` files are announced and downloaded by each device on request. The share extension hands a share to the app, which keeps the App Group copy until host `delivered` or `run_started`. Its folder ID supplies retry-stable message and new-conversation IDs; host-list reconciliation preserves undelivered local messages.

## Data on each side

| Side | Data | Where | Protection |
|---|---|---|---|
| Plugin | Host keys: X25519 static (Noise) and Ed25519 (relay room, signed frames) | OpenClaw's credentials store, `<stateDir>/credentials/yorozu/host-keys.json` | `0600` in a `0700` directory; made once, never rewritten or logged. Deleting it means a new room: every device pairs again. |
| Plugin | Device allowlist, read cursors, push titles, finished uploads | OpenClaw's keyed state store, `<stateDir>/state/openclaw.sqlite`, namespaces `devices`, `read`, `push-titles`, `attachments` | File permissions of the OpenClaw state dir; assume not encrypted at rest. |
| Plugin | Live device sessions, pending pairing secrets | Memory | Gone on Gateway restart: devices re-handshake; an unused `pair` must be run again. |
| OpenClaw | Sessions, transcripts, generated titles | The agent's store under `<stateDir>/agents/<agent>/` | Plaintext, the same trust model as every OpenClaw channel. |
| OpenClaw | Uploaded files | `<stateDir>/media/inbound` | As above. |
| Client | Pairing: the QR's host data, the device's Ed25519 and X25519 keys | Keychain, service `to.yumi.yorozu.ios`, account `pairing-v3` | This device only, never synced (`kSecAttrSynchronizable` false), `AfterFirstUnlockThisDeviceOnly` so a silent push can reconnect while locked. |
| Client (iOS) | Push-preview key (derived; opens previews only) | Keychain group shared with the notification service extension, service `to.yumi.yorozu.v2.push-preview` | `AfterFirstUnlockThisDeviceOnly`; written on each connect, deleted on unpair. |
| Client | Conversation cache (`Conversations-v3/`), files (`Attachments-v3/`) | iOS: the app's Application Support. Mac: `~/Library/Application Support/to.yumi.yorozu.ios/client/` | iOS: Data Protection `complete`, excluded from backup. Mac: the user account's protection (FileVault); no per-file classes outside the sandbox. Wiped on unpair. |
| Client (iOS) | Shares waiting for the app | App Group `group.to.yumi.yorozu`, `ShareInbox/` | Holds no keys; the extension cannot send. |
| Relay | Device keys and APNs tokens per room, device frames buffered while the host is away (5 MiB, 24 h) | Cloudflare Durable Object | Sees only signed outer envelopes and sealed boxes. |

`<stateDir>` is OpenClaw's state directory: `~/.openclaw`, or `~/.openclaw-<name>` for `openclaw --profile <name>`.

Push previews (title and first line, at most 256 bytes) are sealed per device with a key derived from the host and device static keys; the relay and APNs see only the sealed box.
