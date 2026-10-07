# iOS 0.6.0 host <-> phone contract (frozen)

This is the wire contract between the Mac host (`RelayHost` + `EngineBridge` in the Mac app) and
the iOS app (`PhoneModel` on top of `RelayClient`) for Yorozu v2 0.6.0. Both sides implement
against this file. Change it only with a matching change on both sides.

All types come from `packages/YorozuWire` (the v1 `YorozuShared` wire files, vendored). Build
events with the Swift types named here, never with hand-written JSON.

Out of scope for 0.6.0: APNs/`notify`, Stop, attachments, sub-chats, device management events.

## Transport (unchanged v1 relay)

- Relay: `wss://relay.yumi.to`, protocol unchanged. Pairing is `QrPayload` (v1 QR or `yorozu://pair`).
- Phone side: `RelayClient` (vendored, unchanged). It does join, the cleartext `hello`
  (`{t:"hello",pub,spub,proof}`, proof = `YorozuCrypto.helloProof(secret:pub:spub:)`), the
  sealed channel and the peer-info gate. `PhoneModel` sees only `TransportUpdate`s.
- Mac side: `RelayHost` re-implements the v1 host half (register, mint, hello check, seal/open
  per device with role `.mac`, `ack{seq}` for replayed frames). `FrameBody` and the relay
  envelope are private in `RelayClient`; `RelayHost` declares its own copies.
- Every sealed box is `ChannelEnvelope{seq, event}` (`Channel.swift`), keys from
  `YorozuCrypto.deriveChannelKeys(myPriv:theirPub:role:)`. One `ChannelCounter` per device,
  persisted before sending and before acting on a received box.
- The relay buffers phone -> Mac frames (replayed with `seq`) but never Mac -> phone frames.
  So the host must be idempotent on replays, and the phone catches up with `sync_request`.

## Event envelope

Every event is a `YorozuEvent`:

| Field | Phone -> Mac | Mac -> phone |
|---|---|---|
| `id` | `UUID().uuidString` (for `message`: the bubble's id, see below) | `UUID().uuidString`, except chat messages: the v2 `Message.id` |
| `threadId` | `"main"` | `"main"` on chat messages, `""` on control events |
| `ts` | epoch ms, phone clock | epoch ms; chat messages: `Int(Message.created * 1000)` |
| `agentId` | `"device"` | `"main"` |
| `syncCursor` | unset | chat messages: the `Message.id`; otherwise unset |

`clientTs` and `parentAgentId` are never set. There is exactly one thread, id `"main"`.

## Handshake (peer-info), done before anything below

Handled by `RelayClient` on the phone and `RelayHost` on the Mac; `PhoneModel` and
`EngineBridge` never see it.

1. After a valid `hello`, the host's first sealed event is
   `.threadList(ThreadListData(threads: [main], peerInfoSupported: true))`.
2. The phone answers `.threadList(ThreadListData(threads: [], peerInfo: PeerInfoData.local))`
   with event id `R`.
3. The host checks `PeerInfoData.local.compatibility(with: claim)` and replies
   `.threadList(ThreadListData(threads: [main], peerInfoSupported: true, peerInfo: host,
   peerInfoReplyTo: R))`, where `host` is `PeerInfoData.local` with `computerName` set to the
   Mac's name. On `.updateRequired(reason)` it sends `peerInfoError: reason` instead of
   `peerInfo` and serves that device nothing else.
4. The phone checks compatibility and yields `.state(.paired)`.

After step 2, every `thread_list` the host seals to that device carries
`peerInfoSupported: true` and `peerInfo: host`. `RelayClient` fails the link with "Update
required" on a later `thread_list` that has neither, and restarts the exchange on one that has
only `peerInfoSupported`.

The one exception: after every relay `registered`, the host seals the step-1 list to every paired
device again. A relay that replaces a stale Mac socket tells no phone the Mac was gone, so a
phone can still be `.paired` while live updates were lost; this restarts its exchange, and its
next `.paired` catches up. A device that had finished the exchange stays served meanwhile.

The host answers steps 1 and 3 on its own actor, never waiting on the Engine (15 s deadline,
`RelayClient.swift`). Both ends advertise `PeerInfoData.local`:
capabilities `["peer-info","host-name","channel-sequence","yorozu-v2"]`, required
`["channel-sequence","yorozu-v2"]`. A v1 peer on either side therefore ends in "Update required".
Until a device's exchange succeeds, the host passes none of its other events to the backend.

`main` above is the one summary defined under `thread_list` below.

## The six event kinds

### 1. `message` (phone -> Mac): send a user message

```swift
YorozuEvent(id: UUID().uuidString, threadId: "main", ts: nowMs, agentId: "device",
            payload: .message(MessageData(role: .user, text: text)))
```

- `text` is 1-6000 UTF-8 bytes after the phone's own check. No attachments.
- `admissionDeadline`, `delivery`, `channelModel` are not sent and the host ignores them.
- The phone keeps the event in a pending set until it gets a `receipt` or an
  `admission_status` for that `id`, and resends every pending event on every `.paired`.

Host checks, in this order, then acts:

1. `id` matches `^[A-Za-z0-9-]{1,64}$`, else `admission_status rejected`.
2. `attachments` is empty, else `admission_status rejected`.
3. `RuntimeMode.permitsInput(fixtureAcknowledged: false)` is true (fixture mode never takes
   phone input), else `admission_status rejected`.
4. If a v2 `Message` with that id exists: reply `receipt` only (duplicate or relay replay).
5. `try await engine.send(text, id: event.id)`, then reply `receipt`.
   If it throws: if a `Message` with that id now exists (a concurrent duplicate won), reply
   `receipt`; else reply `admission_status rejected` with `reason = error.localizedDescription`.

### 2. `receipt` (Mac -> phone): the message is stored

```swift
YorozuEvent(id: UUID().uuidString, threadId: "", ts: nowMs, agentId: "main",
            payload: .receipt(ReceiptData(eventId: messageId)))
```

The phone drops `messageId` from its pending set. The bubble stays; the stored copy arrives
through `sync_delta` with the same id and replaces it in place.

### 3. `admission_status` (Mac -> phone): the message was refused

```swift
YorozuEvent(id: UUID().uuidString, threadId: "", ts: nowMs, agentId: "main",
            payload: .admissionStatus(AdmissionStatusData(eventId: messageId, status: .rejected, reason: reason)))
```

Only `status: .rejected` is sent in 0.6.0. `reason` is user-facing text the phone shows as is:

| Cause | `reason` |
|---|---|
| bad id | `"Invalid message id."` |
| attachments | `"Attachments aren't supported yet."` |
| fixture mode | `"This Mac is in fixture mode and doesn't take phone messages."` |
| Engine error | `error.localizedDescription` (e.g. "Message must be 1–6000 UTF-8 bytes.") |

The phone drops `messageId` from its pending set, marks that bubble failed and does not resend it.

### 4. `sync_request` (phone -> Mac): catch up

```swift
YorozuEvent(id: UUID().uuidString, threadId: "main", ts: nowMs, agentId: "device",
            payload: .syncRequest(SyncRequestData(lastSeen: cursor.map { ["main": $0] } ?? [:], threadId: "main")))
```

- Sent on every `.paired`, and again whenever a reply page has `more == true`.
- `lastSeen["main"]` is the `syncCursor` of the newest message the phone holds without a gap
  (rules under `sync_delta`). Absent means "from the start".
- `focusThreadId` and `includeCurrent` are unset and ignored.

The host answers with one `sync_delta` reply page.

### 5. `sync_delta` (Mac -> phone): messages and the working flag

```swift
YorozuEvent(id: UUID().uuidString, threadId: "", ts: nowMs, agentId: "main",
            payload: .syncDelta(SyncDeltaData(events: page, threadId: replyThreadId,
                                              workingThreadIds: working ? ["main"] : [], more: more)))
```

Each element of `events` is one v2 `Message`, oldest first, in snapshot order
(`created, rowid`), every message regardless of topic (the Mac's main chat shows all of them):

```swift
YorozuEvent(id: m.id, threadId: "main", ts: Int(m.created * 1000), agentId: "main", syncCursor: m.id,
            payload: .message(MessageData(role: m.role == "user" ? .user : .agent, text: m.body,
                                          done: true, failed: m.kind == "failure" ? true : nil)))
```

- `working` is true when any `Work.active` is true in the snapshot.
- `workingThreadIds` is always present (`[]` when idle); the phone shows the working indicator
  exactly when it contains `"main"`.
- `current` is unset.

Two flavours, told apart by `threadId`:

- **Reply page** (`threadId == "main"`): answers a `sync_request`. Contains the messages after
  the cursor (all of them if the cursor is absent or unknown), at most 200 events and at most
  512 KB of encoded events (always at least one event if any remain). `more = true` when
  messages remain, else `nil`.
- **Live update** (`threadId == nil`, `more == nil`): sent unprompted to every paired device when
  the 350 ms poll's snapshot has message ids the previous one lacked, or the working flag
  changed. `events` holds only the new messages (may be empty when only the flag changed).
  More than 200 new messages go out as several live updates.

Phone rules:

1. A message whose `id` the phone already holds replaces that entry in place; otherwise it is
   added. v2 messages never change after insert, so nothing else is needed.
2. On every `.paired`, set `catchingUp = true` and send `sync_request`.
3. On a reply page: merge; if it has events, set `cursor` to the last event's `syncCursor`;
   if `more == true` send the next `sync_request` with that cursor, else `catchingUp = false`.
4. On a live update: merge; advance `cursor` to its last event's `syncCursor` only when
   `!catchingUp`. (While catching up, older pages may still be missing; re-fetching later is
   safe because rule 1 dedupes.)

### 6. `thread_list` (both directions)

The one summary, `main`:

```swift
ThreadSummary(id: "main", title: "Yorozu", archived: false, lastActivity: newestMessageCreatedMs /* 0 if none */)
```

- Peer-info use is in the handshake above (`RelayHost`).
- A phone `thread_list` without `peerInfo` gets
  `.threadList(ThreadListData(threads: [main], peerInfoSupported: true, peerInfo: host))` back
  (`RelayHost` adds the peer fields to whatever thread list the backend returns). The 0.6.0
  phone doesn't need to send one.

## Everything else

The host ignores every other kind (no reply, no receipt). The phone sends nothing but `message`,
`sync_request` and, via `RelayClient`, the peer-info `thread_list`, and ignores events of other
kinds.

## Mac-side seams

- `RelayBackend` (`YorozuWire/RelayBackend.swift`): `func handle(_ e: YorozuEvent) async -> [YorozuEvent]`.
  `RelayHost` passes it each decrypted phone event other than the peer-info `thread_list`, and
  seals the returned events back to that same device only. `EngineBridge` implements it
  (kinds 1, 4, 6 in; 2, 3, 5 out).
- Live updates go out through `RelayHost.broadcast([YorozuEvent])` to every paired device.
- `Engine.send(_:id:)` / `Store.message(..., id:)` keep the phone's `id` as the v2 `Message.id`,
  so the phone's bubble and the stored message are one entry.
