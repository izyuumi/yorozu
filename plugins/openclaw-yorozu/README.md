# openclaw-yorozu

The OpenClaw channel plugin `yorozu`. It holds the host keys and one outbound WebSocket to the relay, answers wire v3 handshakes from allowlisted devices ([docs/ios-relay-contract.md](../../docs/ios-relay-contract.md)), and runs one agent turn per incoming message. Install, config keys, pairing and troubleshooting: [docs/setup.md](../../docs/setup.md). The OpenClaw SDK surface it relies on: [docs/openclaw-channel.md](../../docs/openclaw-channel.md).

## Entry points

- `index.ts`: the channel entry, the `openclaw yorozu` CLI registration, and the Gateway methods below (all scope `operator.admin`).
- `setup-entry.ts`: the setup entry (`defineSetupPluginEntry`).
- `openclaw.plugin.json`: plugin id `yorozu`, channel `yorozu`, CLI command `yorozu`, and the `channels.yorozu` schema.

| Gateway method | Params | Used by |
|---|---|---|
| `yorozu.pair.begin` | none | `openclaw yorozu pair` |
| `yorozu.devices.list` | none | `openclaw yorozu devices` |
| `yorozu.devices.remove` | `{id}`: full key or a unique prefix | `openclaw yorozu devices remove` |

A method fails with `UNAVAILABLE` and the error text, for example while the channel is not connected to its relay.

## Relay host (`src/relay.ts`, `src/wire.ts`, `src/envelope.ts`)

- Connects to `<relayUrl>?room=<room id>`, registers by signing the relay's nonce, then sends the device allowlist (`devices`). Pings every 30 s and drops a half-open socket. Redials with backoff from 1 s up to 30 s until the account stops.
- A handshake is answered only when the device's Ed25519 key and the X25519 key its handshake authenticates both match an allowlist row, or when it proves a pending pairing. Anything else gets a `revoke` to the relay. A handshake id that was already answered is not answered again within the 5-minute freshness window.
- One session per device, in memory. Sessions survive relay reconnects but not a channel or Gateway restart.
- Each device must send `peer_info` before anything else counts. If the protocol versions do not overlap, the device gets `error update_required` and its session is dropped. The host's `peer_info` carries the agent, the OpenClaw version, `mediaMaxBytes` and the capabilities `attachments`, `devices` and `invite`.
- Frames the relay buffered (`seq`) are acked after handling. Host frames are batched at up to 16 frames and under 1 MiB per batch.

## Keys and devices (`src/keys.ts`, `src/devices.ts`)

- **Host keys**: an X25519 static key and an Ed25519 relay key, made on first start in `<OpenClaw credentials dir>/yorozu/host-keys.json` (`resolveOAuthDir()`, written with `createSecretFileAtomic`) and never rewritten. The room id is `base64url(sha256(Ed25519 public key))`. It is logged at start and on every registration; keys are never logged. A malformed file stops the channel rather than being replaced. Deleting the file makes a new room, and every device has to pair again.
- **Allowlist**: rows in the plugin's keyed state store (namespace `devices`), keyed by the device's Ed25519 key, with its X25519 key, model name (from `peer_info`), paired time and push flag. At most 16 devices; past that the oldest is removed and revoked at the relay.

## Pairing

- `pair`: the plugin asks the relay for a one-time join token (`mint`) and makes a 32-byte secret. The secret is kept in memory until the token expires. It returns `yorozu://pair?v=3&relay=…&key=…&token=…&room=…&secret=…`, the same query as the fragment of `https://yorozu.yumi.to/pair#…` (which is what the QR carries), the host fingerprint and the expiry. The CLI writes to stdout directly, because OpenClaw's console capture redacts key- and token-like text.
- Joining: when a handshake's `helloProof` matches a pending secret, the device is added and the secret is dropped. A Gateway restart forgets pending secrets.
- `pair_invite` from a paired device gets a fresh code made the same way, so a device can be added away from the host.
- Removal (`devices remove`, or `device_patch {removed}` from Settings): the row is deleted, the session is dropped, and the relay gets `revoke`. If the relay is unreachable at that moment, the next registration's `devices` list has the same effect.

## Conversations (`src/conversation.ts`)

Every device is the same channel peer, `owner`. A conversation is the session `agent:<agent>:yorozu:direct:owner:thread:<convId>`, where `<agent>` comes from `channels.yorozu.agent`.

- **In**: a `message` is answered `delivered` to every device at once. A repeated `messageId` gets `delivered` again but does not run twice (remembered for 24 h). The message's uploaded files become media facts, and the turn runs through `runChannelInboundEvent` with commands authorized. Slash commands pass through as text; OpenClaw handles `/new` for that thread only.
- **Out**, to every device with a live session: `run_started`, then `typing` (repeated every 8 s), then `tool` per tool call (`running`, then `done` or `failed`), then one `reply` per chunk of the text chunk limit. Media goes on the last chunk as `attachments`. A failure sends `error run_failed`. Nothing is queued for offline devices; `history` serves the reply from the transcript later.
- **Retries** (`src/retry.ts`): a run that fails with a temporary error (plugin reload, overload, rate limit, 429/503/529, connection reset) before any reply or tool call is parked in the keyed state store (namespace `retry`). It runs again after 5, 15, 30, 60 and 120 s, and only the last failure is shown. A generation that replaces this one after a reload picks up the parked runs.
- **Deliveries from outside a turn** (cron): the outbound adapter's `sendText` and `sendMedia` send a `reply` into the conversation named by the delivery's `threadId`, with `to: "owner"`. `resolveOutboundSessionRoute` maps it to the thread session, so OpenClaw mirrors the text into that transcript.

## History (`src/history.ts`, `src/activity.ts`)

- `conv_list` and `history` are answered to the asking device only. They are read from the session store and the transcript (`listSessionEntries`, `getSessionEntry`, `loadTranscriptEventsSync`, `readTranscriptStatsSync`), never from `chat.history`. Pages hold up to 60 items and 192 KiB; one item's text is cut at 60,000 characters (the transcript keeps the whole text). Built item lists are cached for the 8 most recent sessions.
- Live replies take their ids from the transcript message they came from, so a device does not show a reply twice after paging.
- **Message times**: `conv_list`'s `updatedAt` is the conversation's newest user or agent message time from its transcript. It is kept per transcript revision in the keyed state store (namespace `message-times`).

## Titles, rename, pin, archive, delete (`src/sessions.ts`)

- After a turn, a conversation with neither `label` nor `displayName` gets a title. It comes from `generateConversationLabel` on its first non-command user message and is written as `displayName`, with at most 60 characters.
- `conv_patch`:
  - `title` sets `label` (an empty title clears it); `label` wins over `displayName`.
  - `archived` sets or clears `archivedAt`; archiving also clears `pinnedAt`.
  - `pinned` sets or clears `pinnedAt`. An archived conversation cannot be pinned.
  - `deleted` archives the conversation, then `deleteSessionEntry` with the transcript archived, and drops its read cursor.
  - All writes keep the entry's activity time (`preserveActivity`).
- The plugin watches session changes (`subscribeSessionChanges`) and sends every device a `conv_update` when a conversation's title, archive or pin state changed, whoever changed it.

## Read marks, push, automations, attachments, settings

- **Read marks** (`src/reads.ts`): one cursor per conversation (namespace `read`). It only moves forward, is broadcast to every device, and goes to each device when its session opens.
- **Push** (`src/push.ts`): one relay `notify` per finished reply, including cron deliveries with text. It is sealed per device (title and first line, 256 bytes at most). It goes to every paired device except those with push off and those whose live session reports the app in front or this conversation open. When a device reads a conversation, the other devices alerted for it get a silent `notify` of class `sync`.
- **Automations** (`src/cron.ts`): `cron_list` is answered with every job of the configured agent, including disabled ones. A job without `agentId` counts for the system agent, or else the default agent. Each job comes with its schedule in English words, next and last run, last status and error, and its Yorozu conversation when it delivers into one. The list is read from the cron store with `loadCronStore`. If that fails, the answer carries `error`. Yorozu only reads the jobs.
- **Attachments** (`src/attachments.ts`): uploads arrive in chunks into OpenClaw's media store, indexed in the keyed state store (namespace `attachments`). Outbound media is staged and announced in the `reply`, and each device downloads it on request, sealed for that device. The size limit is the media limit in [setup.md](../../docs/setup.md#2-config).
- **Settings**: `device_list` lists the paired devices (key, model, paired time, push, and which one is asking). `device_patch` turns push on or off for a device, or removes it.

## Trying it without the main Gateway

An OpenClaw profile keeps its own state, config and port (`~/.openclaw-<name>`). From the repository root:

```sh
openclaw --profile yorozu-dev config set gateway.mode local
openclaw --profile yorozu-dev plugins install --link plugins/openclaw-yorozu --force --accept-capabilities
openclaw --profile yorozu-dev gateway run --port 19422     # foreground; Ctrl-C stops it
openclaw --profile yorozu-dev channels status              # another terminal
openclaw --profile yorozu-dev yorozu pair
```

Use `gateway run`, not `gateway install`, which would add a login service for the profile.

## Typecheck

`tsconfig.json` extends `node_modules/openclaw/tsconfig.json`, so link the OpenClaw source checkout behind the `openclaw` command first (`node_modules/` is git-ignored):

```sh
cd plugins/openclaw-yorozu
mkdir -p node_modules
ln -s "$(dirname "$(realpath "$(command -v openclaw)")")" node_modules/openclaw
node_modules/openclaw/node_modules/.bin/tsc -p . | grep -E '^(index|setup-entry|src/)'
```

No output means the plugin typechecks. The `grep` drops errors from inside the OpenClaw checkout.
