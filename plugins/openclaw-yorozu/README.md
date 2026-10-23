# openclaw-yorozu

OpenClaw channel plugin for Yorozu (#415). The Yorozu apps reach the Gateway through this channel. The `yorozu` channel holds the host keys and the relay connection: it registers as the host of its relay room, redials with backoff, and answers wire v3 handshakes ([docs/ios-relay-contract.md](../../docs/ios-relay-contract.md); `src/wire.ts`, `src/envelope.ts`) from allowlisted devices. `openclaw yorozu pair` pairs a device, and text messages run agent turns in per-conversation sessions (below). SDK facts behind it are in [docs/openclaw-channel.md](../../docs/openclaw-channel.md).

## Install

From the repository root:

```sh
openclaw plugins install --link plugins/openclaw-yorozu --force --accept-capabilities
openclaw gateway restart
openclaw channels status
```

`--link` points OpenClaw at this directory, so edits load on the next Gateway restart. `--force` confirms a source that is not on ClawHub; `--accept-capabilities` gives the capability consent the install otherwise stops for. The install enables the plugin under `plugins.entries.yorozu` (and adds it to `plugins.allow` when an allowlist is set) and needs no `channels.yorozu` entry. The v1 channel (`packages/openclaw-channel` on `main`) uses the same plugin id `yorozu`; uninstall it first if it is installed.

## Keys and devices

- **Host keys** (`src/keys.ts`): an X25519 static key and an Ed25519 relay key, made on first start in `<stateDir>/credentials/yorozu/host-keys.json` (`0600`, directory `0700`) and never rewritten. The room id, `base64url(sha256(Ed25519 public key))`, is logged at start and on every registration; keys never are. Deleting the file means a new room, and every device pairs again.
- **Device allowlist** (`src/devices.ts`): rows in the plugin's keyed state store (`<stateDir>/state/openclaw.sqlite`, namespace `devices`, keyed by the device's Ed25519 key), through `getDevice`, `listDevices`, `putDevice` and `removeDevice`; at most 16, the oldest making way. A handshake is answered only when the device's Ed25519 key and the X25519 key its handshake authenticates both match a row, or when it proves a pending pairing (below). The list is read on every handshake and announced to the relay (`devices`) on every registration, so the relay lets only listed devices rejoin. A device the relay let in that is neither gets a `revoke`, so the relay forgets it and closes its socket.
- **Sessions** (`src/relay.ts`): in memory, one per device; they survive relay reconnects but not a Gateway restart. Answered handshake ids are remembered through the 5-minute freshness window, so a replayed handshake gets no second answer.

## Pairing and devices

The commands run in their own process and reach the running plugin through Gateway methods (`yorozu.pair.begin`, `yorozu.devices.list`, `yorozu.devices.remove`, scope `operator.admin`), so the Gateway must be running with the channel connected. Each takes the usual Gateway options (`--url`, `--port`, `--token`, `--timeout`).

```sh
openclaw yorozu pair                  # QR, yorozu://pair link and host fingerprint
openclaw yorozu devices               # id, name, paired at
openclaw yorozu devices remove <id>   # the id, or a unique start of it
```

- **pair**: the plugin asks the relay for a one-time join token (`mint`, 10 minutes) and makes a 32-byte secret, kept in memory with the token's expiry. The QR carries `https://yorozu.yumi.to/pair#<query>`; the link is `yorozu://pair?<query>` with the same query ([contract](../../docs/ios-relay-contract.md#pairing)). The fingerprint is the one the app shows. Output goes straight to stdout, since OpenClaw's console capture redacts key- and token-like text.
- **Joining**: the relay spends the token; the plugin adds the device (its two keys, then its model from `peer_info`) when the handshake's `helloProof` matches a pending secret, and drops that secret. A reused token is refused by the relay (`unknown token`), an expired one too (`expired token` or `unknown token`); a spent or expired secret behind a fresh token is refused by the plugin, which revokes the device at the relay. A Gateway restart forgets pending secrets: run `pair` again.
- **remove**: the row goes, the device's session is dropped and the relay gets `revoke`, which forgets the device and closes its sockets now. If the relay is unreachable at that moment, the next registration's `devices` list does the same.

## Conversations

`src/conversation.ts`. Every paired device is the same channel peer, `owner`, so every conversation shows on every device.

- **In**: a device's `message` is answered `delivered` at once (again for a repeated `messageId`, which is not run twice) and runs one agent turn (`runChannelInboundEvent`) in the session `agent:<agent>:yorozu:direct:owner:thread:<convId>`, `<agent>` from `channels.yorozu.agent`. Text is limited only by the relay's 1 MiB frame. Slash commands go through as text: `/new` resets that conversation's session only.
- **Out**, to every device with a live session: `run_started` when the run begins, `typing` while it runs (repeated every 8 s), `tool` per tool call (name and `running`/`done`/`failed`), then the reply, one `reply` per chunk of `textChunkLimit` characters. A failed run sends `error run_failed`. Nothing is queued for devices that are offline; the transcript keeps the reply, and `history` serves it on reconnect.
- **Cron**: a job with `delivery: { mode: "announce", channel: "yorozu", to: "owner", threadId: "<convId>" }` delivers into that conversation through the outbound adapter (`sendText`), and its text is mirrored into that session's transcript once the session exists. `openclaw cron add --thread-id` takes only Telegram's numeric ids, so such a job is made with the agent's cron tool or `cron.add`.
- **History** (`src/history.ts`): `conv_list` and `history` requests are answered to the asking device only, from the session store and the transcript in the agent's SQLite store (`listSessionEntries`, `getSessionEntry`, `loadTranscriptEventsSync`, `readTranscriptStatsSync`), never through `chat.history`, which truncates. A session's transcript is turned into items once per change and kept for the 8 most recent sessions. Live replies take their ids from the transcript message they came from, so a device does not show them twice after a page ([contract](../../docs/ios-relay-contract.md#history-conv_list-and-history)).
- **Titles, rename, archive, delete** (`src/sessions.ts`, #428): after a conversation's first turn the plugin asks OpenClaw's `generateConversationLabel` (the agent's `utilityModel`, then its primary model) for a title of its first message and writes it as the session's `displayName`; core titles only Control UI, iOS-node and node sessions itself. A device's `conv_patch` renames (the session's `label`, which wins over `displayName`; empty clears it), archives or unarchives (`archivedAt`), or deletes: archive first, then `deleteSessionEntry` with the transcript moved to the deleted-transcript archive, as `sessions.delete` does, and the read cursor dropped. The plugin watches session-entry changes (`subscribeSessionChanges`) and sends every device a `conv_update` when a conversation's title or archive state changed, whoever changed it; `conv_list` carries both ([contract](../../docs/ios-relay-contract.md#titles-conv_patch-and-conv_update)). Push previews take the title too.
- **Automations tab** (`src/cron.ts`, #432; Crons until 2026-10-17): a device's `cron_list` is answered to that device with every job of `channels.yorozu.agent` (disabled ones too): name, schedule and its English wording, next and last run, last status and error, and the Yorozu conversation it delivers into. It reads the cron store with `loadCronStore` (`openclaw/plugin-sdk/cron-store-runtime`), since `cron.list` is a Gateway RPC an untrusted plugin cannot call ([docs/openclaw-channel.md](../../docs/openclaw-channel.md), Q5). Read-only: changes go through the agent ("Edit in chat"), which needs the owner authority below.
- **Push** (`src/push.ts`, `src/relay.ts`, #431): one `notify` per finished reply, to every paired device except one whose live session has that conversation open or the app in front (`foreground.active`), and except devices whose push is off. The plugin remembers which devices it alerted per conversation; a `read_cursor` that reads it sends those (but the reader) a silent `notify` of class `sync`, which wakes them to clear the alert ([contract](../../docs/ios-relay-contract.md#push)). `sync` needs the relay from #447.
- **Retries** (`src/retry.ts`): a run that fails for a moment before any reply or tool (a plugin reload draining it, an overloaded or rate-limited model) runs again after 5 s, 15 s, 30 s, 60 s and 120 s instead of sending `error run_failed`; only the last failure is shown. The message waits in the keyed state store (namespace `retry`), so the generation that replaces this one on a reload runs it. Core keeps its inbound dedupe claim for a failure that is not safe to replay, which drops such a retry.
- **Pins** (`src/sessions.ts`): `conv_patch {pinned}` sets or clears the session entry's `pinnedAt`, as `sessions.patch` does, and archiving clears it; `conv_list` and `conv_update` carry it ([contract](../../docs/ios-relay-contract.md#titles-conv_patch-and-conv_update)).
- **Settings** (`src/relay.ts`): a device's `device_list` is answered with the paired devices (key, model, paired at, push, which one is asking); `device_patch` turns a device's push on or off (`push` in its allowlist row) or removes it as `devices remove` does ([contract](../../docs/ios-relay-contract.md#settings-device_list-and-device_patch)). `peer_info` carries the agent and the OpenClaw version for the client to show. A device's `pair_invite` is answered with a fresh one-time pairing code, as `openclaw yorozu pair` makes, so a paired device can add another away from the host ([contract](../../docs/ios-relay-contract.md#adding-a-device-pair_invite)).
- **Owner authority**: OpenClaw treats Yorozu turns as non-owner, so owner-only tools (`automations` for cron edits, `sessions`, `gateway`, `nodes`) are denied in them, until the owner adds `"yorozu:owner"` to `commands.ownerAllowFrom`.

## Trying it without the main Gateway

An OpenClaw profile keeps its own state, config and port (`~/.openclaw-<name>`), so the plugin can run next to the owner's Gateway without touching it. From the repository root:

```sh
openclaw --profile yorozu-dev config set gateway.mode local
openclaw --profile yorozu-dev plugins install --link plugins/openclaw-yorozu --force --accept-capabilities
openclaw --profile yorozu-dev gateway run --port 19422     # foreground; Ctrl-C stops it
openclaw --profile yorozu-dev channels status              # another terminal
openclaw --profile yorozu-dev yorozu pair
```

Use `gateway run`, never `gateway install`, which would add a login service for the profile.

## Config

Everything under `channels.yorozu` is optional:

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | `false` stops the channel |
| `agent` | `main` | Agent that answers Yorozu conversations |
| `relayUrl` | `wss://relay.yumi.to` | Relay the apps and the plugin meet on |
| `mediaMaxMb` | `8` | Attachment limit, both ways |
| `textChunkLimit` | OpenClaw's (4000) | Longest reply chunk, in characters |

## Typecheck

Types come from the OpenClaw source checkout behind the `openclaw` command. Link it once (`node_modules/` is git-ignored), then run its compiler:

```sh
cd plugins/openclaw-yorozu
mkdir -p node_modules
ln -s "$(dirname "$(realpath "$(command -v openclaw)")")" node_modules/openclaw
node_modules/openclaw/node_modules/.bin/tsc -p . | grep -E '^(index|setup-entry|src/)'
```

No output means the plugin typechecks. The filter drops errors inside the OpenClaw checkout itself, which appear when its generated database types (`.artifacts/kysely`) have not been built.
