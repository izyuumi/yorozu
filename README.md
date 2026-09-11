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
