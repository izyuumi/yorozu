# openclaw-yorozu

The OpenClaw channel plugin `yorozu`. It holds the host keys, one outbound WebSocket to the relay and a [direct listener](#direct-listener-srcdirectts) on private addresses, answers wire handshakes from allowlisted devices ([docs/ios-relay-contract.md](../../docs/ios-relay-contract.md)), and runs one agent turn per incoming message. Install, config keys, pairing and troubleshooting: [docs/setup.md](../../docs/setup.md). The OpenClaw SDK surface it relies on: [docs/openclaw-channel.md](../../docs/openclaw-channel.md).

## Entry points

- `index.ts`: the channel entry, the `openclaw yorozu` CLI registration, and the Gateway methods below (all scope `operator.admin`).
- `setup-entry.ts`: the setup entry (`defineSetupPluginEntry`).
- `openclaw.plugin.json`: plugin id `yorozu`, channel `yorozu`, CLI command `yorozu`, and the `channels.yorozu` schema.

| Gateway method | Params | Used by |
|---|---|---|
| `yorozu.pair.begin` | none | `openclaw yorozu pair` |
| `yorozu.devices.list` | none | `openclaw yorozu devices` |
| `yorozu.devices.remove` | `{id}`: full key or a unique prefix | `openclaw yorozu devices remove` |

A method fails with `UNAVAILABLE` and the error text, for example while the channel reaches neither its relay nor its direct listener.

## Relay host (`src/relay.ts`, `src/wire.ts`, `src/envelope.ts`)

- Connects to `<relayUrl>?room=<room id>`, registers by signing the relay's nonce, then sends the device allowlist (`devices`). Pings every 30 s and drops a half-open socket. Redials with backoff from 1 s up to 30 s until the account stops.
- A handshake is answered only when the device's Ed25519 key and the X25519 key its handshake authenticates both match an allowlist row, or when it proves a pending pairing. Anything else on the relay gets a `revoke` to the relay. A handshake id that was already answered is not answered again within the 5-minute freshness window.
- One session per device, in memory (`src/hub.ts`), each over its own path: the relay or the direct listener. A new session on either path replaces the old one, and an older direct socket is closed `4102`. Relay sessions survive relay reconnects; no session survives a channel or Gateway restart.
- Each device must send `peer_info` before anything else counts. If the protocol versions do not overlap, the device gets `error update_required` and its session is dropped. The host's `peer_info` carries the agent, the OpenClaw version, `mediaMaxBytes` and the capabilities `attachments`, `devices`, `invite`, `replies` and `reactions`, plus `liveActivityPush` while the relay can push, `direct` while the direct listener is listening, and `push-proxy` while the relay's `registered` says `pushProxy: true`.
- Unknown input never ends a session: an unknown kind is answered `error unsupported`, unknown fields are ignored, an unknown enum value passes validation (an unknown `live_activity` job kind or state is dropped before it reaches the relay), and an unknown relay message type is ignored.
- Frames the relay buffered (`seq`) are acked after handling. Host frames are batched at up to 16 frames and under 1 MiB per batch. Fan-out over the relay leaves out devices connected directly.

## Direct listener (`src/direct.ts`)

Capability `direct` (#532): clients reach the plugin without the relay, over the same Noise sessions ([wire](../../docs/ios-relay-contract.md#direct-path)).

| Config key | Default | Meaning |
|---|---|---|
| `channels.yorozu.direct.enabled` | `true` | `false` turns the listener off |
| `channels.yorozu.direct.port` | `8738` | Its port, an integer from 1024 to 65535 (anything else falls back to 8738) |
| `channels.yorozu.direct.bonjour` | `true` | `false` stops the `_yorozu._tcp` Bonjour responder; hints still go out |

- Its own WebSocket server (`WebSocketServer` from `openclaw/plugin-sdk/websocket-runtime`), not a Gateway route: one per local address that is loopback, RFC 1918, ULA or 100.64.0.0/10, read from `os.networkInterfaces()` when the channel starts and again every 5 s (`src/hints.ts`): new addresses are bound, addresses that went away are closed with their sockets. It never binds `0.0.0.0`, `::` or a public address. A port that no address can bind is logged, and the channel runs relay only.
- A socket must send `probe {nonce}` first; the plugin answers with the host's Ed25519 key and its signature over `yorozu-direct|<room>|<nonce>`. Then an init frame from an allowlisted device or one that proves a pending pairing, then signed boxes, each answered `accepted`. At most 8 sockets wait for their handshake, each for 10 s; a message over 1 MiB closes `4103`; anything out of order, a refused handshake, a bad signature or a browser `Origin` closes `4101`; a socket silent for 90 s is dropped.
- Hints (`direct_hints {port, lan[{address,prefix}], tailscale[{address}], magicDNS?}`, flag `direct`): the bound non-loopback addresses, split into LAN and Tailscale (100.64.0.0/10, `fd7a:115c:a1e0::/48`), plus the `.ts.net` name from a reverse lookup of the Tailscale IPv4 (2 s timeout). They go inside the encrypted session to devices whose `peer_info` lists `direct`, right after it and again whenever they change, over whichever path the device is on.
- Bonjour (`src/bonjour.ts`): a small mDNS responder on `node:dgram`, IPv4 LAN addresses only. One receive socket joins 224.0.0.251:5353 on each LAN address; replies and announcements go out from a socket bound to that address, never a wildcard. It advertises `<tag>._yorozu._tcp.local` with TXT `t=<tag>`, where the tag is the base64url of the first 9 bytes of HMAC-SHA256 (key: the host static public key, message `yorozu-bonjour`). Only a paired device, which knows that key, can match it to the host.
- `push_token {token}` from a device (capability `push-proxy`) goes to the relay as `push {device, token}` while the relay offers `pushProxy`, and is dropped otherwise.
- `node --test` covers the address filter, the probe, the limits and rebinding (`test/direct.test.ts`), hint extraction, MagicDNS and the watcher (`test/hints.test.ts`), and the tag vector, DNS parsing and a responder answering on loopback (`test/bonjour.test.ts`); `apps/relay/src/direct.test.ts` runs the listener and `hub.ts` end to end with a device, directly and through the Node relay.

## Keys and devices (`src/keys.ts`, `src/devices.ts`)

- **Host keys**: an X25519 static key and an Ed25519 relay key, made on first start in `<OpenClaw credentials dir>/yorozu/host-keys.json` (`resolveOAuthDir()`, written with `createSecretFileAtomic`) and never rewritten. The room id is `base64url(sha256(Ed25519 public key))`. It is logged at start and on every registration; keys are never logged. A malformed file stops the channel rather than being replaced. Deleting the file makes a new room, and every device has to pair again.
- **Allowlist**: rows in the plugin's keyed state store (namespace `devices`), keyed by the device's Ed25519 key, with its X25519 key, model name (from `peer_info`), paired time and push flag. At most 16 devices; past that the oldest is removed and revoked at the relay.

## Pairing

- `pair` (`src/pairing.ts`): the plugin asks the relay for a one-time join token (`mint`) and makes a 32-byte secret. The secret is kept in memory until the token expires. It returns `yorozu://pair?v=3&relay=…&key=…&token=…&room=…&secret=…`, the same query as the fragment of `https://yorozu.yumi.to/pair#…` (which is what the QR carries), the host fingerprint, the expiry and `directOnly`. While the direct listener is listening, the link also carries `port`, up to 4 LAN hints as `lan=<addr>/<prefix>,…` and up to 2 Tailscale addresses as `ts=<addr>,…` (no MagicDNS name). The CLI writes to stdout directly, because OpenClaw's console capture redacts key- and token-like text.
- Relay down: if the relay can't mint but the direct listener is listening, the token is 32 random bytes the relay doesn't know and the code expires in 10 minutes; the CLI says it pairs over the direct path only. With neither, `pair` fails.
- Joining: when a handshake's `helloProof` matches a pending secret, on the relay or the direct listener, the device is added and the secret is dropped; an expired or spent secret is refused. After a pairing over direct, the relay gets the `devices` allowlist at once if it is connected, else on the next `registered`. That code's relay token is not burned: it stays valid at the relay until it expires, but can't pair anyone else. A Gateway restart forgets pending secrets.
- `pair_invite` from a paired device gets a fresh code made the same way, so a device can be added away from the host.
- Removal (`devices remove`, or `device_patch {removed}` from Settings): the row is deleted, the session is dropped, and the relay gets `revoke`. If the relay is unreachable at that moment, the next registration's `devices` list has the same effect.

## Conversations (`src/conversation.ts`)

Every device is the same channel peer, `owner`. A conversation is the session `<owner session>:thread:<convId>`, where `<owner session>` is the key OpenClaw routes the peer to: `agent:<agent>:yorozu:direct:owner` by default, with `<agent>` from `channels.yorozu.agent`, but `bindings` and `session.identityLinks` can change the agent or the peer part, so the plugin resolves it at start (`setThreadBase`).

- **In**: a `message` is answered `delivered` to every device at once. A repeated `messageId` gets `delivered` again but does not run twice (remembered for 24 h). The message's uploaded files become media facts, and the turn runs through `runChannelInboundEvent` with commands authorized. Slash commands pass through as text; OpenClaw handles `/new` for that thread only.
- **Out**, to every device with a live session: `run_started`, then `typing` (repeated every 8 s), then `tool` per tool call (`running`, then `done` or `failed`), then one `reply` per chunk of the text chunk limit. Media goes on the last chunk as `attachments`. A failure sends `error run_failed`. Nothing is queued for offline devices; `history` serves the reply from the transcript later.
- **Retries** (`src/retry.ts`): a run that fails with a temporary error (plugin reload, overload, rate limit, 429/503/529, connection reset) before any reply or tool call is parked in the keyed state store (namespace `retry`). It runs again after 5, 15, 30, 60 and 120 s, and only the last failure is shown. A generation that replaces this one after a reload picks up the parked runs.
- **Replies** (`src/replies.ts`): a `message`'s `replyTo` reaches the turn as OpenClaw's quote context (`ReplyToId`, `ReplyToBody`). The channel's reply mode is `off`, so only an explicit `[[reply_to…]]` tag or the message tool's `replyTo` gives an outbound `replyToId`; the plugin turns it into the `reply`'s `replyTo`, with the target's text from the turn or the transcript. Each `replyTo` is kept by the replying message's id (namespace `replies`) for its history item.
- **Reactions** (`src/reactions.ts`): one emoji per person per message. A device's `reaction` updates the user's slot, goes to every device, and queues the system event `Yorozu reaction added: <emoji> on msg <id>` (or `removed`) in the conversation's session, replacing a pending one for that message; it does not start a turn. The agent reacts through the `message` tool's `react` action (`plugin.actions`; `capabilities.reactions`, `reactionSlots: "single"`), which updates the agent's slot and sends `reaction` with `by: "agent"`. Reactions are kept by message id (namespace `reactions`) for history items.
- **Deliveries from outside a turn** (cron): the outbound adapter's `sendText` and `sendMedia` send a `reply` into the conversation named by the delivery's `threadId`, with `to: "owner"`. `resolveOutboundSessionRoute` maps it to the thread session, so OpenClaw mirrors the text into that transcript.

## Gateway notices (`src/updates.ts`)

Yorozu never updates OpenClaw itself; it relies on OpenClaw's auto-update ([setup.md](../../docs/setup.md#openclaw-updates)). Each time the channel starts, the plugin may post up to two notices into the most recent unarchived conversation. Each goes out through `sendDurableMessageBatch` with a transcript mirror, so a device that connects later finds it in history. With no conversation yet, nothing is posted.

- **Version**: the OpenClaw version (`runtime.version`) is kept in the keyed state store (namespace `gateway`, key `version`). When it differs from the one stored at the last start, the plugin posts `Updated OpenClaw <old> → <new>` once. The first start only stores it.
- **Auto-update**: the plugin checks what OpenClaw's auto-updater checks: `update.auto.enabled` is `true`, `update.checkOnStart` is not `false`, `OPENCLAW_NO_AUTO_UPDATE` is not set, and the Gateway runs as the service `openclaw gateway install` made (`OPENCLAW_SERVICE_MARKER=openclaw` and `OPENCLAW_SERVICE_KIND=gateway` in its environment). If any check fails, it posts one notice that names each failing check and how to fix it. The list of failures is stored (key `auto-update`), and the notice is posted again only when that list changes. Once every check passes, the stored list is cleared.

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
- **Live Activity push** (`src/liveactivity.ts`, wired in `src/relay.ts` and `src/conversation.ts`): capability `liveActivityPush`, listed only while the relay's `registered` says `liveActivity: true`. A device's `live_activity` report (push token, jobs, running turn → conversation) is kept in memory and its token sent to the relay (`activityToken`). Tool calls and the end of a turn change only that turn's job; the whole state goes to the relay as `activityPush`, steps at priority 5 at most once per 15 s, finished rows at priority 10, `end` when nothing runs. Other jobs pass through unchanged. Details: [Live Activity push](../../docs/ios-relay-contract.md#live-activity-push).
- **Automations** (`src/cron.ts`): `cron_list` is answered with every job of the configured agent, including disabled ones. A job without `agentId` counts for the system agent, or else the default agent. Each job comes with its schedule in English words, next and last run, last status and error, and its Yorozu conversation when it delivers into one. The list is read from the cron store with `loadCronStore`. If that fails, the answer carries `error`. Yorozu only reads the jobs.
- **Attachments** (`src/attachments.ts`, `src/spool.ts`): uploads arrive in chunks, spooled to disk so they resume after a reconnect or restart (`upload_status`, capability `resume`), then go into OpenClaw's media store, indexed in the keyed state store (namespace `attachments`). Outbound media is staged and announced in the `reply`, and each device downloads it on request, sealed for that device. The size limit is the media limit in [setup.md](../../docs/setup.md#2-config).
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

## Tests

`src/liveactivity.ts`, `src/envelope.ts`, `src/direct.ts`, `src/hints.ts`, `src/bonjour.ts` and `src/hub.ts` import nothing from OpenClaw, so Node runs their tests without it: `node --test test/*.test.ts` (Node 26, from this folder; `test/envelope.test.ts` maps the sibling `./x.js` imports to `./x.ts` with a resolve hook). The Live Activity tests share `apps/ios/Tests/Fixtures/activity-content-state.json` with the relay's and the app's tests.
