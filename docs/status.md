# Status

Current state of `main`. Version: `version.txt`. Product decisions: [OWNER_DECISIONS.md](../OWNER_DECISIONS.md). Release flow: [release.md](release.md).

## Implemented

- **Plugin** (`plugins/openclaw-yorozu`): host keys in the OpenClaw credentials store; relay connection with reconnect; Noise IK handshakes from allowlisted devices; `openclaw yorozu pair`, `devices`, `devices remove`. Text in and out through one OpenClaw thread session per conversation, with `run_started`, typing, `tool` rows and chunked whole replies; cron delivery into a conversation; history from the Gateway transcripts (`conv_list`, `history`); titles, rename, archive, delete; read cursors; attachments both ways (default limit 8 MB, `channels.yorozu.mediaMaxMb`); one sealed push per finished reply; read-only cron list; device list and settings; `pair_invite` for adding a Mac.
- **Wire** (`packages/YorozuWire`, plugin `src/wire.ts`/`src/envelope.ts`): [contract](ios-relay-contract.md); the plugin accepts both frame formats.
- **Relay** (`apps/relay`): Cloudflare Worker, one Durable Object per room, one-time pairing mailboxes, APNs sender, connect rate limit; deploys on merge after its tests.
- **Client** (`apps/ios`, one target for iPhone, iPad and native SwiftUI Mac): pairing by QR scan or pasted link with fingerprint check; a new Mac shows a code that a paired iPhone or iPad scans; conversation list, chat, outbox and cache; unread badges and read marks synced; attachments, paste and camera; share extension and notification service extension (iOS); two conversations side by side (`Pair.swift`); read-only Automations with "Edit in Chat"; Settings (tabs General, Devices, Host and Updates on the Mac, each sized to its content; one list on iPhone and iPad) with paired devices; Add a Device shows when the new device has paired; App Shortcuts; interface in English, Japanese, Simplified and Traditional Chinese, Korean, Spanish, French, German and Brazilian Portuguese (the last seven machine-translated); offline demo (`YOROZU-DEMO` in the pairing field, or `--demo`).
- **Mac app**: Developer ID signed, notarized DMG with Sparkle updates (stable and beta feeds), bundled plugin copy.
- **iPhone and iPad updates**: once a day the App Store build looks up its newest App Store version; a newer one shows a dismissible row at the top of the chat list that opens the App Store. Not on TestFlight or in demo mode.
- **Website** (`apps/web`): Astro site with pairing link page, AASA, and Mac download and update-feed redirects.
- **CI**: PR compile checks and relay tests; Mac beta per merge, promotion to stable on a `version.txt` bump; TestFlight upload per merge; web and relay deploy per merge ([release.md](release.md#ci)).

## Open items

Pending owner decisions or owner-only checks. Each row keeps its current default.

| Item | Default until the owner decides |
|---|---|
| **Pending: `commands.ownerAllowFrom` += `"yorozu:owner"`** ([setup.md](setup.md#owner-only-tools)). Without it Yorozu turns lose owner-only tools, so "Edit in Chat" cannot change a cron job. | Not set: Yorozu turns are non-owner. |
| **Pending: on-device checks**: QR scan with the camera; pairing on a phone; cache unreadable while locked; push (one per reply, title and first line, tap opens the conversation, none for the conversation in front, cron pushes, preview while locked after first unlock); Mac local notifications; Mac Dock and iOS badge; swipe and context-menu marks; pull to refresh on Crons; "Edit in Chat" with a real model; a real vision model on attachments; Mac drag and drop and ⌘Return; VoiceOver; adding a Mac by scanning its code. | Unchecked. |
| **`openclaw message send --channel yorozu -t owner`**: the plugin defines no `messaging.targetResolver` (`src/channel.ts`). | Agent replies and cron deliveries work; CLI sends to Yorozu are not supported. |
| **Crons tab reads a private SDK path**: `loadCronStore` from `openclaw/plugin-sdk/cron-store-runtime` (`src/cron.ts`), which resolves on a source install; a packaged OpenClaw may withhold it from linked plugins. | Keep it; if it breaks, `cron_list` answers `error` and the switch is a loopback Gateway client ([openclaw-channel.md](openclaw-channel.md)). |
| **Mac signing has no entitlements**: no macOS provisioning profile exists for the Mac bundle id, so `build_native.sh` and `release_mac.sh` sign without them: no APNs, associated domains, shared Keychain group or App Group on the Mac; keys live in the login Keychain. | Developer ID without entitlements. |
| **Pending: leftovers of the old host on the owner's Mac** (its data, Keychain items). | Kept until the owner approves cleanup. |

## Known limits

- Replies are whole messages, chunked by length; no streaming (`disableBlockStreaming`).
- The plugin sends only to devices with a live session; offline devices backfill from history on reconnect. A reply whose delivered text differs from its transcript text shows the transcript text in history.
- A Gateway restart drops live device sessions (devices re-handshake) and forgets pairing secrets not yet used.
- At most 16 paired devices (`MAX_DEVICES`, plugin and relay); adding one past that removes the oldest.
- An interrupted attachment upload starts over (partials are dropped after 30 minutes).
- `openclaw cron add --thread-id` accepts only numeric (Telegram) ids, so a job delivering into a Yorozu conversation is made with the agent's cron tool or `cron.add`.
- The plugin's keyed state (allowlist, read cursors) and OpenClaw's transcripts are not encrypted at rest beyond the disk's encryption.
- No push on the Mac; no mute; no voice notes.
