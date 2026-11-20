# 0011. History sync, resumable uploads and the share extension

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

The app pages history from the host, sends one request at a time, uploads attachments in chunks that must survive reconnects, and lets the share extension send on its own session.

## Decision

- History paging:
  - A page replaces the seq range it covers. The app never re-fetches a range it already holds (requests are `after: newestSeq` or `before: oldestSeq`), so no held item, and no card on one, falls inside it.
  - An empty page with rev 0 means the host has no session yet. The app does not take its rev, since a rev would let the list prune the thread.
- Request queue:
  - Only an answer for the in-flight request can finish it. Older hosts may omit history cursors.
  - A host error about one message fails the in-flight request only when that request is the message itself. History and conversation-list requests carry no message id, so such an error leaves them in flight.
- Resumable uploads (capability `resume`):
  - A host listing `resume` in `peer_info` is asked what it holds, and uploads carry the file's SHA-256 (lowercase hex). An older host starts the upload over.
  - On a new session the receiver holds `have` and nothing is in flight. With every chunk held but the upload not stored, the last chunk goes again so the receiver assembles it.
  - On `hashMismatch` the host dropped what it had: start over once, with the hash read again.
- Plugin upload spool:
  - `<id>.part` holds the bytes at `index * chunkBytes`; `<id>.json` lists the chunks it holds. Imports only node built-ins so `node --test` runs it without OpenClaw.
  - `run` runs a function after every earlier `run` for the same id; the other methods expect to be called inside it.
  - `status` reports the chunks held for an upload of this shape; a spool of another shape is dropped. `put` returns `null` when the spool held another upload under this id, which is dropped.
  - `sweep` drops entries idle past the TTL and files without a ledger; `tidy` is housekeeping after an upload event. Both are called outside `run`.
- Share extension:
  - It sends one share over a relay session of its own, under the app's pairing: it uploads the file in chunks read from disk, sends the message, and returns once the host answers `delivered` or `run_started`.
  - The host keeps one session per device, so the extension's session replaces the app's while it runs. After the extension sent a share itself it posts `sentNotification`, and an open app reconnects.
  - The inbox folder is named for `messageId` and the app sends the share under that id, so a share the extension already got to the host is answered `delivered` again rather than run twice.

## Consequences

- Reconnects resume uploads instead of restarting them, on hosts that support it.
- A share is never run twice, whichever process sent it.

## Where in the code

- `apps/ios/Sources/Client/Store.swift` — history page merge
- `apps/ios/Sources/Client/AppModel.swift` — history page handling
- `apps/ios/Sources/Client/RequestQueue.swift` — `finish(answering:)`, `fail(messageId:)`
- `apps/ios/Sources/Client/Transfers.swift` — `resumable`, upload loop
- `apps/ios/Sources/YorozuShare/ShareSender.swift` — `ShareSender`
- `apps/ios/Sources/ShareInbox/ShareInbox.swift` — `write(text:file:convId:messageId:)`, `sentNotification`
- `packages/YorozuWire/Sources/YorozuWire/Resume.swift` — `UploadSender.resume`
- `packages/YorozuWire/Sources/YorozuWire/WireEvent.swift` — `Upload.sha256`
- `plugins/openclaw-yorozu/src/spool.ts` — `Spool`, `run`, `status`, `put`, `sweep`, `tidy`
