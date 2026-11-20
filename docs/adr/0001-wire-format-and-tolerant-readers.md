# 0001. Wire format, wire migration and tolerant readers

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

The client (Swift), the plugin (TypeScript), the relay (TypeScript) and the Windows client (Rust) all speak one wire ([docs/ios-relay-contract.md](../ios-relay-contract.md)). Old and new versions of each meet in the field, so every reader must accept what an older or newer peer sends, and the frame format must change without breaking sessions.

## Decision

- A frame leads with its type byte. Clients before 0.11 lead with the old version byte 3, then 1, 2 or 3. Each session answers in the format its init frame used, until the plugin drops the old one.
- Feature flag `unversioned-wire` (#532 wire migration step 1): the plugin accepts unversioned frames and the `yorozu|…` prologue. Clients may send unversioned only to a plugin listing it; this plugin always lists it.
- The client's `unversionedWire` is true only if the host listed `UnversionedWire.capability` in its last `peer_info`.
- A pairing link without `v` is the current wire's. The plugin stops sending `v=3` once every client reads it so.
- Changing only a box's format must not bypass the session binding: a valid SID, counter and tag are not enough.
- The Noise initiator payload puts `ts` first, then `proof`. This matches both existing wire implementations and the published vector.
- Relay parsers return `null` when a message is malformed and `undefined` for something the relay does not know: an unknown notify class or Live Activity event is ignored by the caller; an unknown job kind or state drops the job.
- A relay message of an unknown type is ignored, but it still costs a rate-limit token.
- `CLOSE_HOST_OFFLINE` means a nonce join the relay cannot answer yet: no host registered, or the host has not announced its devices. The device retries.
- The relay sends every host frame to every device socket.
- The relay tests send exactly the shipped token and nonce join fields. They also exceed the unacknowledged window to prove the old `flowAck` shape is still read; ignoring it would close the peer.
- Tolerant readers on the client:
  - A `Reaction` whose `by` the client doesn't know reads as absent, so the reaction still decodes (and is ignored).
  - A card the client can't read is dropped from a `Reply`; the reply keeps the rest.
  - A history call whose status the client doesn't know is dropped, and so is a card it can't read; the item keeps the rest.
  - In a `Presentation`, a block of an unknown type, or one that fails a check, decodes as `.unknown` with its `alt`.
- The reaction emoji length limit counts UTF-16 units, so 👍 counts as two.

## Consequences

- New fields and kinds can ship before every peer understands them.
- The legacy frame format stays in the plugin until no client sends it.
- Rate limiting cannot be dodged by sending unknown types.

## Where in the code

- `plugins/openclaw-yorozu/src/wire.ts` — `LEGACY_VERSION`
- `plugins/openclaw-yorozu/src/envelope.ts` — `UNVERSIONED_WIRE`
- `plugins/openclaw-yorozu/test/unversioned-wire.test.ts`, `plugins/openclaw-yorozu/test/wire.test.ts`
- `packages/YorozuWire/Sources/YorozuWire/Direct.swift` — `RacingConnection.init`
- `packages/YorozuWire/Sources/YorozuWire/RelayConnection.swift` — `RelayConnection.init`
- `packages/YorozuWire/Sources/YorozuWire/Pairing.swift` — `QrPayload.decodePairingString`
- `packages/YorozuWire/Sources/YorozuWire/WireEvent.swift` — `Reaction`, `Reply.init`, `Presentation`, `HistoryItem.init`
- `packages/YorozuWire/Tests/YorozuWireTests/WireEventLimitTests.swift` — `reactionEmojiLength`
- `apps/windows/core/src/wire.rs` — Noise initiator payload
- `apps/relay/src/protocol.ts` — `CLOSE_HOST_OFFLINE`, `parseNotify`, `parseActivityJob`, `parseActivityPush`
- `apps/relay/src/worker.ts`, `apps/relay/src/index.ts` — message dispatch `default` branch
- `apps/relay/src/worker.test.ts` — join helpers, flow-ack window test
- `apps/relay/src/direct.test.ts` — fan-out assertion
