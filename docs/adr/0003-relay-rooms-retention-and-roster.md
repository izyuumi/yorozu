# 0003. Relay rooms: retention, storage migrations and device roster

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

The relay keeps one room per host. A room is only a cache: the host's allowlist is the real record of who is paired. The relay must forget idle rooms, survive deploys of older and newer code, and never unpair a device by mistake.

## Decision

- Retention: a room no member connected to for 30 days (`ROOM_IDLE_TTL_MS`) is deleted with everything stored for it.
  - `seenKey` holds the room's last connection from any member.
  - A connection lasts until it closes, so the relay touches the room on close; the alarm only sees sockets still open.
  - An open socket counts as a connection still going. A room from before retention starts its clock when first checked.
  - The alarm is queued behind message handling, so a register or join in flight lands before anything is deleted.
  - `storage.deleteAll()` also clears the alarm; the sweep sets it again if an unauthenticated socket needs one.
  - `retain` returns the next retention deadline, `Infinity` for an empty room.
- Rebuild: the host's next register and `devices` announce rebuild a wiped room, and its devices rejoin with the keys they already hold.
  - The room id is the host key's hash, so a wiped room accepts its host again like a new one.
  - On every `registered`, the plugin announces its allowlist. The allowlist is the only record of who is paired, so this announce rebuilds a room the relay wiped.
  - The relay ignores an `activityToken` without a `p:` row; only the devices announce restores that row in a wiped room.
- Storage migrations:
  - `Conn.announced` is read only when migrating socket attachments serialized before explicit roster state.
  - Old rooms are migrated once; a missing attachment field meant the host had not announced.
  - An older relay left a `gone` marker in each room it wiped. Nothing reads it now; `retain` deletes it.
- Roster:
  - `p:` timestamps stay backward-readable. Legacy rows are vouched under host authority, otherwise pending.
  - Legacy provenance is preserved before a new host socket resets roster authority.
  - Rows outside the latest announce are pending, and only a fresh row consumes pending capacity. A lagging announce keeps connected devices pending, so it cannot free pending capacity.
  - Only the host's announce can say a device is unknown. Until the current host announced, a nonce join of an unknown device retries. The plugin announces after every `registered`.
  - When the roster is full, the relay no longer evicts the oldest device with "revoked": v0.13.0 did, and that unpaired its app.
  - An announce must follow the relay's removal of disconnected phones.
- Plugin relay lifecycle:
  - Production reconnect backoff starts at roughly 1 s.
  - Every teardown step runs even if an earlier one fails, especially after setup throws.
  - The teardown's `host === me` comparison is safe if setup threw before assignment, because `host` is never undefined.

## Consequences

- Wiping a room costs nothing permanent: devices keep their keys and the host rebuilds it.
- Relay storage must stay readable by the previous relay release (see [0034](0034-test-conventions-and-fixtures.md) for the compatibility tests).

## Where in the code

- `apps/relay/src/protocol.ts` — `ROOM_IDLE_TTL_MS`
- `apps/relay/src/worker.ts` — `seenKey`, `Conn`, `Room.webSocketClose`, `Room.alarm`, `Room.retain`, `Room.vouched`, `Room.roster`, pending capacity check, `register` handling
- `apps/relay/src/index.ts` — `Room.announced`, nonce join of an unknown device
- `apps/relay/src/index.test.ts`, `apps/relay/src/worker.test.ts` — roster eviction and pending capacity tests
- `apps/relay/src/conformance.test.ts` — `paired`
- `plugins/openclaw-yorozu/src/relay.ts` — `registered` handling, setup and teardown
- `plugins/openclaw-yorozu/test/relay-integration.test.ts` — reconnect announce assertions
