# 0021. Privacy in logs, diagnostics and push previews

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

Logs and diagnostics are read by whoever debugs Yorozu, and push previews pass through Apple. None of them may carry message content, keys or the room id.

## Decision

- The client logs a relay connection as `"<path> <host[:port]>"`, never the query, which holds the room id.
- The plugin logs an error by its code or name only, never its message, which may quote content (`errorTag`).
- The diagnostics report is plain text for whoever debugs Yorozu: app, device, connection state and this run's log. It holds no keys, tokens or message text. Card statistics are counts only ([0017](0017-presentation-cards-in-the-client.md)).
- Push previews are sealed with ChaCha20-Poly1305 and always a fresh nonce: a repeated nonce under the same key breaks the cipher. Production `sealPreview` takes no nonce on purpose; only a test helper chooses one, to make the fixture reproducible.
- The voice dictionary is never logged ([0024](0024-voice-engines-catalogue-and-dictionary.md)).

## Consequences

- Logs and reports can be shared for debugging without exposing conversations.

## Where in the code

- `packages/YorozuWire/Sources/YorozuWire/RelayConnection.swift` — `RelayConnection.host`
- `plugins/openclaw-yorozu/src/cards.ts` — `errorTag`
- `apps/ios/Sources/YorozuIOS/Diagnostics.swift` — diagnostics report
- `plugins/openclaw-yorozu/src/push.ts` — `sealPreview`
- `plugins/openclaw-yorozu/test/push-preview.test.ts` — `sealWithNonce`
