# Setup

How to put Yorozu on an OpenClaw Gateway, pair a device and chat, plus what building the client needs. Run the OpenClaw commands below on the computer that runs the Gateway, from the repository root of the main checkout. The parts are described in [architecture.md](architecture.md), and the plugin's behaviour in [its README](../plugins/openclaw-yorozu/README.md).

## Tools

| Need | Version | Notes |
|---|---|---|
| OpenClaw | 2026.9.8 or later (`peerDependencies` in `plugins/openclaw-yorozu/package.json`) | The `openclaw` CLI on `PATH` and a running Gateway. The Gateway loads the plugin's TypeScript from source; there is no build step. |
| Xcode | 27 (CI uses 27.1) | Builds the client (`apps/ios`) and `packages/YorozuWire`. |
| Tuist | pinned in `mise.toml` | Install with `mise install`. The generated Xcode project and workspace are gitignored. |
| Upload tools | system | `scripts/upload_ios.sh` also uses `openssl`, `curl`, `jq`, `awk` and `xxd`. |

## 1. Install the plugin

```sh
openclaw plugins install --link plugins/openclaw-yorozu --force --accept-capabilities
openclaw gateway restart
openclaw channels status
```

- `--link` loads the plugin from this directory, and code changes load on the next Gateway restart. Link from a checkout that stays, not from a worktree that will be removed.
- `--force` accepts a source that is not on ClawHub. `--accept-capabilities` gives the capability consent that the install otherwise stops to ask for.
- No `channels.yorozu` entry is needed, because every key has a default ([Config](#2-config)).
- On first start the plugin makes its host keys. The Gateway log shows `yorozu started (agent <agent>, room <room id>)`, then `yorozu: registered at relay, room <room id>`, and `openclaw channels status` shows the Yorozu channel connected.
- The Mac app also carries a copy of the plugin at `Yorozu.app/Contents/Resources/openclaw-channel`. A Gateway linked there runs the plugin version of the installed app.

The `openclaw yorozu` commands reach the running plugin through Gateway methods, so the Gateway must be running with the channel connected. They accept the usual Gateway client options (`--url`, `--port`, `--token`, `--password`, `--timeout`).

To try the plugin without touching a Gateway in use, run it in an isolated OpenClaw profile ([plugin README](../plugins/openclaw-yorozu/README.md#trying-it-without-the-main-gateway)).

## 2. Config

Every key under `channels.yorozu` is optional:

| Key | Default | Meaning |
|---|---|---|
| `channels.yorozu.enabled` | `true` | `false` stops the channel |
| `channels.yorozu.agent` | `main` | The agent that answers every Yorozu conversation, and whose cron jobs the Automations tab lists |
| `channels.yorozu.relayUrl` | `wss://relay.yumi.to` | The relay that the plugin and the apps meet on. It goes into the pairing link. |
| `channels.yorozu.mediaMaxMb` | `agents.defaults.mediaMaxMb`, else 8 | Attachment size limit, both ways |
| `channels.yorozu.textChunkLimit` | 4000 | Longest reply chunk, in characters |

```sh
openclaw config set channels.yorozu.agent <agent id>
```

The plugin declares `channels.yorozu` as its reload prefix, so OpenClaw restarts the channel when that config changes. Changing `relayUrl` moves the host to another relay, so every device has to pair again.

### Owner-only tools

OpenClaw treats a Yorozu turn as a non-owner sender, so its owner-only agent tools are denied. That includes `automations`, which the Automations tab's "Edit in Chat" needs. To give Yorozu turns owner authority, add `yorozu:owner` to `commands.ownerAllowFrom` and keep the entries already there:

```sh
openclaw config get commands.ownerAllowFrom
openclaw config set commands.ownerAllowFrom '[<existing entries>, "yorozu:owner"]' --strict-json
```

This gives every paired device the owner's authority over the agent.

### OpenClaw updates

Yorozu does not update OpenClaw. OpenClaw's own auto-update does it: when the Gateway is idle, it drains running turns, updates, restarts and checks the result, and rolls back if that fails. Meanwhile the apps show the Gateway as offline. Auto-update needs both of these:

- `update.auto.enabled` set to `true` (it is off by default), with `update.checkOnStart` not `false` and `OPENCLAW_NO_AUTO_UPDATE` not set:

  ```sh
  openclaw config set update.auto.enabled true
  ```

- The Gateway running as a managed service (launchd, systemd or a Scheduled Task). A Gateway started in a terminal only logs that an update is available:

  ```sh
  openclaw gateway install
  ```

If either is missing, the plugin posts a notice into the most recent conversation after the Gateway starts. It posts it again only when what is missing changes. After an update, it posts `Updated OpenClaw <old> → <new>` there once ([plugin README](../plugins/openclaw-yorozu/README.md#gateway-notices-srcupdatests)). OpenClaw's own guide: `docs/install/updating/automatic-updates.md` in the OpenClaw source.

### Models

Yorozu has no model settings of its own; it uses the configured agent's models. Titles come from OpenClaw's title generator, which uses the agent's utility model first and then its primary model. Attachments reach the model as media, so pictures need a model that accepts image input.

## 3. Install a client

- **iPhone, iPad**: the Yorozu app from TestFlight or the App Store ([release.md](release.md#ios-and-ipados-testflight)).
- **Mac**: `scripts/build_native.sh` builds the client into `/Applications/Yorozu.app` ([release.md](release.md#mac-local-build)).

The app and the plugin speak the same wire; old clients keep working ([contract](ios-relay-contract.md#frames)).

## 4. Pair a device

```sh
openclaw yorozu pair
```

The command prints a QR code, a `yorozu://pair?…` link, the host fingerprint and the expiry time. The code works for one device, within 10 minutes, and only until the next Gateway restart.

1. In the app, on "Pair with your host", do one of these:
   - On iPhone or iPad, tap Scan QR Code and scan the code.
   - On any device, paste the link (or the https link the QR encodes) with Paste, or type it into "Pairing link" and tap Pair.
2. The app asks "Pair with this host?" and shows the host key. Pair only if it matches the fingerprint the command printed.
3. Pairing is done when the conversation list appears and `openclaw yorozu devices` lists the device by its model name. The app then asks to allow notifications.

**From a paired device:** Settings › Add a Device… makes a fresh pairing code on the host and shows it as a QR code and a link.

**A new Mac from a paired iPhone or iPad:** the Mac's pairing screen shows a code, which changes every 10 minutes.

1. On the iPhone or iPad, open Settings › Add a Device › Scan a Mac's Code (or point the Camera at the code) and tap Add.
2. On the Mac, check that the host key matches and click Pair.

Pair each device separately; all of them see the same conversations. At most 16 devices can be paired: a 17th replaces the oldest.

### Try demo data without a host

On the pairing screen, enter `YOROZU-DEMO` in **Pairing link** and tap **Pair**, or scan a QR code containing that text. Surrounding whitespace is ignored, and the code is case-sensitive. Demo mode shows sample conversations and automations and gives scripted replies; no host is involved. Settings › **Exit Demo** leaves it, and the existing pairing is kept.

For development, launch with `--demo` to start in demo mode directly. On the Mac, use a dev build with its own bundle id ([release.md](release.md#compile-checks)):

```sh
open -n .build/xcode-mac/Build/Products/Debug/YorozuIOS.app --args --demo
```

On an iOS Simulator with the app installed, run `xcrun simctl launch <udid> to.yumi.yorozu.ios --demo`.

## Devices

```sh
openclaw yorozu devices               # id, name, paired at
openclaw yorozu devices remove <id>   # the id, or a unique start of it
```

`remove` takes the device off the allowlist and tells the relay to forget it and close its sockets. The app then shows "Removed from the host". In the app, Settings lists the paired devices, can turn push on or off for each, and can remove other devices. Settings › Unpair This Device removes this device on the host and deletes its keys and cache.

## Self-hosted relay

The plugin and the apps use the public relay `wss://relay.yumi.to` unless `channels.yorozu.relayUrl` says otherwise. To run your own, use either form of `apps/relay` ([its README](../apps/relay/README.md)):

- **Cloudflare Worker**: in `apps/relay/wrangler.toml`, replace the `relay.yumi.to` route with a domain in your own Cloudflare account, then run `pnpm --filter @yorozu/relay run deploy`.
- **Docker** (Node, keeps everything in memory):

  ```sh
  docker build -f apps/relay/Dockerfile -t yorozu-relay .
  docker run -d --restart unless-stopped -p 8787:8787 yorozu-relay
  ```

  Put it behind a TLS proxy. The apps accept only `wss://`, except `ws://` to `localhost`.

Then point the plugin at it and pair every device again, because the pairing link carries the relay:

```sh
openclaw config set channels.yorozu.relayUrl wss://relay.example.com
openclaw yorozu pair
```

What a self-hosted relay doesn't do:

- **Push:** it can't send push. APNs pushes need the app developer's key, so there are no notifications while the app is closed. The Mac never gets push anyway.
- **Mac pairing codes:** a new Mac's pairing code still goes through the public relay's one-time mailbox. Only the invite link passes there; conversations stay on your relay.
- **Restarts:** the Docker relay loses buffered frames on restart. Devices reconnect by themselves.

## Push notifications

- The relay sends the APNs pushes. It needs the Worker secrets `APNS_KEY_ID`, `APNS_TEAM_ID` and `APNS_KEY_P8` (`apps/relay/src/apns.ts`). Without them, the relay still forwards frames but wakes nobody. To check the names only, run `wrangler secret list` from `apps/relay`.
- iOS uses production APNs. `UIBackgroundModes: remote-notification` lets the silent push reconnect a suspended app.
- The Mac gets no APNs. While the app runs, a reply in a conversation that is not in front posts a local notification.

## Data paths

Where each side keeps keys, state and cache: [architecture.md](architecture.md#data-on-each-side).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `plugins install` is refused with `Plugin config repair could not be inspected: yorozu …` | OpenClaw's state still holds a pending migration for an older plugin with the id `yorozu`. `openclaw doctor --fix` runs the pending repair, but it rewrites OpenClaw state and also acts on other plugins' pending migrations. |
| `channels status` shows Yorozu `recovering` with `unable to get local issuer certificate` | Node cannot verify the relay's TLS certificate because its OpenSSL has no CA bundle. Restore that OpenSSL's CA bundle, then run `openclaw gateway restart`. |
| `channels status` shows `recovering` with another error | The relay is unreachable. The plugin redials with backoff (up to 30 s) and registers again by itself. |
| The channel stops with `yorozu host key file is malformed` | The host key file is damaged. Restore it from a backup. Deleting it makes a new room, and every device has to pair again. |
| `Configured plugin load path is unavailable: …/plugins/openclaw-yorozu` | The linked directory is gone (for example, a removed worktree). Install again with `--link` from a checkout that exists. |
| `OpenClaw does not know the command "yorozu"` | The plugin is not installed in this profile, or the Gateway has not been restarted since the install. |
| `openclaw yorozu pair` or `devices` cannot connect, or `pair` fails with `the yorozu channel is not connected to its relay` | The Gateway is not running, or the channel is not connected. Check `openclaw channels status`. For a non-default port or a remote Gateway, pass `--port`, or `--url` with `--token`. |
| The app shows "Couldn’t pair", or "Removed from the host" right after pairing | The relay refused the token (`unknown token` or `expired token`: already used, or older than 10 minutes), or the plugin no longer holds the pairing secret (used, expired, or the Gateway restarted). Run `openclaw yorozu pair` again. |
| The app says "Update required" | The client and the plugin share no protocol version. Update the older side. |
| "Edit in Chat" or session tools are refused by the agent | `yorozu:owner` is not in `commands.ownerAllowFrom` ([Owner-only tools](#owner-only-tools)). |
