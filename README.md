# Yorozu

Out-of-box personal AI assistant for macOS, remote-controlled from iOS through a blind end-to-end encrypted relay. Install, grant permissions once, scan one QR, start talking.

- Spec: `docs/spec-v1.html`
- Tickets: `tickets.md`

## Layout

- `apps/mac` — SwiftUI menu bar app, native tool host (SwiftPM executable, macOS 15+).
- `apps/ios` — SwiftUI iOS app sources (SwiftPM library, iOS 18+).
- `apps/relay` — blind websocket relay that forwards ciphertext between Mac and phone.
- `packages/runtime` — Node agent loop, provider adapters, tools, memory, scheduler.
- `packages/shared` — protocol event types shared by the TypeScript workspaces.
- `packages/shared-swift` — SwiftUI views shared by the Mac and iOS apps.

## Runtime sidecar

`pnpm --filter @yorozu/runtime serve` (installed as the `yorozu-serve` bin) is what the Mac app
spawns. It loads or creates the Mac's X25519 and Ed25519 keypairs, registers its relay room, mints
a join token, prints the pairing payload, then answers each sealed message with the agent loop.
Stdout is the protocol the Mac app reads: `STATE <state>` per relay transition, `QR <json>` per
pairing payload.

| Variable | Default |
| --- | --- |
| `YOROZU_STATE_DIR` | `~/Library/Application Support/Yorozu` (holds `keys.json`, mode 600) |
| `YOROZU_RELAY_URL` | `ws://127.0.0.1:8787` |
| `YOROZU_BASE_URL` / `YOROZU_API_KEY` / `YOROZU_MODEL` | `https://api.openai.com/v1`, unset, `gpt-4o-mini` |

Pairing: the QR carries the Mac's X25519 key, the room ID and a one-time token. The phone joins the
room, announces its own X25519 key in one cleartext `hello` frame (authenticated by the relay's
per-frame signature check), and every frame after that is ChaCha20-Poly1305 sealed under the derived
session key.

## Mac app

```sh
pnpm --filter @yorozu/runtime build            # sidecar must be built first
docker run -p 8787:8787 yorozu-relay &         # or any relay
swift run --package-path apps/mac
```

The menu bar window shows the relay state and the pairing QR. The sidecar command is
`YOROZU_RUNTIME_CMD`, run through `/bin/sh -c`, defaulting to
`node ../../packages/runtime/dist/serve.js` (relative to `apps/mac`, i.e. the dev checkout layout);
the shipped app will point it at the bundled runtime. The sidecar is killed when the app quits.

## Memory

Facts live as one markdown file per fact in `YOROZU_MEMORY_DIR` (default
`<YOROZU_STATE_DIR>/memory`, itself defaulting to `~/Library/Application Support/Yorozu`).
Frontmatter carries `kind` (`preference`, `decision`, `correction`, `fact`, `approval`),
`created`, `threadId` and `agentId`. The files are the truth: edit them by hand or in Obsidian.

The SQLite FTS5 index next to them (`.index.sqlite`) is derived, and is rebuilt from the files
whenever it is missing or their mtimes have moved. The agent writes facts with the `remember`
tool; `recallForPrompt` returns a compact block that `runAgent` prepends to the system prompt
when given a `memory`. Vector recall is not implemented yet: `searchByEmbedding` returns nothing
until sqlite-vec or provider embeddings land.

## Relay

The relay forwards ciphertext between Mac and phone and can read none of it. Rooms are keyed by
`base64url(sha256(macPublicKey))`. The Mac registers by signing a server-issued nonce with its
Ed25519 key, then mints one-time join tokens (10 minute TTL) that the phone redeems with a
signature over the token. Every frame carries a signature from the sender's registered key;
unsigned or mis-signed frames close the connection. While the Mac is offline, frames are buffered
in memory per room (24h TTL, 5 MB cap, oldest dropped first) and drained in order on reconnect.
Each room is rate limited to 60 frames per second.

Run it with one command (`PORT` defaults to 8787):

```sh
docker build -t yorozu-relay -f apps/relay/Dockerfile . && docker run -p 8787:8787 yorozu-relay
```

## Scheduler and transcripts

Jobs live as JSON in `<YOROZU_STATE_DIR>/schedule.json`: an ID, the thread the job fires in, the
instruction, either a `when` (ISO 8601 one-shot) or a `cron`, who created it and when it last ran.
The agent manages them with `schedule(instruction, at | cron)`, `unschedule(id)` and
`list_schedule`. Cron is a 5-field expression (`minute hour day-of-month month day-of-week`)
matched against local time by `src/cron.ts` — numbers, `*`, `*/n`, lists and ranges, no dependency.

There is no heartbeat: `startScheduler` wakes every 30s, asks which jobs are due, and hands each to
the sidecar, which runs it as a turn in the job's own thread and emits the reply to the phone
exactly as if the user had typed it. One-shots are dropped once fired; cron jobs record `lastRun`
so a second tick inside the same minute cannot double-fire them.

Every event the sidecar sees is appended to `<YOROZU_STATE_DIR>/transcripts/YYYY-MM-DD.jsonl`
(UTC day), readable back with `readTranscripts(since)` and by the agent through the
`read_transcripts` tool. A fresh schedule is seeded with the nightly consolidation job
(`0 3 * * *`, thread `system`), which tells the agent to read the last 24h and `remember` the
durable facts memory does not already hold. Unschedule it and it stays gone.
