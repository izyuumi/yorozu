# Owner decisions

The owner's decisions that are in force now, by area. Each line ends with the date it was made or last changed. The full log, superseded entries included, is [docs/history/decisions-log.md](docs/history/decisions-log.md).

When the owner makes or changes a decision, rewrite the line here so no two lines contradict, and append the entry to the log. Open questions and their defaults live in [docs/status.md](docs/status.md).

On 2026-10-15 the owner replaced the secretary system with Yorozu as an OpenClaw channel (tracking issue #415). The secretary-era decisions are superseded and kept in the log ([Superseded](#superseded)). Code and other docs still describe the secretary until the #415 build order removes it; where they disagree with this file, this file wins.

## Shape

- Yorozu is an OpenClaw chat channel, a peer of Signal or Telegram: a TypeScript channel plugin inside the owner's OpenClaw Gateway talks over the end-to-end-encrypted relay to Yorozu client apps on iPhone, iPad and Mac. OpenClaw runs the agent, sessions, memory and cron; Yorozu only carries messages, with a Signal-like UX. (2026-10-15)
- Yorozu runs nothing of its own: no routing, classification, workers, coding agents, memory, jobs, Hermes or cua. All of `Sources/ProjectXCore` engine code and the Mac host role go. (2026-10-15)
- No Mac host process. The OpenClaw channel plugin (`plugins/openclaw-yorozu`, TypeScript) holds the host keys and the relay connection itself. Fallback, only if the spike shows a plugin cannot: a Mac bridge app between Gateway and relay. (2026-10-15)
- One multiplatform SwiftUI client app for iPhone, iPad and Mac. Clients only; no host role anywhere in Swift. (2026-10-15)
- No backward compatibility: wire protocol v3, every device re-pairs once. Old wire types, store and engine are deleted, not flagged off. (2026-10-15)

## Conversations

- The client mirrors OpenClaw sessions, minimal. In scope: conversation list, open with history, send with replies arriving, new conversation, tool calls shown collapsed, attachments, push, read/unread marks, rename/archive/delete. Out: agent picker. (2026-10-15)
- Peer = the owner, not the device: all paired devices share one channel peer, so every conversation shows everywhere. Session key `agent:<agent>:yorozu:direct:owner:thread:<convId>` (thread-scoped sessions, as Telegram DM topics). (2026-10-15)
- One agent from plugin config (`channels.yorozu.agent`), default `main`. (2026-10-15)
- Only Yorozu conversations are listed; other channels' sessions are not. (2026-10-15)
- "+" makes a new `convId` (new thread session). `/new` inside a conversation resets that session in place. Other slash commands pass through as text. (2026-10-15)
- Titles are generated automatically by OpenClaw's own title generator (`utilityModel`, as for Telegram DM topics). A manual rename (session `label`) overrides it. (2026-10-15)
- History: the Gateway transcript is the source of truth. Clients keep a local cache and backfill from the plugin on open/reconnect; new devices see full history. (2026-10-15)

## Status marks

- Outgoing: ✓ sent = relay accepted; ✓✓ delivered = plugin received and decrypted; read = agent run started. Typing indicator from run start until the reply. (2026-10-15)
- Unread badge on agent replies until opened on any device; read state syncs across devices; manual Mark as Read/Unread stays. The plugin stores the read cursor per conversation in its state dir. (2026-10-15)
- Replies arrive as whole messages, chunked by length (no edit-in-place streaming). (2026-10-15)

## Pairing and security

- `openclaw yorozu pair` prints the pairing QR (plus the `yorozu://pair…` link) in the terminal. The QR carries relay URL, room id, host public key, one-time token and secret. Scanned devices join the plugin's allowlist. (2026-10-15)
- Crypto: Noise-style handshake (IK: the device knows the host static key from the QR) per connection for forward secrecy, over the existing primitives (X25519, HKDF-SHA256, ChaCha20-Poly1305, Ed25519 relay frames). (2026-10-15)
- Baseline: client cache under iOS Data Protection `complete`; client keys in Keychain, this-device-only, non-syncing; plugin keys in OpenClaw's credentials store, `0600`; push previews sealed; fingerprint shown on both sides at pairing. (2026-10-15)
- Transcripts on the Mac stay plaintext in OpenClaw's state (same trust model as every OpenClaw channel). (2026-10-15)

## Transport

- Relay only. The direct path (port 8738) is dropped. The plugin only makes an outbound connection; the Gateway opens no new port. (2026-10-15)
- The deployed relay also serves v1 users on `main`; any relay change must stay backward compatible. (2026-10-15)
- The relay answers each client frame with `accepted` once it has forwarded it or stored it durably. Merged on `main` in #332 and deployed by the owner. (2026-10-09)

## Push and attachments

- One push per finished agent reply via the relay's `notify`, preview (title + first line) sealed per device; none to a device with that conversation in the foreground. Cron output delivered into a conversation pushes the same way. No mute yet. (2026-10-15)
- Attachments both ways (`sendMedia`), 8 MB limit (OpenClaw's `mediaMaxMb` default), sealed chunks under the relay's 1 MiB frame limit. Share extension stays. No voice notes yet. (2026-10-15)

## Crons

- A Crons tab next to Chats: all jobs on the configured agent (`cron.list`), disabled ones greyed; name, human schedule, next run, last status (error on tap). (2026-10-15)
- No admin calls from Yorozu. Each row has "Edit in chat": a new conversation (or the job's delivery conversation) opens with a draft `Change cron job "<name>" (id <id>): ` and the agent edits it with its cron tool. (2026-10-15)
- A job delivering into a Yorozu conversation (`delivery.channel: yorozu`, `threadId`) opens that conversation from its row. (2026-10-15)

## Client UX

- A control or label that a clear symbol can stand for is shown as the icon alone, with its words kept for VoiceOver (accessibility label, and a tooltip on the Mac): fewer visible strings to translate. Menu items, Settings tabs, status words and anything whose icon would be ambiguous keep their text. (2026-10-12)
- ⌘Enter sends by default on the Mac: Enter adds a newline. Hardware keyboards on iPhone and iPad keep smart Enter; the on-screen keyboard keeps its Send button. (2026-10-09, clients 2026-10-15)
- Interface text is in English and Japanese on every client. (2026-10-09)
- The client app is native SwiftUI, with selective AppKit on the Mac, never a web UI or webview wrapper. Use native SwiftUI components wherever they fit. (2026-10-07, clients 2026-10-15)
- The app takes the system look: native backgrounds, Liquid Glass bars, the vermilion accent and bubbles in system materials. The design is done in Claude Design, mockups first, before UI code. (2026-10-09)

## Platform and release

- The Mac app is a Tuist-generated Xcode project and takes v1's identity (bundle id, signing team, entitlements). (2026-10-07)
- The Mac signing identity is a local, gitignored build setting, not part of the repo; git history is left as it is. (2026-10-09)
- Clients reach the plugin through v1's end-to-end-encrypted Cloudflare Workers relay, reused as a deployed service. The relay may be changed when that is the better design (Transport). (2026-10-08, channel 2026-10-15)
- iOS ships to internal TestFlight only. Build numbers are per version, start at 1 and ascend. (2026-10-08)
- The app icon is v1's Icon Composer mark (blob-identical to 1e2f1fba). (2026-10-08)

## Engineering

- Language: Swift wherever possible, for a native feel; never Python. Code that has to live in another ecosystem uses that ecosystem's language, for example the TypeScript channel plugin that runs inside the OpenClaw Gateway. A separate long-running background process of Yorozu's own is Rust. (2026-10-13)
- Not used: Electron, Tauri, web frontends, SwiftData, Core Data, agent orchestration frameworks, vector services, or Python in the repo. (2026-10-09)
- Owner-specific values (such as the relay URL) are settings with generic defaults in code. (2026-10-09)
- The OpenClaw config sets `contextWindow: 272000` for `openai-pool/gpt-6-sol` and `openai-pool/gpt-6-astra` (the owner's global file, approved). OpenClaw's global `contextPruning` stays off. (2026-10-08)
- Working rules the owner set live in [AGENTS.md](AGENTS.md#rules); their dates are in the log.

## Process and roadmap

- Work lands on `projectx` through the usual worktree + PR flow, one #415 child issue per PR, in #415's build order. The secretary is deleted only after the new path works end to end. (2026-10-15)
- Tests and CI stay on hold; acceptance is compile + manual checks. (2026-10-15)

## Superseded

Superseded on 2026-10-15 by the channel decisions; their text as of 2026-10-14 is in the log ([decisions log](docs/history/decisions-log.md)): the secretary and its threads, main timeline, Main chat and Quick Chat; routing; workers, coding agents, integrations and cua; jobs and the Scheduled section; memory; the Mac host, its menu-bar UI, Settings, onboarding and setup CLI; the phone as a mirror of the Mac; the 0.7 contract, delivery marks, the outbox and the direct path; notifications as the host sent them; Hermes and the harness choice; role models; assisted setup; the agent id `projectx`; the 0.7.0 website; and the R1–R3 roadmap order.
