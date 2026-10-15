# Status

As of 2026-10-16. The #415 tracker (Yorozu as an OpenClaw channel) is built: every child issue #416–#432 is merged and closed, and this rewrite of the docs is #433. The secretary system and the Mac host are deleted (#426); their last status is in [history/secretary-status.md](history/secretary-status.md).

**Release 0.8.0** (2026-10-16, `projectx` after #454), internal only:
- Mac: `/Applications/Yorozu.app` rebuilt in place with `scripts/build_native.sh --restart`: the client (`to.yumi.yorozu.ios`) 0.8.0 (1), Developer ID signed, replacing the old host app. Launched to the v3 pairing screen.
- iPhone and iPad: TestFlight 0.8.0 (1), one upload with `scripts/upload_ios.sh --confirm`; App Store Connect reports it valid and in internal beta testing (Internal group only).
- Wire v3 is incompatible with 0.7.x: every device pairs again with `openclaw yorozu pair`, which needs the plugin installed in the owner's Gateway first ([Open items](#open-items)).
- Before the release, a Mac live check on an isolated profile found two client bugs (invisible composer text, a nested split view breaking the window after relaunch), fixed in #453 and checked on the Mac and both simulators.

## Evidence levels

Acceptance for this branch is compile plus manual checks (tests and CI are on hold). Each check below has one of these levels:

- **Source**: read against the OpenClaw source of the running build (2026.9.8), no live run.
- **Compile**: the plugin typechecks; `swift build --package-path packages/YorozuWire`; the client builds for `generic/platform=iOS`, `platform=macOS` and the iOS Simulator.
- **Isolated**: live on an isolated OpenClaw profile (its own state, config and port, the owner's Gateway untouched), against the deployed relay unless noted, with a local mock model and scratch wire devices, iPhone and iPad simulators, or the Mac client from derived data.
- **Owner**: on the owner's own Gateway with a real model, or on a physical device. None of these is done yet ([Open items](#open-items)).

## Done

| Issue (PR) | Shipped | Checked |
|---|---|---|
| #416 (#437) | [openclaw-channel.md](openclaw-channel.md): a `--link` channel plugin can hold the relay WebSocket itself, so no Mac bridge | Source |
| #417 (#434) | The channel decisions in OWNER_DECISIONS.md and the log | Docs |
| #418 (#435) | `apps/relay` copied from `main` for reference; no relay gap for v3 | Relay typecheck, `wrangler deploy --dry-run` |
| #419 (#436) | One multiplatform client target for iPhone, iPad and native SwiftUI Mac | Compile; Mac launch to the pairing screen |
| #420 (#438) | The plugin skeleton, installable with `--link` | Compile; Isolated: `channels status` running and connected, clean stop on Gateway stop and config reload |
| #421 (#439) | Wire v3: Noise IK handshake, frames, envelope, in Swift and TypeScript | Known-answer vectors reproduced byte for byte in both languages and against an independent Noise IK vector; negative checks (replay, reflection, stale time, wrong keys) |
| #422 (#440) | Host keys in the credentials store, the relay host loop, handshakes from allowlisted devices | Isolated: registration, reconnect with backoff through a killed and a frozen proxy, no keys in logs, key file `0600` and stable |
| #423 (#441) | `openclaw yorozu pair`, `devices`, `devices remove`; the allowlist | Isolated, scratch Swift device: join by link, reused and expired tokens refused, remove revokes at once |
| #424 (#442) | Text in and out through thread sessions; `delivered`, `run_started`, typing, `tool` rows, chunked replies; cron delivery into a conversation | Isolated, mock model, two scratch devices: separate sessions, `/new`, 12-chunk replies, dedupe, 700 KiB messages, cron delivery |
| #425 (#443) | Client on wire v3: pairing by scan or paste with fingerprint check, conversation list, chat, marks, outbox, cache | Isolated: Mac client and iPhone simulator paired and chatted; offline resend; iPad launch |
| #426 (#445) | The secretary system, the Mac host, wire v2 and the v2 client deleted; `build_native.sh` builds the client | Compile; the script's build line signed and verified (the script itself not run); Isolated: iOS simulator chat |
| #427 (#448) | History from the Gateway transcript, `conv_list` and `history` pages, client cache and backfill | Isolated, two simulators: a freshly paired device showed full history, resets, tool rows and cron replies, no duplicates |
| #428 (#450) | Generated titles, rename, archive and delete, synced to every device | Isolated, mock `utilityModel`, two simulators |
| #429 (#444) | Read cursor per conversation, unread badges, Mark as Read and Unread, synced | Isolated, two simulators and a scratch device |
| #430 (#451) | Attachments both ways up to 8 MB, share extension into a chosen conversation, ⌘Return on the Mac | Isolated, mock vision model, two simulators: photo and PDF up, image down, 9 MB refused, share sheet |
| #431 (#449) | One sealed push per finished reply, none to a device with that conversation in front; local notifications on the Mac | Isolated with a local relay recording each `notify` and fake device tokens; no real APNs |
| #432 (#446) | Read-only Crons tab with "Edit in Chat" | Isolated, two simulators: the list matched `openclaw cron list --all`; edits simulated with the CLI |

## Open items

| Item | Default until the owner decides |
|---|---|
| **Plugin install into the owner's Gateway.** The install is refused with `Plugin config repair could not be inspected: yorozu`: OpenClaw state holds a pending upgrade migration row for the old v1 plugin with the same id. Choices: `openclaw doctor --fix` (also acts on other plugins' pending rows), or `openclaw plugins uninstall yorozu` then retry (untested). | Not installed; every live check stays on isolated profiles. |
| **`commands.ownerAllowFrom` += `"yorozu:owner"`** ([setup.md](setup.md#owner-only-tools)). Without it Yorozu turns lose owner-only tools, so "Edit in Chat" cannot change a cron job. | Not set: Yorozu turns are non-owner. |
| **Relay PR #447 on `main`** (`notify` names the devices to alert). Backward compatible; needs the owner's merge and deploy. | Deployed relay alerts every device; the client hides a banner for the conversation on screen, but that device still gets the relay's fixed-text alert. |
| **On-device checks** (TestFlight build): QR scan with the camera; pairing acceptance on a phone; the cache unreadable while locked; push (one per reply, title and first line, tap opens the conversation, none for the conversation in front, cron pushes, preview while locked after first unlock); Mac local notifications; Mac Dock and iOS app badge; swipe and context-menu marks; pull to refresh on Crons; "Edit in Chat" with a real model; a real vision model on attachments; Mac drag and drop and ⌘Return live; VoiceOver. | Unchecked. |
| **`openclaw message send --channel yorozu -t owner` fails**: the plugin has no messaging target resolver (`messaging.targetResolver`) for `owner`. | Agent replies and cron deliveries work; CLI sends to Yorozu do not. |
| **Crons tab reads a private SDK path**: `loadCronStore` from `openclaw/plugin-sdk/cron-store-runtime`, which works on a source install. A packaged OpenClaw may withhold it from linked plugins. | Keep it; if it breaks, `cron_list` answers `error` and the switch is a loopback Gateway client ([openclaw-channel.md](openclaw-channel.md)). |
| **Mac client signing** has no entitlements (no provisioning profile for `to.yumi.yorozu.ios` on macOS): no APNs, no associated domains, no App Group, login-Keychain prompts after rebuilds. | Developer ID without entitlements via `build_native.sh`. |
| `OWNER_DECISIONS.md` still gives the Mac app v1's identity (`to.yumi.yorozu`); since #426 the Mac app is the client, `to.yumi.yorozu.ios`. Needs the owner's wording. | Code and docs follow `to.yumi.yorozu.ios`. |
| Leftovers of the old host on the owner's Mac (its data, Keychain items, ignored `apps/mac` build outputs in the main checkout). | Kept until the owner approves cleanup. |

## Roadmap

The owner has set nothing after #415. Named as later or out in the decisions: mute for pushes, voice notes, an agent picker (out), Mac distribution and Mac push, v1 → v2 migration (from #322).

## Known limits

- Replies are whole messages, chunked by length; no streaming.
- Devices that are offline get nothing queued; they backfill from history on reconnect. A reply whose delivered text differs from its transcript text (core strips some parts before delivery) shows the transcript text in history.
- A Gateway restart drops live device sessions (devices re-handshake by themselves) and forgets pairings not yet used.
- At most 16 paired devices; the 17th replaces the oldest.
- An interrupted attachment transfer starts over on the next session.
- `openclaw cron add --thread-id` takes only Telegram's numeric ids, so a job delivering into a Yorozu conversation is made with the agent's cron tool or `cron.add`.
- The plugin's keyed state (allowlist, read cursors) and OpenClaw's transcripts are not encrypted at rest beyond the disk's own encryption.
- No mute, no voice notes.
