# openclaw-yorozu

OpenClaw channel plugin for Yorozu (#415). The Yorozu apps reach the Gateway through this channel. The `yorozu` channel holds the host keys and the relay connection: it registers as the host of its relay room, redials with backoff, and answers wire v3 handshakes ([docs/ios-relay-contract.md](../../docs/ios-relay-contract.md); `src/wire.ts`, `src/envelope.ts`) from allowlisted devices. Pairing and message handling are not there yet. SDK facts behind it are in [docs/openclaw-channel.md](../../docs/openclaw-channel.md).

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
- **Device allowlist** (`src/devices.ts`): rows in the plugin's keyed state store (`<stateDir>/state/openclaw.sqlite`, namespace `devices`, keyed by the device's Ed25519 key), through `getDevice`, `listDevices`, `putDevice` and `removeDevice`. A handshake is answered only when the device's Ed25519 key and the X25519 key its handshake authenticates both match a row. The list is read on every handshake and announced to the relay (`devices`) on every registration, so the relay lets only listed devices rejoin.
- **Sessions** (`src/relay.ts`): in memory, one per device; they survive relay reconnects but not a Gateway restart. Answered handshake ids are remembered through the 5-minute freshness window, so a replayed handshake gets no second answer.

## Trying it without the main Gateway

An OpenClaw profile keeps its own state, config and port (`~/.openclaw-<name>`), so the plugin can run next to the owner's Gateway without touching it. From the repository root:

```sh
openclaw --profile yorozu-dev config set gateway.mode local
openclaw --profile yorozu-dev plugins install --link plugins/openclaw-yorozu --force --accept-capabilities
openclaw --profile yorozu-dev gateway run --port 19422     # foreground; Ctrl-C stops it
openclaw --profile yorozu-dev channels status              # another terminal
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
