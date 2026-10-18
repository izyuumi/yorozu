# Setup

How to put Yorozu on an OpenClaw Gateway, pair a device and chat, plus what building the client needs. Every OpenClaw command below runs on the computer that runs the Gateway, from the repository root of the main checkout. The parts are described in [architecture.md](architecture.md).

## Tools

| Need | Version | Notes |
|---|---|---|
| OpenClaw | 2026.9.8 or later (`peerDependencies` in `plugins/openclaw-yorozu/package.json`) | The `openclaw` CLI on `PATH` and a running Gateway. The plugin is TypeScript loaded by the Gateway from source: no build step. |
| Node.js | what the OpenClaw build needs | Runs the Gateway, and with it the plugin. Its TLS needs a CA bundle to reach the relay ([Troubleshooting](#troubleshooting)). |
| Xcode | 27 | Builds the client (`apps/ios`) and `packages/YorozuWire`. |
| Tuist | pinned in `mise.toml` | `mise install`. Generated `.xcodeproj` / `.xcworkspace` are gitignored; `apps/ios/Tuist.swift` lets generation work in a git worktree. |
| Upload tools | system | `scripts/upload_ios.sh` also uses `openssl`, `curl`, `jq`, `awk` and `xxd`. |

## 1. Install the plugin

```sh
openclaw plugins install --link plugins/openclaw-yorozu --force --accept-capabilities
openclaw gateway restart
openclaw channels status
```

- `--link` loads the plugin from this directory, so link it from a checkout that stays (the main checkout, never a worktree that will be removed). Code changes there load on the next Gateway restart.
- `--force` confirms a source that is not on ClawHub; `--accept-capabilities` gives the capability consent the install otherwise stops for.
- The install records the plugin, enables it under `plugins.entries.yorozu` and adds it to `plugins.allow` when an allowlist is set. It needs no `channels.yorozu` entry: every key has a default ([Config](#2-config)).
- v1's channel plugin (`packages/openclaw-channel` on `main`) uses the same id `yorozu`. If it is installed, `openclaw plugins uninstall yorozu` first; if the install is refused anyway, see [Troubleshooting](#troubleshooting).
- Done when `openclaw channels status` lists `Yorozu default: enabled, configured, running, connected`. The Gateway log shows `yorozu started (agent <agent>, room <room id>)`. On first start the plugin makes its host keys; they never change afterwards.

The Gateway must keep running for everything below: the `openclaw yorozu` commands reach the live plugin through Gateway methods (scope `operator.admin`) and take the usual Gateway options (`--url`, `--port`, `--token`, `--password`, `--timeout`).

To try the plugin without touching a Gateway in use, run it in an isolated OpenClaw profile ([plugin README](../plugins/openclaw-yorozu/README.md#trying-it-without-the-main-gateway)).

## 2. Config

Everything under `channels.yorozu` is optional. A change to `channels.yorozu` restarts the channel without a Gateway restart.

| Key | Default | Meaning |
|---|---|---|
| `channels.yorozu.enabled` | `true` | `false` stops the channel |
| `channels.yorozu.agent` | `main` | The one agent that answers every Yorozu conversation and whose crons the Crons tab lists |
| `channels.yorozu.relayUrl` | `wss://relay.yumi.to` | Relay the plugin and the apps meet on; it goes into the pairing link, so devices follow it |
| `channels.yorozu.mediaMaxMb` | `8` | Attachment limit, both ways |
| `channels.yorozu.textChunkLimit` | OpenClaw's (4000) | Longest reply chunk, in characters |

```sh
openclaw config set channels.yorozu.agent <agent id>
```

Changing `relayUrl` moves the plugin to another relay: devices paired on the old one pair again.

### Owner-only tools

OpenClaw treats a Yorozu turn as a non-owner sender, so owner-only agent tools (`automations` for cron edits, `sessions`, `gateway`, `nodes`) are denied in it. The Crons tab's "Edit in Chat" needs `automations`. To give Yorozu turns owner authority, the owner adds `yorozu:owner` to `commands.ownerAllowFrom`, keeping the entries already there:

```sh
openclaw config get commands.ownerAllowFrom
openclaw config set commands.ownerAllowFrom '[<existing entries>, "yorozu:owner"]' --strict-json
```

That is the owner's decision: it gives every paired device the owner's authority over the agent.

### Models

Yorozu uses the configured agent's models; it has no model settings of its own. Titles come from OpenClaw's title generator on the agent's utility model: `agents.entries.<agent>.utilityModel`, else `agents.defaults.utilityModel`, else the primary provider's small model or the primary model. Attachments reach the model as media, so pictures need a model whose input takes images.

## 3. Install a client

- **iPhone, iPad**: the Yorozu app from internal TestFlight ([release.md](release.md#ios-and-ipados-testflight)).
- **Mac**: `scripts/build_native.sh` builds the client into `/Applications/Yorozu.app` ([release.md](release.md#mac-client)).

The app speaks wire v3 only. A device paired with the old Mac host (wire v2) or with v1 pairs again.

## 4. Pair a device

```sh
openclaw yorozu pair
```

It prints a QR code, a `yorozu://pair?…` link, the host fingerprint (`XXXX XXXX XXXX XXXX`) and the time it expires: one device, within 10 minutes, and before the next Gateway restart (pending pairings live in memory).

1. In the app, on "Pair with your host": on iPhone or iPad, tap Scan QR Code and scan it. On any device, copy the link (or the https link the QR encodes) and tap Paste, or paste it into "Pairing link" and tap Pair.
2. The app asks "Pair with this host?" with the host key. Compare it with the fingerprint the command printed; pair only if they match.
3. Done when the conversation list appears and `openclaw yorozu devices` lists the device by its model name. On iPhone and iPad the app then asks to allow notifications.

Pair each device separately; all of them see the same conversations. At most 16 devices: a 17th replaces the oldest.

### Try demo data without a host

On the pairing screen, enter `YOROZU-DEMO` in **Pairing link** and tap **Pair**, or scan a QR containing that exact text. Leading and trailing whitespace is ignored; the code is case-sensitive. There is no separate demo entry button.

Demo mode shows sample conversations, collapsed tool rows and Automations. Send a message to get a delayed, scripted whole reply; no model or OpenClaw host runs. A small Demo indicator appears in the chat list. Changes stay in memory and disappear when you choose **Exit Demo** in Settings. Existing pairing credentials are preserved. Files, uploads and real host or account actions are unavailable.

For development, launch the executable with `--demo` to enter directly, bypassing pairing, Keychain access, network connections, Mac migration and the updater. On the Mac, first build with a separate developer bundle id as described in [release.md](release.md#compile-checks), then run:

```sh
open -n .build/xcode-mac/Build/Products/Debug/YorozuIOS.app --args --demo
```

Do not run another Mac build with the installed app's bundle id. On an iOS Simulator with the app installed, use `xcrun simctl launch <udid> to.yumi.yorozu.ios --demo`.

## 5. Chat

- "+" starts a new conversation (a new OpenClaw thread session). Type and send with the send button; on the Mac ⌘Return sends and Return adds a line.
- Marks: ✓ sent (relay accepted), ✓✓ delivered (plugin received), read (agent run started); typing shows while the agent works; tool calls show as one collapsed row. Long replies arrive as several cards.
- `/new` resets the open conversation's session; other slash commands go to OpenClaw as typed.
- Files: the + menu in the composer, drag and drop, or Share › Yorozu on iOS; up to `mediaMaxMb`.
- Crons: the Crons tab lists the agent's jobs; "Edit in Chat" drafts a change for the agent to make ([Owner-only tools](#owner-only-tools)).

## Devices

```sh
openclaw yorozu devices               # id, name, paired at
openclaw yorozu devices remove <id>   # the id, or a unique start of it
```

`remove` drops the device from the allowlist and tells the relay to forget it and close its sockets; the app then shows "Removed from the host". In the app, Host (the info button) › Unpair This Device deletes the keys and cache on that device only; remove it on the host too.

## Signing

| App | Bundle id | Signing |
|---|---|---|
| Client, iPhone and iPad | `to.yumi.yorozu.ios` | Team `AN5KM8QGEF`, automatic signing; Xcode issues the distribution certificate and App Store profiles during `upload_ios.sh` with the App Store Connect key. Entitlements in `apps/ios/Project.swift`: `aps-environment: production`, `applinks:yorozu.yumi.to`, `keychain-access-groups` (the app's own group, then `<team>.to.yumi.yorozu.notifications`), App Group `group.to.yumi.yorozu`. |
| Notification service extension | `to.yumi.yorozu.ios.notification-service` | Same team and version pair; Keychain group `<team>.to.yumi.yorozu.notifications`, which holds only the push-preview key. |
| Share extension | `to.yumi.yorozu.ios.share` | Same team and version pair; App Group `group.to.yumi.yorozu`. |
| Client, Mac | `to.yumi.yorozu.ios` (one multiplatform target) | `build_native.sh`: Developer ID Application with hardened runtime when that identity is in the login Keychain, else ad hoc; either way without entitlements, since they need a macOS provisioning profile for this bundle id that does not exist. The keys go to the login Keychain, which may ask for access again after a rebuild. |

## Push notifications

- The relay sends APNs pushes; it needs the Worker secrets `APNS_KEY_ID`, `APNS_TEAM_ID` and `APNS_KEY_P8` (`apps/relay/src/apns.ts`). A relay without them forwards frames but wakes nobody. Check names only, from `apps/relay` on `main`: `wrangler secret list`.
- iOS: TestFlight builds use production APNs (`aps-environment: production`), and `UIBackgroundModes: remote-notification` lets the silent push reconnect a suspended app. The app asks for alerts, sounds and badges after pairing and at launch while paired.
- Mac: no APNs. While the app runs, a reply in a conversation that is not in front posts a local notification.

## App Store Connect credentials

`upload_ios.sh` needs `ASC_KEY_ID` and `ASC_ISSUER_ID` in the environment and reads the private key from `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8` (mode `600`), or from `ASC_KEY_PATH` when set. The key stays outside the repository. `BUILD=<n>` sets the build number for both scripts.

## Data paths

Where each side keeps keys, state and cache, and how each is protected: [architecture.md](architecture.md#data-on-each-side).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `plugins install` is refused with `Plugin config repair could not be inspected: yorozu. Repair the plugin's Doctor artifact, then retry the update.` | OpenClaw's state still holds a pending upgrade migration for an older plugin that had the id `yorozu` (such as v1's channel), and that plugin has nothing for Doctor to inspect. `openclaw doctor --fix` runs the pending repair; it rewrites OpenClaw state and also acts on other plugins' pending migrations. `openclaw plugins uninstall yorozu` before the install removes the old install record but is not known to clear the row. On the owner's Gateway this is the owner's choice ([status.md](status.md#open-items)). |
| `plugins install` fails with `EPIPE`, or every plugin install fails | The Gateway is still running on a Node binary that a package upgrade has since replaced. `openclaw gateway restart`, then install again. |
| `channels status` shows Yorozu `recovering` with `unable to get local issuer certificate` | Node cannot verify the relay's TLS certificate: the OpenSSL that Node uses has no CA bundle (it can go missing after an OpenSSL package upgrade). Restore the CA bundle of that OpenSSL installation (for a Homebrew one, rerun its formula's post-install step), then `openclaw gateway restart`. |
| `channels status` shows `recovering` with another error | The relay is unreachable; the plugin redials with backoff up to 30 s and registers again by itself. |
| `Configured plugin load path is unavailable: …/plugins/openclaw-yorozu` | The directory the plugin was linked from is gone (a removed worktree). Install again with `--link` from the main checkout. |
| `OpenClaw does not know the command "yorozu"` | The plugin is not installed in this profile, or the Gateway has not been restarted since the install. |
| `openclaw yorozu pair` or `devices` fails to connect | The Gateway is not running or the channel is not connected; check `openclaw channels status`. For a non-default port or a remote Gateway pass `--port` or `--url` and `--token`. |
| The app shows "Couldn’t pair", or "Removed from the host" right after pairing | The relay refused the token (used, or older than 10 minutes), or the plugin no longer holds the pairing secret (spent, expired, or the Gateway restarted since `pair`). Run `openclaw yorozu pair` again and pair with the new code. |
| The app says "Update required" | Client and plugin share no wire protocol version. Update the older side. |
| "Edit in Chat" or session tools are refused by the agent | `yorozu:owner` is not in `commands.ownerAllowFrom` ([Owner-only tools](#owner-only-tools)). |
| `openclaw message send --channel yorozu -t owner` fails | The plugin has no messaging target resolver yet ([status.md](status.md#open-items)). Agent replies and cron deliveries are unaffected. |
| `openclaw cron add --thread-id <convId>` is rejected | That flag takes only Telegram's numeric ids. Make the job with the agent's cron tool, or `cron.add` with `delivery: {channel: "yorozu", to: "owner", threadId: "<convId>"}`. |
