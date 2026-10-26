# Owner decisions

The owner's decisions that are in force now, by area. Each line ends with the date it was made or last changed. The full log, superseded entries included, is [docs/history/decisions-log.md](docs/history/decisions-log.md).

When the owner makes or changes a decision, rewrite the line here so no two lines contradict, and append the entry to the log. Open questions and their defaults live in [docs/status.md](docs/status.md).

On 2026-10-15 the owner replaced the secretary system with Yorozu as an OpenClaw channel (tracking issue #415). The secretary-era decisions are superseded and kept in the log ([Superseded](#superseded)). Code and other docs still describe the secretary until the #415 build order removes it; where they disagree with this file, this file wins.

## Shape

- Yorozu is an OpenClaw chat channel, a peer of Signal or Telegram: a TypeScript channel plugin inside the owner's OpenClaw Gateway talks over the end-to-end-encrypted relay to Yorozu client apps on iPhone, iPad and Mac. OpenClaw runs the agent, sessions, memory and cron; Yorozu only carries messages, with a Signal-like UX. (2026-10-15)
- Yorozu runs nothing of its own: no routing, classification, workers, coding agents, memory, jobs, Hermes or cua. All of `Sources/ProjectXCore` engine code and the Mac host role go. (2026-10-15)
- No Mac host process. The OpenClaw channel plugin (`plugins/openclaw-yorozu`, TypeScript) holds the host keys and the relay connection itself. Fallback, only if the spike shows a plugin cannot: a Mac bridge app between Gateway and relay. (2026-10-15)
- One multiplatform SwiftUI client app for iPhone, iPad and Mac. Clients only; no host role anywhere in Swift. (2026-10-15)
- Wire protocol 3. Old wire types, store and engine are deleted, not flagged off. 0.5.0-beta installs migrate once in 0.9.0, carrying pairings over ([Upgrade from 0.5.0-beta](#upgrade-from-050-beta)); 0.4.0 and older are not upgraded. (2026-10-15, migration 2026-10-17)

## Conversations

- The client mirrors OpenClaw sessions, minimal. In scope: conversation list, open with history, send with replies arriving, new conversation, tool calls shown collapsed, attachments, push, read/unread marks, rename/archive/delete. Out: agent picker. (2026-10-15)
- Peer = the owner, not the device: all paired devices share one channel peer, so every conversation shows everywhere. Session key `agent:<agent>:yorozu:direct:owner:thread:<convId>` (thread-scoped sessions, as Telegram DM topics). (2026-10-15)
- One agent from plugin config (`channels.yorozu.agent`), default `main`. (2026-10-15)
- Only Yorozu conversations are listed; other channels' sessions are not. (2026-10-15)
- Compose (`square.and.pencil`, at the top trailing corner of the chat list, 2026-10-18; the window toolbar on the Mac) makes a new `convId` (new thread session). Inside a conversation the same button sits at the top trailing corner of its bar (2026-10-23), hidden while that conversation is still empty: on iPhone it opens the new conversation in place; on iPad and iPhone Duo open, a tap opens it in place and holding it offers New Conversation Beside (⌥⌘N), and with two side by side each pane has its own, opening into that pane. From iOS 27 it is pinned at the trailing edge, so iPhone Duo's side bars keep it right after Back instead of moving it to the overflow menu (2026-10-25). `/new` inside a conversation resets that session in place. Other slash commands pass through as text. (2026-10-17)
- Titles are generated automatically by OpenClaw's own title generator (`utilityModel`, as for Telegram DM topics). A manual rename (session `label`) overrides it. (2026-10-15)
- History: the Gateway transcript is the source of truth. Clients keep a local cache and backfill from the plugin on open/reconnect; new devices see full history. (2026-10-15)

## Status marks

- Outgoing: ✓ sent = relay accepted; ✓✓ delivered = plugin received and decrypted; read = agent run started. Typing indicator from run start until the reply. (2026-10-15)
- Unread mark on agent replies until opened on any device, a dot rather than a count: blue for unread replies, orange when a run failed (needs attention) (2026-10-17); read state syncs across devices; manual Mark as Read/Unread stays. The plugin stores the read cursor per conversation in its state dir. (2026-10-15)
- Replies arrive as whole messages, chunked by length (no edit-in-place streaming). (2026-10-15)

## Pairing and security

- A paired device can add another from Settings › Add a Device, away from the host: the plugin sends it the same one-time code over the relay (`pair_invite`), shown as a QR and a link. (2026-10-17)
- `openclaw yorozu pair` prints the pairing QR (plus the `yorozu://pair…` link) in the terminal. The QR carries relay URL, room id, host public key, one-time token and secret. Scanned devices join the plugin's allowlist. (2026-10-15)
- Crypto: Noise-style handshake (IK: the device knows the host static key from the QR) per connection for forward secrecy, over the existing primitives (X25519, HKDF-SHA256, ChaCha20-Poly1305, Ed25519 relay frames). (2026-10-15)
- Baseline: client cache under iOS Data Protection `complete`; client keys in Keychain, this-device-only, non-syncing; plugin keys in OpenClaw's credentials store, `0600`; push previews sealed; fingerprint shown on both sides at pairing. (2026-10-15)
- Transcripts on the Mac stay plaintext in OpenClaw's state (same trust model as every OpenClaw channel). (2026-10-15)

## Transport

- Relay only. The direct path (port 8738) is dropped. The plugin only makes an outbound connection; the Gateway opens no new port. (2026-10-15)
- The deployed relay also serves 0.4 and 0.5 installs; any relay change must stay backward compatible. (2026-10-15)
- The relay honours `notify.devices` and has a silent `sync` class (#447, merged on `main` and deployed for 0.9). (2026-10-17)
- The relay answers each client frame with `accepted` once it has forwarded it or stored it durably. Merged on `main` in #332 and deployed by the owner. (2026-10-09)

## Push and attachments

- One push per finished agent reply via the relay's `notify`, preview (title + first line) sealed per device. Cron output delivered into a conversation pushes the same way. No mute yet. (2026-10-15)
- No push to a device while the app is in front on it, per device; a minimal pill at the top shows a reply in another conversation instead (tap opens it, swipe up or 3 s dismisses, the newest replaces it), with an optional light haptic, on by default. (2026-10-17)
- Reading a conversation on any device removes its delivered notifications on the others: live over the socket, and through a silent `sync` push for devices whose app is closed. (2026-10-17)
- Attachments both ways (`sendMedia`), 8 MB limit (OpenClaw's `mediaMaxMb` default), sealed chunks under the relay's 1 MiB frame limit. Share extension stays, with a preview of the picture or file being sent; PDFs show their first page (2026-10-17). No voice notes yet. (2026-10-15)
- Pasting images and files into the chat input stages them as attachments. On iPhone and iPad, the composer's plus menu offers taking a photo in place. Move the plus glyph left within its full tap target so it stays close to the textarea without overlapping it. (2026-10-19) Styled text pastes as plain text, never as an attachment. (2026-10-23)

## Automations

- An Automations tab (ja 自動化, `clock` icon) next to Chats: all cron jobs on the configured agent, disabled ones greyed; name, human schedule, next run, last status (error on tap). Code and wire names stay `cron`. (2026-10-17)
- No cron admin calls from Yorozu. Each row has "Edit in Chat": a new conversation opens with the job attached in the composer as a chip, like a file; sent, it becomes part of the text (`Cron job "<name>" (id <id>): …`) and the agent edits the job with its cron tool. (2026-10-15, chip 2026-10-17)
- A job delivering into a Yorozu conversation (`delivery.channel: yorozu`, `threadId`) opens that conversation from its row. (2026-10-15)

## Client UX

- The iOS launch screen shows the oval mark inside the app icon, not the full square icon; the mark and background respond to light and dark appearance. No timed splash delay. (2026-10-19)

- Settings opens with Appearance: System, Light or Dark, and an accent colour from eight (Vermilion, the default; Pink, Purple, Indigo, Blue, Teal, Green, Graphite). The accent is the tint, the user's bubble, the send control and the focus ring; each has a light and a dark value, and the bubble keeps white text at 4.5:1 in both. Both are kept on the device. (2026-10-22)
- Settings: a gear at the top left of the chat list opens it as a sheet; on the Mac it is the Settings window (⌘,). It shows this device's notification permission, the host (name, agent, OpenClaw and plugin versions, relay, key), the paired devices, and Unpair. From it the owner can turn push from the host on or off for this device and remove other devices; these are the only admin calls Yorozu makes. Unpair also removes this device on the host. (2026-10-17)
- In a conversation: a message's context menu has Copy and Select Text (a sheet to select any part); a small glass circle with a down arrow at the bottom centre appears while the newest message is out of view and scrolls back to it; the composer grows to five lines, then scrolls with the caret in view. (2026-10-17) Dragging the timeline left slides every message over and shows its time at the trailing edge, as in Messages; it springs back on release (iPhone and iPad). (2026-10-18)
- Two conversations side by side on iPad and iPhone Duo's inner display: Open Beside from the conversation's bar (⌘\), from a row's context menu, or by dragging a row onto either half of the conversation, where it opens. One pane is focused: its composer has an accent ring, the list highlights it and it is the one the host hears is in front; a tap in the other pane moves the focus. Both stream; no in-app notice for a reply already on screen. Picking from the list opens into the focused pane, and a conversation already open only takes the focus. The divider drags and snaps to a third, a half or two thirds, a fling to an edge closes that pane, double-tap equalizes. Each pane's menu has Swap Sides, Full Screen and Close. When the window is too narrow for two comfortable panes the sidebar steps aside. At compact width (iPhone, Duo closed) the pair stays, with a segmented switcher at the top of the conversation. A draft survives its pane being rebuilt. (2026-10-21)
- Pin a conversation from its row (swipe from the leading edge, or its menu): pinned ones sit in a Pinned section above Chats on every device, newest pin first. The pin is the OpenClaw session's (`pinnedAt`), so it is shared with OpenClaw's own UI; archiving unpins, and an archived conversation cannot be pinned. (2026-10-23)
- The list is ordered by each conversation's last message time, and that is the time a row shows: the host reads it from the transcript, so renaming, pinning or other changes do not reorder the list; a conversation imported from 0.5 keeps its last 0.5 message's time until a new message comes. (2026-10-24)
- On iPad and the Mac, when no conversation is open beside the list (at launch, or after the open one was deleted or archived), a new conversation opens, ready to type in, instead of an empty "No conversation selected" pane. Folding iPhone Duo to its phone layout goes back to the list if that new conversation is still empty. (2026-10-25)
- A message's picture or file opens in Quick Look zooming out of where it sits in the conversation, and a swipe down closes it back into place, as in Photos; Done still closes it (iPhone, iPad). The Mac opens it in its default app. (2026-10-26)
- A message sent just before leaving the app still goes out: going to the background on iPhone and iPad keeps the connection open (up to 25 s) until every message has reached the relay (✓); quitting the Mac app waits up to 10 s the same way. Whatever is still waiting after that goes out on the next launch, as before. (2026-10-26)
- Inside a conversation the iPhone's tab bar hides. Chats and Automations use inline titles. A conversation row's preview is one line. (2026-10-17)
- A control or label that a clear symbol can stand for is shown as the icon alone, with its words kept for VoiceOver (accessibility label, and a tooltip on the Mac): fewer visible strings to translate. Menu items, Settings tabs, status words and anything whose icon would be ambiguous keep their text. (2026-10-12)
- ⌘Enter sends by default on the Mac: Enter adds a newline. Hardware keyboards on iPhone and iPad keep smart Enter; the on-screen keyboard keeps its Send button. (2026-10-09, clients 2026-10-15)
- Siri, Shortcuts and Spotlight through App Intents: Ask Yorozu (sends, waits up to 25 s and returns the reply for Siri to read; past that, "the reply will come as a notification"), Open Conversation and New Conversation, with conversations as entities Siri can name; App Shortcuts phrases in English and Japanese. Search Yorozu finds conversations by what was said, with the matching lines; conversations (title and recent messages, up to 4,000 characters) are in an on-device Spotlight index Siri searches, Data Protection `complete`, removed on unpair, with a Settings switch (Siri & Search), on by default. (2026-10-17)
- Interface text is in English and Japanese on every client. (2026-10-09)
- A run that fails for a moment (a plugin reload, an overloaded or rate-limited model) before any reply or tool runs again by itself, for about four minutes, instead of showing its error; only a failure that outlasts that is shown. (2026-10-23)
- The client app is native SwiftUI, with selective AppKit on the Mac, never a web UI or webview wrapper. Use native SwiftUI components wherever they fit. (2026-10-07, clients 2026-10-15)
- The app takes the system look: native backgrounds, Liquid Glass bars, the vermilion accent and bubbles in system materials. Large UI changes are designed in Claude Design, mockups first; changes built from stock native controls go straight to code. (2026-10-09, mockups 2026-10-17)

## Platform and release

- The Mac app is a Tuist-generated Xcode project. Its macOS destination ships as 0.5's Mac id `to.yumi.yorozu`, Developer ID signed and notarized, team `AN5KM8QGEF`, so Sparkle updates 0.5.0-beta in place. (2026-10-07, id 2026-10-17)
- The Mac updates through Sparkle (macOS only), with 0.5's EdDSA key, from GitHub Releases. The default feed is `yorozu.yumi.to/beta/appcast.xml`; `YorozuBetaUpdates` stays respected. The stable feed stays frozen at 0.4.0. 0.9.0 is beta. (2026-10-17) 0.9 is stable, not beta. (2026-10-23)
- Releases: `projectx` merges into `main`, and `main`'s `release.yml` is ported to publish `v<ver>-beta` from a green `main`. (2026-10-17)
- The Mac signing identity is a local, gitignored build setting, not part of the repo; git history is left as it is. (2026-10-09)
- Clients reach the plugin through 0.5's end-to-end-encrypted Cloudflare Workers relay, reused as a deployed service. The relay may be changed when that is the better design (Transport). (2026-10-08, channel 2026-10-15)
- iOS ships to the public App Store (first release 0.9.0), manual release after approval, no phased release; TestFlight testers first. Review uses a live review host, with a fixture demo behind the documented code `YOROZU-DEMO` as fallback (as OpenClaw does). iOS shows a subtle, dismissible "Update available" row from Apple's lookup API; nothing is forced. (2026-10-08, App Store 2026-10-17)
- Version 0.9.1: iOS 0.9.0 went live on the App Store on 2026-10-23, which closed that version to new builds. The visible build restarts at 1 per version; `CFBundleVersion` = major·10⁷ + minor·10⁵ + patch·10³ + build on every platform (0.9.0 build 1 = `900001`, above 0.5's `10279`). (2026-10-08, encoding 2026-10-17, 0.9.1 2026-10-23)
- The app icon is 0.5's Icon Composer mark (blob-identical to 1e2f1fba). (2026-10-08)

## Upgrade from 0.5.0-beta

- Only 0.5.0-beta installs upgrade, to 0.9.0-beta, each migration confirmed by hand. 0.4.0 and older are not upgraded; the stable feed stays frozen at 0.4.0. Fix forward only, no rollback tooling. Plan: [docs/upgrade-from-0.5.md](docs/upgrade-from-0.5.md). (2026-10-17)
- The Mac migrates on first launch, fully automatically (an exception to click-to-write for this one migration): the 0.9 plugin is bundled at `Yorozu.app/Contents/Resources/openclaw-channel` so 0.5's `--link` install picks it up; the app drops `channels.yorozu.socketPath`, reloads the plugin accepting its capabilities and restarts the Gateway; the plugin imports 0.5's host keys and devices so no device re-pairs; memory notes import as unverified notes; every 0.5 chat becomes a conversation seeded with one plain `chat.inject` of its last 40 turns; 0.5's watchdog LaunchAgent is removed. 0.5's data folder is never written. (2026-10-17)
- iOS copies the keychain account `pairings` into `pairing-v3` on first launch, QR pairing as fallback, and never deletes `pairings`. (2026-10-17)
- Release order: the iOS build is assigned to TestFlight testers at the moment the Mac appcast item goes live; iOS shows "Your Mac is updating" and reconnects by itself, the Mac nudges to update the iPhone app. (2026-10-17)
- No bridge 0.5.x release. Once the owner confirms every 0.5 install migrated, all migration code is deleted. (2026-10-17)

## Stable contracts

These never change; future versions migrate around them (2026-10-17):

- Mac bundle id `to.yumi.yorozu`, iOS bundle id `to.yumi.yorozu.ios`, team `AN5KM8QGEF`.
- Sparkle EdDSA key and feed URLs (`yorozu.yumi.to/appcast.xml`, `yorozu.yumi.to/beta/appcast.xml`).
- `CFBundleVersion` formula (Platform and release); never a smaller leading number.
- Bundled plugin path `Contents/Resources/openclaw-channel`, plugin id `yorozu`.
- Keychain service `to.yumi.yorozu.ios` and account `pairing-v3`.

## Versioning rules

- Every stored record carries a schema version; ordered migrations `n → n+1`, each idempotent, run at launch. (2026-10-17)
- `peer_info` negotiates `protocolMin`/`protocolMax`; each side supports one protocol version back; `update_required` only outside that. (2026-10-17)
- Changes are additive: new fields optional, unknown fields ignored, not rejected. (2026-10-17)
- A breaking Mac update sets Sparkle `sparkle:minimumAutoupdateVersion`. (2026-10-17)
- Naming: prose, docs, UI and migration code name app versions ("0.5", "0.9"), never v1/v2/v3. Type names carry no version (the `V3*` prefixes are renamed in a mechanical PR). The wire protocol stays a plain integer, "protocol 3", separate from app versions. (2026-10-17)

## Engineering

- Language: Swift wherever possible, for a native feel; never Python. Code that has to live in another ecosystem uses that ecosystem's language, for example the TypeScript channel plugin that runs inside the OpenClaw Gateway. A separate long-running background process of Yorozu's own is Rust. (2026-10-13)
- Not used: Electron, Tauri, web frontends, SwiftData, Core Data, agent orchestration frameworks, vector services, or Python in the repo. (2026-10-09)
- Owner-specific values (such as the relay URL) are settings with generic defaults in code. (2026-10-09)
- The OpenClaw config sets `contextWindow: 272000` for `openai-pool/gpt-6-sol` and `openai-pool/gpt-6-astra` (the owner's global file, approved). OpenClaw's global `contextPruning` stays off. (2026-10-08)
- Working rules the owner set live in [AGENTS.md](AGENTS.md#rules); their dates are in the log.

## Process and roadmap

- Work lands on `projectx` through the usual worktree + PR flow, one #415 child issue per PR, in #415's build order. The secretary is deleted only after the new path works end to end. (2026-10-15)
- Tests and CI stay on hold; acceptance is compile + manual checks. Exception: the release job on `main`, with no test jobs. (2026-10-15, release 2026-10-17)

## Superseded

Superseded on 2026-10-15 by the channel decisions; their text as of 2026-10-14 is in the log ([decisions log](docs/history/decisions-log.md)): the secretary and its threads, main timeline, Main chat and Quick Chat; routing; workers, coding agents, integrations and cua; jobs and the Scheduled section; memory; the Mac host, its menu-bar UI, Settings, onboarding and setup CLI; the phone as a mirror of the Mac; the 0.7 contract, delivery marks, the outbox and the direct path; notifications as the host sent them; Hermes and the harness choice; role models; assisted setup; the agent id `projectx`; the 0.7.0 website; and the R1–R3 roadmap order.
