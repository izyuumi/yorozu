# iOS 0.7 host <-> phone relay contract

This is the wire contract between the Mac host (`RelayHost` + `EngineBridge` in the Mac app) and
the iOS app (`PhoneModel` on top of `RelayClient`) for Yorozu v2 0.7. Both sides implement
against this file. Change it only with a matching change on both sides, and follow
[Versioning](#versioning).

All types come from `packages/YorozuWire` (the v1 `YorozuShared` wire files, vendored, plus the
0.7 payloads in `Mirror.swift`). Build events with the Swift types named here, never with
hand-written JSON.

The phone is a mirror of the Mac with control: the Mac is the only source of truth. The phone
holds a cache of the [history window](#history-window), catches up by
[change sequence](#change-sequence), can Stop or Retry a task, moves the read cursor, searches the
Mac's full history and removes its own pairing.

Out of scope for 0.7: APNs/`notify`, attachments,
typing in sub-chats, multiple threads (the thread id is carried everywhere and never hard-wired
beyond the one thread `"main"`).

## Transport (unchanged v1 relay)

- Relay: `wss://relay.yumi.to`, protocol unchanged. Pairing is `QrPayload` (v1 QR or `yorozu://pair`).
- Phone side: `RelayClient`, one session over the relay or the [direct path](#direct-path). It does join, the cleartext `hello`
  (`{t:"hello",pub,spub,proof}`, proof = `YorozuCrypto.helloProof(secret:pub:spub:)`), the
  sealed channel, flow acks and the peer-info gate. `PhoneModel` sees only `TransportUpdate`s.
- Mac side: `RelayHost` re-implements the v1 host half (register, mint, hello check, seal/open
  per device with role `.mac`, `ack{seq}` for replayed frames). `FrameBody` and the relay
  envelope are private in `RelayClient`; `RelayHost` declares its own copies.
- Every sealed box is `ChannelEnvelope{seq, event}` (`Channel.swift`), keys from
  `YorozuCrypto.deriveChannelKeys(myPriv:theirPub:role:)`. One `ChannelCounter` per device,
  persisted before sending and before acting on a received box.
- The relay buffers phone -> Mac frames (replayed with `seq`) but never Mac -> phone frames.
  So the host must be idempotent on replays, and the phone catches up with `sync_request`.
- `accepted`: the relay answers every phone frame with `{"type":"accepted","sig":…,"buffered":bool}`
  once it has forwarded the frame to the Mac's live socket (`buffered: false`) or stored it
  durably for the Mac (`buffered: true`); `sig` is the frame's own signature. `RelayClient`
  maps each sent event's frame signature to its event id, per socket (forgotten when the socket
  changes), and yields `TransportUpdate.accepted(eventId:buffered:)` for a known one; the
  handshake frames are not mapped. No `accepted` on the direct path.
- Sending while the Mac is away: `RelayClient.send` works once joined, before `.paired`, when
  the channel is replay-protected: the Mac answered in the current format on this socket, or
  this pairing has completed the peer-info exchange before (`ChannelCounter.peerInfoRequired`).
  The channel keys come from the pairing, so such a box is one the relay buffers and the Mac
  opens when it returns. Otherwise `send` throws until `.paired`, as before.

### Relay limits and pacing

The relay (on `main`, not changed by 0.7) takes at most 1 MiB per WebSocket message and 60
messages a second per socket, and drops a phone socket with `1013 slow receiver` once more than
2 MiB sent to it is unacknowledged (`RelayClient` acks every 1 MiB or 16 frames). It forwards
every Mac frame to every phone socket of the room, and a phone ignores boxes sealed for another
phone. So every frame the Mac sends counts against every phone's 2 MiB window.

- `RelayHost.transmit` batches at most 16 frames and about 900 KB a message.
- Catch-up is request-driven: the Mac sends a reply page only for a `sync_request`, so each
  phone has at most one page in flight.
- The Mac keeps reply pages to at most 200 records and 256 KiB of encoded events, except that a
  page always holds at least one record when any remain (a bigger one is then
  [chunked](#chunking)).
- Every sealed frame is charged once against one token bucket across all phones: 512 KiB and
  30 frames a second, starting and capped at 512 KiB and 30 frames. A frame leaves only when the
  bucket covers it, else it waits; anything else for a phone that still has frames waiting
  queues behind them, in order. Handshake thread lists (steps 1 and 3) leave at once, ahead of
  waiting frames, and are charged even past zero; frames are sealed only as they leave, so
  sealing order is still wire order. Waiting frames are dropped when the relay socket drops, the
  phone is removed or says `hello`; its waiting chunk frames are also dropped when it sends a new
  `sync_request`. The phone catches up from its cursor.
- A phone the relay still drops redials, gets `.paired` again and asks from its cursor; the
  page that was cut off is sent again whole.

## Direct path

Capability `direct-v1` (`DirectCandidate.capability`, in `PeerInfoData.local`; a Mac with `[direct] enabled`
false leaves it and the candidates out of its host info). When the phone's
"Direct connection (LAN / Tailscale)" setting is on (off by default), it also dials the Mac's own
WebSocket listener on its LAN or VPN address. The relay stays the fallback and keeps its phone ->
Mac buffer; pairing, push and everything before the first relay join stay on the relay. Types are
in `packages/YorozuWire`: `DirectCandidate`, `DirectMessage`, `DirectProof` (`Crypto.swift`) and
`DirectCloseCode`.

### Candidates

The host's peer info (handshake step 3 and every later `thread_list`) carries
`directCandidates: [{host, port, kind}]`: at most 8, `host` an IPv4 or IPv6 literal without a zone,
`port` 1–65535, `kind` `"lan"` (a private Wi-Fi/Ethernet address) or `"vpn"` (a private address,
RFC 1918, 100.64.0.0/10 or ULA, on a `utun` interface). `PeerInfoData.isValid` enforces this; a
phone's claim carries none, and a host with its listener off sends none. The phone takes them only
from a peer exchange that negotiated `direct-v1`, keeps them in its Keychain pairing record
(`PairingStore.Stored.directCandidates`, so Remove host and Repair drop them) and replaces them on
every exchange. Diagnostics call a `vpn` candidate "Tailscale" only inside 100.64.0.0/10 or
fd7a:115c:a1e0::/48. The listener port is fixed, 8738 by default (`DirectMessage.defaultPort`).

### Wire

JSON text frames over `ws://host:port/`, at most 1 MiB each (`DirectMessage.maxBytes`); binary
strings are base64url without padding.

1. Mac -> phone on connect: `{"type":"nonce","nonce":<32 random bytes>}`.
2. Phone -> Mac: `{"type":"join","room":<roomId>,"pub":<phone Ed25519 key>,"sig":…,"nonce":<32 random bytes>}`,
   `sig` = Ed25519 over the UTF-8 of `yorozu-direct-v2|<room>|<Mac nonce>`
   (`DirectProof.signJoin` / `verifyJoin`). The Mac accepts only a key in `relay-devices.json`.
3. Mac -> phone: `{"type":"joined","pub":<Mac Ed25519 relay key>,"sig":…}`, `sig` over
   `yorozu-direct-v2-host|<room>|<phone nonce>` (`DirectProof.signJoined`). The phone accepts it only
   if base64url sha256(`pub`) equals the QR's `roomId` and the signature verifies
   (`DirectProof.verifyJoined`); a pairing without `roomId` never dials direct.
4. Both ways after `joined`: `{"type":"frame","frame":{"payload":…,"sig":…}}`, exactly the signed
   frame the relay carries (base64url frame-body JSON and the sender's signature over that string),
   one frame per message, the same `ChannelEnvelope` sealing and the same per-device
   `ChannelCounter`. The phone checks each signature against the `joined` key. Direct frames are never
   acked to the relay, and there is no `accepted`.
5. The phone pings every 10 s, `{"type":"ping","t":<epoch ms>}`, and the Mac answers
   `{"type":"pong","t":<same>}`; 5 s without the pong fails the leg. The Mac drops a link silent for
   more than 30 s.

Close codes: 4000 the Mac is going to sleep, 4001 unauthorized, 4002 superseded (a newer session took
the route), 4003 a message over 1 MiB.

### Session rules (phone)

- One `RelayClient`, one in-memory `ChannelCounter`, two socket kinds: `URLSessionWebSocketTask`
  for the relay, `NWConnection` + `NWProtocolWebSocket` for direct.
- Race: eligible direct candidates at t = 0, the relay about 300 ms later (at once when there are
  none, or when every direct leg has already failed). The first leg to an authenticated `joined`
  carries the session; `hello` and the peer exchange run on it alone. A direct winner cancels the
  others; a relay winner leaves direct legs running, and the first to authenticate takes over.
- Eligible: the setting on, the relay already knows the device, the candidate not backing off and
  not refused Local Network access, and its kind of network up (`NWPathMonitor`): `lan` only with a
  Wi-Fi or wired interface, `vpn` only with an `.other` interface. A `lan` socket never uses cellular.
- Upgrade, make-before-break: on a direct `joined` while on the relay, `hello` on the direct socket,
  then the relay socket closes.
- No downgrade while the direct heartbeat is healthy. A failed direct session hands over at once (a
  new race, the relay among it); a direct socket whose kind of network goes away closes at once.
- Re-race on foreground (`refreshDirect()`, which also retries refused candidates), on a real path
  change (another set of interfaces) and on failure. Per candidate, a failure backs off 30 s,
  doubling to 10 minutes; a path change resets every backoff, and a session that reaches `.paired`
  resets its own.
- Local Network: a socket iOS holds back with `.localNetworkDenied` waits (the prompt may be up) and
  is judged at its 10 s deadline; then that candidate is skipped until the next foreground or toggle
  and Settings shows one line pointing to Settings › Privacy & Security › Local Network.
- Every path switch is a new session: `.path`, `.joined`, `.paired`, then `PhoneModel` sends
  `sync_request` from its cursor and resends its outbox. The Mac dedupes by event id and channel
  seq; a relay-buffered frame overtaken by a direct session is dropped as a replay.
- `TransportUpdate.path(.relay | .directLAN(c) | .directVPN(c))` and `.direct(DirectReport)` are for
  Settings diagnostics only (path, last direct error, candidates, Copy diagnostics); the chat never
  shows the path.

## Event envelope

Every event is a `YorozuEvent`:

| Field | Phone -> Mac | Mac -> phone |
|---|---|---|
| `id` | `UUID().uuidString` (for `message`: the bubble's id) | records: the record's id; anything else: `UUID().uuidString` |
| `threadId` | the thread (`"main"`) | records and pages: the thread (`"main"`); control replies: `""` |
| `ts` | epoch ms, phone clock | records: the record's `created` (a task's or topic's too), `read_state`: now; others: now |
| `agentId` | `"device"` | `"main"` |
| `syncCursor` | unset | unset (0.7 uses `seq`, below) |

`clientTs` and `parentAgentId` are never set. All times inside payloads are epoch milliseconds
(`Int`), converted from the Mac's `Double` seconds with `Int(t * 1000)`.

## Handshake (peer-info), done before anything below

Handled by `RelayClient` on the phone and `RelayHost` on the Mac; `PhoneModel` and
`EngineBridge` never see it.

1. After a valid `hello`, the host's first sealed event is
   `.threadList(ThreadListData(threads: [main], peerInfoSupported: true))`.
2. The phone answers `.threadList(ThreadListData(threads: [], peerInfo: claim))` with event id
   `R`, where `claim` is `PeerInfoData.local` with `computerName` set to the phone's model name
   ("iPhone 17 Pro"; `DeviceModel.swift` maps the hardware identifier, unknown ones send "iPhone"
   or "iPad"). The host stores it as the device's `name` in `relay-devices.json`; a claim without
   it keeps the stored name, and a phone that never sent one is listed as "iPhone".
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
`RelayClient.swift`). Both ends advertise `PeerInfoData.local`: protocol 2 (`protocolMin` =
`protocolMax` = 2), capabilities `["peer-info","host-name","channel-sequence","yorozu-v2"]`,
required `["channel-sequence","yorozu-v2"]`. A v1 peer on either side therefore ends in "Update
required". Until a device's exchange succeeds, the host passes none of its other events to the
backend; a known device whose last result on file is compatible counts as succeeded (Mac-side
seams below).

`main` above is `ThreadSummary(id: "main", title: "Yorozu", archived: false, lastActivity:
newestMessageCreatedMs /* 0 if none */)`. A phone `thread_list` without `peerInfo` gets
`.threadList(ThreadListData(threads: [main], peerInfoSupported: true, peerInfo: host))` back.

### Versioning

- **A breaking change raises the protocol version** in `PeerInfoData.local` on both apps. Peers
  whose ranges do not overlap end in "Update required".
- **A feature added within 0.7 brings a new peer-info capability** (a name like `attachments`,
  added to `PeerInfoData.local.capabilities`). Each side reads the negotiated
  `.compatible(version:capabilities:)` list and hides or never sends the feature when the peer
  lacks it. New kinds and new optional fields that an older 0.7 peer can ignore follow this rule;
  they are never made required.
- Unknown kinds decode as `.unknown(kind:data:)`, and so does a known kind whose data does not
  decode. Both sides ignore them.

### The 0.6.x refusal

A 0.6.x phone advertises protocol 1, which does not overlap the Mac's 2. The Mac sends it
`peerInfoError: "Update Yorozu on this iPhone to talk to this Mac."` and serves it nothing else;
the 0.6.x phone shows that reason in Settings. Once it runs 0.7 the same pairing works without
pairing again (the device's stored `compatible` result is dropped because its `hostProtocol`
differs, and the next claim decides). A 0.7 phone that meets a 0.6.x Mac gets the Mac's own
0.6.x reason; if it ever computes the mismatch itself it reads "Update Yorozu on the Mac to
talk to this iPhone." (`PeerInfoData.compatibility(with:)` words both from the phone's side,
since the phone is where they are read).

## History window

The phone caches, and catch-up serves, the **history window**: the newest 500 messages plus every
message younger than 30 days (the union), with the topics, tasks, amendments, worker events and
read cursors that belong to it. Older history is reached only through
[search and page requests](#search_request--search_result-search).

- A phone with no cache (`afterSeq` absent or 0), a newly paired phone, or a cursor that is
  stale gets the window from its start, not the whole history. The first reply page then has
  `reset: true`, and the phone drops its cache before applying it.
- A cursor is stale when it is greater than the Mac's latest sequence (another database) or lower
  than the smallest `seq` of any message in the window (every message the phone could hold
  changed since, so nothing is kept).
- The phone trims its cache to the window by its own clock and count when it loads and saves it,
  keeping unsuppressed active or uncertain tasks as the Mac does.
- A topic that a new message or task starts using is re-stamped, so an old topic re-entering the
  window reaches the phone.

## Change sequence

The Mac stamps every row of `topics`, `messages`, `work`, `events`, `amendments` and
`readCursor` with a database-wide change sequence (`seq`), bumped in the same transaction as each
insert and update (topic assignment, task state, amendment state, routing start). Every record
event carries its row's `seq`.

- **Upsert rule.** The phone keys records by kind and id and replaces a held record only with
  one of a higher `seq` (`worker_event` is insert-only; a known id is skipped). Records can
  arrive out of order across pages, live updates and page replies; this rule makes that safe.
  Messages change after insert in 0.7 (topic, task and notice can be set later, and a user
  message changes once more when routing starts and sets `readAt`), so a stored message must be
  replaced, not kept.
- **Cursor.** The phone's cursor is the `latestSeq` of the last page it applied whole. It is
  kept in the cache.

## Event kinds

| Kind | Direction | Payload | Notes |
|---|---|---|---|
| `message` | phone -> Mac | `MessageData` | send a user message |
| `receipt` | Mac -> phone | `ReceiptData` | message stored |
| `admission_status` | Mac -> phone | `AdmissionStatusData` | message refused |
| `sync_request` | phone -> Mac | `SyncRequestData` | catch up after a cursor |
| `sync_delta` | Mac -> phone | `SyncDeltaData` | reply page, live update or page reply |
| `message` | Mac -> phone, in pages | `MessageData` | record, upsert |
| `topic` | Mac -> phone, in pages | `TopicData` | record, upsert |
| `task` | Mac -> phone, in pages | `TaskData` | record, upsert |
| `amendment` | Mac -> phone, in pages | `AmendmentData` | record, upsert |
| `worker_event` | Mac -> phone, in pages | `WorkerEventData` | record, insert-only |
| `read_state` | both | `ReadStateData` | read cursor; a record when Mac -> phone |
| `task_control` | phone -> Mac | `TaskControlData` | Stop or Retry |
| `task_control_result` | Mac -> phone | `TaskControlResultData` | its outcome |
| `search_request` | phone -> Mac | `SearchRequestData` | full-history search |
| `search_result` | Mac -> phone | `SearchResultData` | hits |
| `page_request` | phone -> Mac | `PageRequestData` | the page around one message |
| `device_remove` | phone -> Mac | `DeviceRemoveData` | remove the sender's own record |
| `chunk` | Mac -> phone | `ChunkData` | one slice of an oversized event |
| `thread_list` | both | `ThreadListData` | peer-info only (handshake) |

Record kinds travel only inside `sync_delta.events`. Everything else is a top-level event. The
host ignores every other kind (no reply, no receipt); the phone ignores kinds it does not show.
The vendored v1 kinds `thread_read`, `interrupt`/`stop_status` and
`thread_search_request`/`thread_search_result` are not used by v2.

### `message` (phone -> Mac): send a user message

```swift
YorozuEvent(id: UUID().uuidString, threadId: "main", ts: nowMs, agentId: "device",
            payload: .message(MessageData(role: .user, text: text, admissionDeadline: nowMs + 86_400_000)))
```

- `text` is 1-6000 UTF-8 bytes after the phone's own check. No attachments.
- `ts` is the phone's send time; the Mac keeps it as the message's `sentAt`. Resend renews it.
- `admissionDeadline` is always `ts` + 24 h, the relay buffer's lifetime. Resend renews it.
- `delivery`, `channelModel`, `sentAt`, `readAt` and the other 0.7 metadata are not sent and the
  host ignores them.

#### The phone's outbox

Every message goes into a persistent outbox first (`Outbox.swift`, one file per pairing, see
`docs/setup.md`), so Send works with or without a link. Each item holds the event, its send time,
the relay's `accepted` time and `buffered` flag, whether the Mac has stored it, and a refusal
reason. The marks live beside the items in a forward-only id -> state map (below).

- On every relay join (`.joined`, the Mac away), send the items still Sending. Items the relay
  already holds (Delivered) are not sent again while the Mac is away.
- On every `.paired`, send every item the Mac has not stored, Sending or Delivered. The Mac
  dedupes by id (host check 4), so a resend is never a second message.
- An item stops being sent on a `receipt` or when its stored copy arrives, never on `accepted`.
  Its times stay until the stored copy carries `readAt`, then the item goes.
- `admission_status` (`rejected` or `expired`) clears the item from the send queue: it is Not
  delivered and is never resent on its own. **Resend** keeps the id with a new `ts` and
  deadline; **Delete** removes the bubble and the item.
- An item that never got `accepted` and whose deadline passed turns Not delivered on the phone
  without the Mac ("This iPhone couldn't send it within 24 hours.").

#### Marks

| Mark | Symbol | Phone evidence |
|---|---|---|
| Sending | `circle.dotted` (spins while a frame is in flight) | in the outbox, no `accepted` or stored copy yet |
| Delivered | `checkmark.circle` | `accepted`, a `receipt`, or the stored copy without `readAt` |
| Read | `checkmark.circle.fill` | the stored copy has `readAt` |
| Not delivered | `exclamationmark.circle`, red | `admission_status`, or the local deadline |

States only move forward (Sending -> Delivered -> Read); a late `accepted` after Read is ignored.
Not delivered goes back to Sending only through Resend, but a stored copy still lifts it to
Delivered or Read, since that proves the Mac has it. Without a relay `accepted` (an old relay),
the mark spins for at most 10 s per frame and stays Sending until the Mac's `receipt`; while
that link stays up its status word stays "Sending", not "Waiting for connection". User
messages typed on the Mac, and those in sub-chats, take their mark from the stored copy alone.

Host checks, in this order, then acts:

1. `id` matches `^[A-Za-z0-9-]{1,64}$`, else `admission_status rejected`.
2. `attachments` is empty, else `admission_status rejected`.
3. `RuntimeMode.permitsInput(fixtureAcknowledged: false)` is true (fixture mode never takes
   phone input), else `admission_status rejected`.
4. If a v2 `Message` with that id exists: reply `receipt` only (duplicate or relay replay).
5. If `admissionDeadline` is set and has passed: reply `admission_status expired`; the message
   is never stored or routed late.
6. `try await engine.send(text, id: event.id, sentAt: ts / 1000)`, then reply `receipt`.
   If it throws: if a `Message` with that id now exists (a concurrent duplicate won), reply
   `receipt`; else reply `admission_status rejected` with `reason = error.localizedDescription`.

The Engine is never told which device a message came from; it gets the send time only.

### `receipt` (Mac -> phone): the message is stored

```swift
YorozuEvent(id: UUID().uuidString, threadId: "", ts: nowMs, agentId: "main",
            payload: .receipt(ReceiptData(eventId: messageId)))
```

The phone marks the item stored (Delivered) and stops sending it. The bubble stays; the stored
copy arrives as a record with the same id and replaces it in place.

### `admission_status` (Mac -> phone): the message was refused

```swift
YorozuEvent(id: UUID().uuidString, threadId: "", ts: nowMs, agentId: "main",
            payload: .admissionStatus(AdmissionStatusData(eventId: messageId, status: .rejected, reason: reason)))
```

`status` is `.rejected` or `.expired`. `reason` is user-facing text the phone shows after "Not delivered: ", as is for
`rejected`; for `expired` the phone shows its own localized copy of the same sentence:

| Cause | `status` | `reason` |
|---|---|---|
| bad id | `rejected` | `"Invalid message id."` |
| attachments | `rejected` | `"Attachments aren't supported yet."` |
| fixture mode | `rejected` | `"This Mac is in fixture mode and doesn't take phone messages."` |
| Engine error | `rejected` | `error.localizedDescription` (e.g. "Message must be 1–6000 UTF-8 bytes.") |
| past `admissionDeadline` | `expired` | `"Your Mac was offline for more than 24 hours."` |

Either status clears `messageId` from the phone's send queue: the bubble shows Not delivered with
the reason, Resend and Delete, and is not resent on its own.

### `sync_request` (phone -> Mac): catch up

```swift
YorozuEvent(id: UUID().uuidString, threadId: "main", ts: nowMs, agentId: "device",
            payload: .syncRequest(SyncRequestData(threadId: "main", afterSeq: cursor)))
```

- Sent on every `.paired`, again whenever a reply page has `more == true`, and again when
  neither a reply page nor a `chunk` arrived within 15 s (each chunk restarts the deadline).
- `afterSeq` is the phone's cursor; nil or 0 when it has no cache.
- `lastSeen` is `[:]` (encoded as `{}`, still required by the decoder); `focusThreadId` and
  `includeCurrent` are unset and ignored.

The host always answers with one reply page, an error page if it cannot read its store.

### `sync_delta` (Mac -> phone): records and status

```swift
YorozuEvent(id: UUID().uuidString, threadId: "main", ts: nowMs, agentId: "main",
            payload: .syncDelta(SyncDeltaData(events: records, threadId: "main",
                workingThreadIds: working ? ["main"] : [], more: more ? true : nil,
                routingThreadIds: routing ? ["main"] : [], afterSeq: after, latestSeq: next,
                reset: reset ? true : nil)))
```

Fields:

- `events`: record events in `seq` order (see the record kinds below).
- `workingThreadIds`: threads with any `Work.active` outside job topics; the global working spinner. Always present.
- `routingThreadIds`: threads whose secretary is routing a message (`Engine.routing`); the
  thinking bubble. Always present.
- `afterSeq`: the cursor these changes continue from.
- `latestSeq`: the phone's next cursor after applying this page: the last record's `seq` while
  `more == true`, else the Mac's latest sequence (`ChangePage.latest`).
- `more`: `true` when changes remain after `latestSeq`, else nil.
- `reset`: `true` on the first reply page of a [window start](#history-window).
- `requestId`: set only on a page reply (below).
- `error`: user-facing text when the Mac could not read its store; no events, cursor unchanged.
- `current` is unset.

Three flavours:

- **Reply page** (`requestId == nil`, answers a `sync_request`): the window's changes after the
  request's `afterSeq`, at most 200 records and 256 KiB of encoded events (at least one record if
  any remain); `afterSeq` echoes the request.
- **Live update** (`requestId == nil`, `more == nil`, `latestSeq` set): sent unprompted to every
  paired device when the Mac's latest sequence moved past the last one it published, or the
  working or routing flag changed. `afterSeq` is the previous live update's `latestSeq`.
  `events` may be empty when only a flag changed. More than 200 changes go out as several live
  updates.
- **Page reply** (`requestId` set, answers a `page_request`): the messages around the asked-for
  message, inside or outside the window, in timeline order. `afterSeq`, `latestSeq` and `more`
  are unset and it never moves the cursor. An unknown message id gets no events and
  `error: "Message not found."`; a page whose encoding would pass what 256 chunks carry gets
  `error: "That part of the chat is too large to send."`.

A `sync_request` or `page_request` for a thread the Mac does not have gets no events and
`error: "Unknown thread."`.

Phone rules:

1. Apply every record by the [upsert rule](#change-sequence). A sent bubble holds the phone's
   `ts` until its stored copy (same id) replaces it.
2. On every `.paired`, set `catchingUp = true` and send `sync_request` with the cursor.
3. On a reply page: if `reset`, drop the cache; apply; set the cursor to `latestSeq`; if
   `more == true` send the next `sync_request`, else `catchingUp = false`. On `error`, keep the
   cursor, show nothing new and ask again on the next `.paired` or deadline.
4. On a live update: apply; set the cursor to `latestSeq` only when `!catchingUp` and its
   `afterSeq` is not greater than the cursor (no live update was missed). A greater `afterSeq`
   while not catching up starts a catch-up at once (`catchingUp = true`, `sync_request`); while
   catching up, that catch-up fills the gap. Re-applying is safe by rule 1.
5. On a page reply: apply its messages for display; keep the ones outside the window out of the
   cache.
6. The flags are only true while `.paired`. While not paired the phone shows "status unknown"
   for the working indicator, the thinking bubble and topic statuses, never idle.

### Record kinds (inside `sync_delta.events`)

All carry `threadId: "main"`, `agentId: "main"`, `id` = the record's id and `ts` = its `created`
in ms (an `amendment` or `read_state` record, which has no `created`: now).

**`message`** (`MessageData`, upsert):

```swift
MessageData(role: m.role == "user" ? .user : .agent, text: m.body, done: true,
            failed: m.kind == "failure" ? true : nil, kind: m.kind, topicId: m.topicID,
            taskId: m.taskID, replyTo: m.replyTo, notice: m.notice.map { NoticeData(code: $0.code, params: $0.params) },
            seq: Int(seq))
```

`kind` is the v2 message kind as text (`conversation`, `result`, `failure`, `question`,
`acknowledgment`, ...); the phone treats an unknown kind like `conversation`. A user
message also carries `readAt` (epoch ms, when the Mac started routing it, the Read mark; absent
before that) and `sentAt` (epoch ms, the `ts` of the phone event it was admitted from; absent for
one typed on the Mac). Both are optional fields an older 0.7 peer ignores; they shipped inside
0.7 because 0.7 had not reached a phone yet (#314). The phone shows a delay line in a message's
details when the Mac's `created` is more than 60 s after `sentAt`. Every message goes to the main timeline as on the Mac; `topicId` also files it in
its sub-chat.

**`topic`** (`TopicData`, upsert): `id`, `label`, `created`, `seq`.

**`task`** (`TaskData`, upsert): `id`, `topicId`, `messageId` (the message that started it),
`instruction`, `executor` (nil = thinking worker, else `claude` or `codex`), `state` (the Mac's
work state as text), `revision`, `suppressed`, `error`, `result`, `created`, `seq`. The phone
derives a topic's status with the Mac's rule (`docs/architecture.md`).

**`amendment`** (`AmendmentData`, upsert): `id`, `taskId`, `messageId`, `revision`,
`instruction`, `state`, `seq`.

**`worker_event`** (`WorkerEventData`, insert-only): `id`, `taskId`, `kind`, `body`, `created`,
`seq`.

**`read_state`** (`ReadStateData`): `threadId`, `messageId`, `seq` (below).

### `read_state` (both directions): read cursor

The Mac holds one read cursor per thread: the newest message seen on any device. It only moves
forward.

```swift
YorozuEvent(id: UUID().uuidString, threadId: "main", ts: nowMs, agentId: "device",
            payload: .readState(ReadStateData(threadId: "main", messageId: newestSeenId)))
```

- Phone -> Mac: sent when the newest message on screen changes while the app is active and the
  chat is shown. The user's own messages never count as unread. No reply.
- The Mac ignores an unknown message id and one not newer (`created`, then row order) than the
  held cursor. A cursor that moved is a changed `readCursor` row, so it reaches every phone as a
  `read_state` record with `seq` in the next live update (and in catch-up).
- The phone applies a record by the upsert rule and draws the unread divider after that message.

### `task_control` / `task_control_result`: Stop and Retry

```swift
// phone -> Mac
YorozuEvent(id: UUID().uuidString, threadId: "main", ts: nowMs, agentId: "device",
            payload: .taskControl(TaskControlData(requestId: rid, taskId: task.id, action: .stop /* or .retry */)))
// Mac -> phone
YorozuEvent(id: UUID().uuidString, threadId: "", ts: nowMs, agentId: "main",
            payload: .taskControlResult(TaskControlResultData(requestId: rid, taskId: task.id, accepted: o.accepted,
                text: o.text, notice: o.notice.map { NoticeData(code: $0.code, params: $0.params) }, messageId: o.messageID)))
```

- The Mac calls `Engine.stopTask(id:)` or `Engine.retryTask(id:)` (no secretary call) and replies
  with the `TaskOutcome`. Stop needs active or uncertain work; Retry needs failed or uncertain,
  unsuppressed work and never starts a duplicate. Any acknowledgment or failure message is
  posted in the task's topic, replying to the task's original message, and reaches the phone as
  a record; no user message is created.
- The phone sends one `task_control` per tap, only while `.paired`, and keeps that button
  disabled until the result or a change to that task arrives. It is never queued or resent.
- `text` is user-facing; `notice` lets the phone render it in its own language.
- A replayed `task_control` (same `requestId`, among the Mac's last 64) gets its first result
  again and does not run again (`EngineBridge`); an older one runs again, and the Engine's guards
  make that a no-op with `accepted: false`.

### `search_request` / `search_result`: search

```swift
// phone -> Mac
.searchRequest(SearchRequestData(requestId: rid, query: query, offset: offset /* nil = 0 */))
// Mac -> phone, threadId ""
.searchResult(SearchResultData(requestId: rid, hits: hits, total: total, nextOffset: next))
```

- The Mac runs `Engine.search(query, limit: 50, offset:)` over its full history, main timeline
  and sub-chats.
- Each hit is `SearchHitData{threadId, topicId?, taskId?, messageId?, eventId?, snippet,
  created}`: a message hit has `messageId` (and `topicId` when filed in a topic); a worker-event
  hit has `eventId`, `taskId` and `topicId`.
- `total` is the full hit count; `nextOffset` is `offset + hits.count` while more remain, else
  nil. A failure sends no hits, `total: 0` and a user-facing `error`.
- Search needs `.paired`; the phone ignores a result whose `requestId` is not its latest.

### `page_request`: the page around one message

```swift
.pageRequest(PageRequestData(requestId: rid, threadId: "main", messageId: id))
```

Answered with a page reply (`sync_delta` with `requestId`, above): `Store.page(around:)`, up to
50 older and 50 newer messages. The phone uses it for a search hit outside its cache.

### `device_remove` (phone -> Mac): forget this phone

```swift
.deviceRemove(DeviceRemoveData(pub: myBoxPub)) // the phone's own X25519 public key, base64url
```

- Sent by Remove host and by confirming any new pairing (Repair, or a code for another Mac),
  over the current link and only while `.paired`, before the phone wipes its pairing and cache.
  No reply; the phone does not wait for one.
- The Mac acts only when `pub` is the sender's own key: it drops that `RelayDevice`, revokes it
  at the relay and announces the device list (`RelayHost.removeDevice`). Any other `pub` is
  ignored; a phone can remove only itself.
- If the phone cannot reach the relay it wipes anyway; the Mac's record stays until removed in
  Mac Settings.

### `chunk` (Mac -> phone): oversized events

An event whose JSON encoding exceeds 256 KiB (`ChunkData.budget`) is sent as a set of ordered
`chunk` events instead: `ChunkData{id, index, count, data}`, where `id` names the set, `index`
runs `0..<count`, `count` is 2...256 and `data` is base64 of up to 192 KiB
(`ChunkData.slice`) of the encoding.

- Mac: `try event.chunked()` returns the event itself or its chunk events; send a set back to
  back, never interleaved with another set to the same phone, paced as
  [above](#relay-limits-and-pacing). Any top-level event may be chunked; in practice it is a
  `sync_delta` page holding one large record, so the page stays whole and the cursor rules are
  unchanged.
- Phone: feed every `chunk` to one `ChunkAssembler`; `add(_:)` returns the whole event after the
  last chunk, which is then handled as if it had arrived directly. A chunk that does not continue
  the current set drops the partial set; a dropped page is asked for again by the 15 s deadline,
  which each chunk restarts.
- Worker output has no size limit, so a record could pass what 256 chunks (48 MiB) carry. The
  Mac caps every record at 256 chunks less 64 KiB for the page around it: a larger one keeps the
  head of its long text fields (a message's `text`; a task's `instruction`, `result` and `error`;
  an amendment's `instruction`; a worker event's `body`), each followed by
  `"\n\n…(truncated; the full text is on the Mac)"`, and the Mac logs it. An event that still
  cannot be chunked is logged and not sent.

## Notice codes

A `message` record or `task_control_result` may carry `notice{code, params}`, the Mac's
`Notice` (`Sources/ProjectXCore/Models.swift`). The phone renders known codes as system rows from
its own string catalog in its language (English and Japanese), and falls back to the message's
English `text` for an unknown code. Raw error text is only ever in `params["error"]`.

Codes in 0.7: `question`, `question_topic`, `question_task`, `routing_failed`, `offline`,
`task_failed`, `task_overflow`, `interrupted_by_restart`, `compaction_failed`, `memory_skipped`,
`retry_running`, `retry_not_allowed`, `correction_blocked`, `earlier_stopped_with_change`,
`earlier_finished_change`, `earlier_running`, `earlier_unknown`, `change_queued`, `change_sent`,
`change_held`, `change_after_finish`, `not_running`, `stopped`, `stopping`, `moved`,
`moved_stopping`, `correction_saved`, `earlier_retired`, `memory_forgotten`,
`amendment_unconfirmed`, `closed_too_long`, `task_control_failed`, `config_invalid`,
`settings_changed`. A new code needs no capability: the fallback covers it.

## Mac-side seams

- `RelayBackend` (`YorozuWire/RelayBackend.swift`): `func handle(_ e: YorozuEvent) async -> [YorozuEvent]`.
  `RelayHost` passes it each decrypted phone event other than the peer-info `thread_list`, one at
  a time in arrival order and off the receive path (so hellos and claims never wait on the
  Engine), and seals the returned events back to that same device only. `EngineBridge`
  implements it (`message`, `sync_request`, `read_state`, `task_control`, `search_request`,
  `page_request` in; `receipt`, `admission_status`, `sync_delta`, `task_control_result`,
  `search_result` out). `device_remove` needs the sender's key, so `RelayHost` handles it.
- Duplicate check (host check 4): `Store.message(id:)`, a keyed lookup.
- Acks for replayed frames: the ack is cumulative, so the host sends `ack{seq}` for a replayed
  frame only after the backend has handled it and every phone event before it, that is once the
  Engine stored or refused its message. A frame that can never be handled (not a frame, unknown
  key, malformed, a replayed channel seq, a device that must update) is acked too. A `hello`
  whose device list could not be written stops acks on that socket from its seq on; the relay
  replays them on the next registration. Acks queued for an earlier socket are never sent on a
  new one.
- Held boxes: a box from a device that has no peer-info result yet (and is not its claim) is kept
  in memory with its relay seq, at most 64 a device (later ones are dropped), unaccepted and
  unacked; acks stop from its seq on. A compatible claim passes the held boxes to the backend in
  order after the reply; any other result drops them. Either way acks then resume up to the
  newest relay seq, behind the handled boxes. A new socket forgets held boxes; the relay replays
  them.
- Channel counter: a box is accepted in memory on arrival, for ordering, but its `recv` is
  written to the device file only after the backend has handled it, so a quit in between makes
  the replay acceptable again. The Engine answers a re-sent message id with its `receipt`.
- Peer-info result on file: the last `.compatible` result is kept in the device's record as
  `compatible{version, capabilities, hostProtocol}`, where `hostProtocol` is
  `PeerInfoData.local.protocolMax` when it was computed. At launch a record whose `hostProtocol`
  matches serves the device from its first frame; another protocol drops it and the next claim
  decides. A `hello` from a known device keeps a `.compatible` result and restarts the exchange
  (step 1); each claim replaces the result, and one that is not compatible clears it.
- Live updates come from `Store.changes(after:)` past the last published sequence and go out
  through `RelayHost.broadcast([YorozuEvent])` to every paired device, chunked when needed.
- `Engine.send(_:id:sentAt:)` / `Store.message(..., id:, sentAt:)` keep the phone's `id` as the
  v2 `Message.id`, so the phone's bubble and the stored message are one entry, and its `ts` as
  `Message.sentAt`.
- Paired devices live in `relay-devices.json` (`RelayDevice`): keys, `pairedAt` and the channel
  counter, plus optional `name` (from the claim), `label` (renamed on the Mac with
  `RelayHost.rename(_:label:)`; blank clears it), `lastSeen` and `compatible` (above). Files
  without the optional fields still load.
- A relay host that cannot start (Keychain, device file) is started again every 30 s.
- Presence: the relay reports none. A device is online once one of its sealed frames opens on
  the current relay connection, and stays so until that socket drops. `lastSeen` is the time of
  its last opened frame; it is written with the next counter or device-list write.
  `RelayStatus.devices` carries `{pub, name, label, pairedAt, online, lastSeen}` per device.
