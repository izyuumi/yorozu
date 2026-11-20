# 0005. Local Mac pairing

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

A Mac on the same machine as the Gateway should pair without scanning a QR code (#532, feature flag `local-pair`). The trust boundary is "can read this user's files".

## Decision

- "Pair with the Gateway on this Mac" asks the plugin's loopback direct listener where its local pairing file is.
- The client probes as on the direct path, but without a room yet: the room is the hash of the key that answered, and that key must have signed the nonce for it.
- Instead of its Noise init, the client sends `{"type":"local_pair"}` and gets `{"type":"local_pair","path":…}`, or `error` when the host could not make a code. The answer is the path only. The link itself never crosses the socket.
- `local_pair` is a feature flag of the direct listener, both ways, not a `peer_info` capability: it is asked before any session. A plugin without it refuses the message like any other unexpected one (close 4101), which the client reads as no host.
- The plugin answers `local_pair` only on a loopback listener.
- Local Mac pairing must answer within 5 s, so it mints without waiting on a relay token: a new offline-style code with a random token and a 10-minute expiry.
- A code with less time left than `MIN_LEFT_MS` is not handed out again: the Mac needs the time to pair.
- The file:
  - One file at a time. It is deleted when its secret is spent (`PendingPairings.onSpend`), when it expires and on close. At start, whatever an earlier process left is stale, its secret gone with it, and is deleted.
  - Written atomically: its directory 0700 and owned by this user; the file 0600 through a temp file created exclusively beside it (`O_EXCL` never follows a symlink) and renamed over it (a rename replaces a symlink, never writes through it).
- The app reads the file only when it is this user's private regular file and names the room the loopback probe proved. It opens with `O_NOFOLLOW` and checks the same inode as the `lstat`, so nothing swapped in a symlink or another file in between.
- Closing the socket ends a `receive` still waiting, so the task group can finish.
- `localpair.ts` imports only node built-ins, so `node --test` runs it without OpenClaw.

## Consequences

- Anyone who can read the owner's files can pair a Mac; nobody else can, even on loopback.

## Where in the code

- `plugins/openclaw-yorozu/src/localpair.ts` — `LOCAL_PAIR`, `MIN_LEFT_MS`, `writePrivateFile`, `LocalPairingOptions.mint`, `LocalPairingFile`, `LocalPairingFile.close`
- `plugins/openclaw-yorozu/src/direct.ts` — `DirectOptions.localPair`, `receive` (`local_pair` branch)
- `plugins/openclaw-yorozu/src/relay.ts` — `mintPairing`, `LocalPairingFile` setup
- `plugins/openclaw-yorozu/src/pairing.ts` — `PendingPairings.onSpend`
- `packages/YorozuWire/Sources/YorozuWire/LocalPairing.swift` — `LocalPairing`, `LocalPairing.flag`, `LocalPairing.ask`, `LocalPairing.verify`
- `apps/ios/Sources/Client/LocalPairingFile.swift` — `LocalPairingFile`, `LocalPairingFile.read(path:room:)`
