# 0004. Pairing codes, sessions and the allowlist

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

A device pairs by scanning a QR link. Pairing must work while the relay is down (#532 step 5), and a pairing must never be lost through a storage hiccup.

## Decision

- Codes:
  - A code is a relay token. When the relay cannot mint one but the direct listener has hints, the plugin mints a random token the relay doesn't know. A relay join with it fails as "unknown token", so that code pairs over the direct path only.
  - An offline code lives as long as the relay's tokens (`OFFLINE_MS`).
  - A secret is one-time: a matching unexpired proof spends it, so a second use is refused.
- The link:
  - The query carries `port`, up to 4 `lan=<addr>/<prefix>` and 2 `ts=<addr>` entries, comma-separated, and no MagicDNS name, so the QR stays readable.
  - The client reads the link's hints as nil without a valid port, drops invalid entries as `DirectHints` drops them, and caps the lists as the plugin does.
  - The app moves the code's hints into `DirectHintStore` when it saves the pairing, where the host's later hints go too.
- Pairing over the direct path:
  - Pairing races the stored hints too; Bonjour waits until the device paired.
  - The relay doesn't know an offline code; the direct legs may still pair with it.
  - A direct-paired device retries the relay until the plugin's allowlist reaches it. Token expiry cannot unpair it.
- The hub's `pair` stores a device whose proof spends a pending secret. After every pairing, on either path, it queues the relay allowlist without delaying the handshake. Disconnected relays get it on their next `registered`.
- `Announcer` serializes roster reads and sends, so an older snapshot cannot land last.
- Sessions:
  - The hub serves each session over its own path, relay or direct (#532). Every relay session shares one link that sends through whichever relay socket is registered.
  - `Request.reply` seals for the device's current session, once it has sent `peer_info`.
  - The direct path has close codes of its own, apart from the relay's.
  - `broadcast` reaches every device with a live session over its own path; the relay batch skips devices connected directly.
  - When the relay has no device sockets left, only relay sessions lose their foreground.
  - The allowlist lookup returns the device's X25519 key (base64url), known-absent, or "could not read". Legacy callers return the key itself, or nothing for absent. A store miss says nothing about the device: no session, no pairing and no revoke.
  - A stale init is dropped before the allowlist check, so it cannot revoke.
  - A receive queue can still hold an already-opened frame after an await resumes.
- Client storage:
  - The pairing lives in the app's default Keychain group: the first entry of the group list, which equals the app's identifier, so items saved before the entitlement existed are there too. The share extension lists the same group first to read it. Reordering or renaming it would hide existing pairings and unpair devices.
  - `PairingMigration.State` is process-local: an unsuccessful migration permits reads of the retained old item until retry.
  - If saving a pairing fails, it is kept in memory: a pairing whose first session completed is not dropped over a failed write.

## Consequences

- A device can pair on the LAN with no relay at all.
- Keychain group order in `Project.swift` is effectively frozen.

## Where in the code

- `plugins/openclaw-yorozu/src/pairing.ts` — `OFFLINE_MS`, `QR_LAN`, `QR_TAILSCALE`, `mintCode`, `pairingQuery`, `PendingPairings.spend`, `Announcer`, `pairer`
- `plugins/openclaw-yorozu/src/hub.ts` — `Hub`, `CLOSE`, `Request.reply`, `HubOptions.staticKeyOf`, `Hub.handshake`, `Hub.broadcast`, `Hub.relayGone`
- `plugins/openclaw-yorozu/src/relay.ts` — `relayLink`
- `plugins/openclaw-yorozu/test/hub-session.test.ts`, `plugins/openclaw-yorozu/test/pairing.test.ts`
- `packages/YorozuWire/Sources/YorozuWire/Pairing.swift` — `QrPayload.hints`, `QrPayload.maxLAN`
- `packages/YorozuWire/Sources/YorozuWire/Direct.swift` — `RacingConnection.race`, `RacingConnection.received`, race state handling
- `packages/YorozuWire/Sources/YorozuWire/RelayConnection.swift` — `RelayConnection.afterClose`
- `apps/ios/Project.swift` — `pairingKeychainGroup`
- `apps/ios/Sources/ShareInbox/PairingMigration.swift` — `PairingMigration.State`
- `apps/ios/Sources/Client/AppModel.swift` — pairing accept, pairing save failure
