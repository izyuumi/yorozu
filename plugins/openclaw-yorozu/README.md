# openclaw-yorozu

OpenClaw channel plugin for Yorozu (#415). The Yorozu apps reach the Gateway through this channel. For now the `yorozu` channel only starts and stops; it has no relay connection or message handling yet. `src/wire.ts` and `src/envelope.ts` implement wire v3 (the Noise handshake, frames, boxes and envelope, [docs/ios-relay-contract.md](../../docs/ios-relay-contract.md)) and are not wired in. SDK facts behind it are in [docs/openclaw-channel.md](../../docs/openclaw-channel.md).

## Install

From the repository root:

```sh
openclaw plugins install --link plugins/openclaw-yorozu --force
openclaw gateway restart
openclaw channels status
```

`--link` points OpenClaw at this directory, so edits load on the next Gateway restart. `--force` confirms a source that is not on ClawHub. The install enables the plugin under `plugins.entries.yorozu` (and adds it to `plugins.allow` when an allowlist is set) and needs no `channels.yorozu` entry. The v1 channel (`packages/openclaw-channel` on `main`) uses the same plugin id `yorozu`; uninstall it first if it is installed.

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
