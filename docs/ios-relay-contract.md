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
Mac's full history and removes its own pairing. The relay wakes it with [push](#push), whose words are
[sealed](#sealed-previews) for the phone.

Out of scope for 0.7:
typing in sub-chats (other than a job's own input, [Jobs](#jobs)), multiple threads (the thread id is carried everywhere and never hard-wired
beyond the one thread `"main"`).

## Transport (unchanged v1 relay)

- Relay: `wss://relay.yumi.to`, protocol unchanged. Pairing is `QrPayload` (v1 QR or `yorozu://pair`).
  The Mac's pair sheet shows the QR, the code as text (the QR's own `https://yorozu.yumi.to/pair#…`
  link, which the phone's manual entry takes, as it takes `yorozu://pair?…`) and the Mac key,
  `QrPayload.fingerprint` (the session key's first 8 bytes, uppercase hex in groups of two bytes:
  `3F9A 1C07 B2E4 55D0`), which the phone's confirmation shows too. The phone claims
  `applinks:yorozu.yumi.to`, so the system Camera opens the link in the app.
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
  [chunked](#chunk-mac---phone-oversized-events)).
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
- Attachment transfers are request-driven too ([Attachments](#attachments)): one
  `attachment_download_chunk` (at most 160 KiB of file, never split into `chunk`s) per request, at most
  two requests in flight per phone, and the Mac drops a download chunk for a phone that already has two
  waiting behind the bucket. Phone -> Mac, one upload chunk is in flight at a time.

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
`directCandidates: [{host, port, kind}]`: at most 8, `host` an IP literal without a zone (IPv4 as a
plain dotted quad, no shorthand such as `10.1`), `port` 1–65535, `kind` `"lan"` (RFC 1918 or ULA
fc00::/7, on Wi-Fi/Ethernet) or `"vpn"` (RFC 1918, 100.64.0.0/10 or ULA, on a `utun` interface).
Loopback, unspecified, link-local and public addresses are never candidates.
`DirectCandidate.isValid` (through `PeerInfoData.isValid`) enforces this with `DirectCandidate.allows`,
the same test the Mac uses for what it advertises and accepts; a phone's claim carries none, and a
host with its listener off sends none. The phone takes them only
from a peer exchange that negotiated `direct-v1`, keeps them in its Keychain pairing record
(`PairingStore.Stored.directCandidates`, so Remove host and Repair drop them) and replaces them on
every exchange. Diagnostics call a `vpn` candidate "Tailscale" only inside 100.64.0.0/10 or
fd7a:115c:a1e0::/48. The listener port is fixed, 8738 by default (`DirectMessage.defaultPort`).

### Wire

JSON text frames over `ws://host:port/`, at most 1 MiB each (`DirectMessage.maxBytes`); binary
strings are base64url without padding.

The Mac proves its key before the phone reveals anything about itself:

1. Phone -> Mac on connect: `{"type":"probe","room":<roomId>,"nonce":<32 random bytes>}`. The Mac
   answers only a probe for its own room with a 32-byte nonce; anything else closes with 4001.
2. Mac -> phone: `{"type":"joined","pub":<Mac Ed25519 relay key>,"sig":…,"nonce":<32 random bytes>}`,
   `sig` = Ed25519 over the UTF-8 of `yorozu-direct-v2-host|<room>|<phone nonce>`
   (`DirectProof.signJoined`). The phone accepts it only if base64url sha256(`pub`) equals the QR's
   `roomId` and the signature verifies (`DirectProof.verifyJoined`), and the nonce is 32 bytes;
   otherwise the leg fails without the phone sending anything more. A pairing without `roomId` never
   dials direct.
3. Phone -> Mac: `{"type":"join","room":<roomId>,"pub":<phone Ed25519 key>,"sig":…}`, `sig` over
   `yorozu-direct-v2|<room>|<Mac nonce>` (`DirectProof.signJoin` / `verifyJoin`). The Mac accepts only
   a key in `relay-devices.json`, and closes with 4001 otherwise. The phone treats its leg as
   authenticated once it has sent the join (it does not wait for a reply), so `hello` follows the join
   on the same socket; a refused join surfaces as the 4001 close.
4. Both ways after the join: `{"type":"frame","frame":{"payload":…,"sig":…}}`, exactly the signed
   frame the relay carries (base64url frame-body JSON and the sender's signature over that string),
   one frame per message, the same `ChannelEnvelope` sealing and the same per-device
   `ChannelCounter`. The phone checks each signature against the `joined` key. Direct frames are never
   acked to the relay, and there is no `accepted`.
5. The phone pings every 10 s, `{"type":"ping","t":<epoch ms>}`, and the Mac answers
   `{"type":"pong","t":<same>}`; 5 s without the pong fails the leg. The Mac drops a link silent for
   more than 30 s.

The Mac closes a connection that has not sent a valid join 10 s after it was accepted. It takes
connections only on a private local address that it would advertise (RFC 1918/ULA on `en*`, plus
100.64.0.0/10 on `utun*`) whose path's first interface is Wi-Fi or wired Ethernet (`lan`) or `.other`
(`utun`); any other is closed with 4001 unheard. A `hello` on a direct link moves the phone's route
to it (closing an older link with 4002); a relay `hello` moves it back, except one the relay replays
from its buffer (it carries `seq`) or a live one (no `seq`) that arrives within 2 s of the direct
link's own `hello` while that link is still heard: both are older than the direct link and leave the
route alone. The domain strings keep the two signatures from
standing for each other or for a relay join, which signs a bare nonce.

What a LAN sniffer sees: the `room` in the probe travels in cleartext. It is a stable hash of the
Mac's Ed25519 key, so it links connections to the same Mac across networks; the phone's key, and so
its identity, is no longer sent to anyone who has not first proved they hold that Mac's key. Frames
stay sealed end to end.

Close codes: 4000 the Mac is going to sleep (sent on `NSWorkspace.willSleepNotification` to every link,
and to every new connection until `didWakeNotification`), 4001 unauthorized, 4002 superseded (a newer
session took the route), 4003 a message over 1 MiB.

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
  resets its own. A 4000 close backs off every candidate at once, so the next race goes straight to the
  relay; a 4002 close backs off none and re-races at once.
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
`protocolMax` = 2), capabilities `["peer-info","host-name","channel-sequence","yorozu-v2","direct-v1","attachments-v1","readiness-v1","jobs-v1","push-preview-v1"]`,
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
`peerInfoError: "Update Yorozu on this device to talk to this host."` and serves it nothing else;
the 0.6.x phone shows that reason in Settings. Once it runs 0.7 the same pairing works without
pairing again (the device's stored `compatible` result is dropped because its `hostProtocol`
differs, and the next claim decides). A 0.7 phone that meets a 0.6.x Mac gets the Mac's own
0.6.x reason; if it ever computes the mismatch itself it reads "Update Yorozu on the Mac to
talk to this iPhone." (`PeerInfoData.compatibility(with:)` words both from the phone's side,
since the phone is where they are read).

## History window

The phone caches, and catch-up serves, the **history window**: the newest 500 main-timeline messages plus every
message younger than 30 days (the union; a job sub-chat's own messages only the latter), with the topics, tasks, amendments, worker events and
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
  one of a higher `seq`. A `worker_event` changes after insert only when the images a worker shared
  in it are attached ([Attachments](#attachments)), which re-stamps its `seq`. Records can
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
| `worker_event` | Mac -> phone, in pages | `WorkerEventData` | record, upsert by `seq` (`files` added later) |
| `read_state` | both | `ReadStateData` | read cursor; a record when Mac -> phone |
| `task_control` | phone -> Mac | `TaskControlData` | Stop or Retry |
| `task_control_result` | Mac -> phone | `TaskControlResultData` | its outcome |
| `search_request` | phone -> Mac | `SearchRequestData` | full-history search |
| `search_result` | Mac -> phone | `SearchResultData` | hits |
| `page_request` | phone -> Mac | `PageRequestData` | the page around one message |
| `device_remove` | phone -> Mac | `DeviceRemoveData` | remove the sender's own record |
| `chunk` | Mac -> phone | `ChunkData` | one slice of an oversized event |
| `thread_list` | both | `ThreadListData` | peer-info only (handshake) |
| `attachment_chunk` | phone -> Mac | `AttachmentChunkData` | upload bytes ([Attachments](#attachments)) |
| `attachment_progress` | Mac -> phone | `AttachmentProgressData` | what is staged |
| `attachment_commit` | phone -> Mac | `AttachmentCommitData` | send a message with files |
| `attachment_download_request` | phone -> Mac | `AttachmentDownloadRequestData` | a file or thumbnail chunk |
| `attachment_download_chunk` | Mac -> phone | `AttachmentDownloadChunkData` | its answer |
| `readiness` | Mac -> phone | `ReadinessData` | whether the Mac can answer ([`readiness`](#readiness-mac---phone-can-the-mac-answer)) |
| `job_list` | Mac -> phone | `JobListData` | every scheduled job ([Jobs](#jobs)) |
| `job_control` | phone -> Mac | `JobControlData` | Pause, Resume, Run now or Delete one job; answered with `admission_status` |

Record kinds travel only inside `sync_delta.events`. Everything else is a top-level event. The
host ignores every other kind (no reply, no receipt); the phone ignores kinds it does not show.
The vendored v1 kinds `thread_read`, `interrupt`/`stop_status` and
`thread_search_request`/`thread_search_result` are not used by v2.

### `message` (phone -> Mac): send a user message

```swift
YorozuEvent(id: UUID().uuidString, threadId: "main", ts: nowMs, agentId: "device",
            payload: .message(MessageData(role: .user, text: text, admissionDeadline: nowMs + 86_400_000)))
```

- `text` is 1-6000 UTF-8 bytes after the phone's own check. `attachments` stays empty: a message
  with files is an [`attachment_commit`](#attachments) instead, text and files as one unit.
- `ts` is the phone's send time; the Mac keeps it as the message's `sentAt`. Resend renews it.
- `admissionDeadline` is always `ts` + 24 h, the relay buffer's lifetime. Resend renews it.
- `jobId` (`jobs-v1` only) makes it that job's own input ([Jobs](#jobs)); absent for the main chat.
- `replyTo`, set when the user replied to a stored main-timeline message, is that message's id; the host files the
  reply with its target's topic. Absent otherwise.
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
2. `attachments` (v1 inline files) is empty, else `admission_status rejected`.
3. `RuntimeMode.permitsInput(fixtureAcknowledged: false)` is true (fixture mode never takes
   phone input), else `admission_status rejected`.
4. If a v2 `Message` with that id exists: reply `receipt` only (duplicate or relay replay).
5. If `admissionDeadline` is set and has passed: reply `admission_status expired`; the message
   is never stored or routed late.
6. `try await engine.send(text, id: event.id, sentAt: ts / 1000)` (with `jobId`:
   `engine.sendToJob(jobID:body:id:sentAt:)`), then reply `receipt`.
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
| inline v1 attachments | `rejected` | `"Update Yorozu on this device to send attachments."` |
| bad commit files | `rejected` | `"Up to 10 files of at most 50 MB each."` |
| fixture mode | `rejected` | `"This Mac is in fixture mode and doesn't take phone messages."` |
| Engine error | `rejected` | `error.localizedDescription` (e.g. "Message must be 1–6000 UTF-8 bytes.") |
| past `admissionDeadline` | `expired` | `"The host was offline for more than 24 hours."` |

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
its sub-chat. The exception is the job-only kinds (`job_input`, `job_result`, `job_note`), which
stay in their job's sub-chat and reach only a phone that negotiated `jobs-v1`; a job run's trigger
(`job_run`) reaches no phone ([Jobs](#jobs)). A message with files (a user message or a result alike) carries `files`, their
[descriptors](#descriptors), in order; absent when it has none.

**`topic`** (`TopicData`, upsert): `id`, `label`, `created`, `seq`, and `attachedTo`: the id of the topic this sub-chat was attached to (#348), absent when none. Its later work is filed under that topic; its own history stays here. An optional field inside 0.7 that an older phone ignores.

**`task`** (`TaskData`, upsert): `id`, `topicId`, `messageId` (the message that started it),
`instruction`, `executor` (nil = thinking worker, else `claude` or `codex`), `state` (the Mac's
work state as text), `revision`, `suppressed`, `error`, `result`, `created`, `seq`. The phone
derives a topic's status with the Mac's rule (`docs/architecture.md`).

**`amendment`** (`AmendmentData`, upsert): `id`, `taskId`, `messageId`, `revision`,
`instruction`, `state`, `seq`.

**`worker_event`** (`WorkerEventData`, upsert): `id`, `taskId`, `kind`, `body`, `created`,
`seq`, and `files` for the images a worker shared in that step (absent when none).

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

### `readiness` (Mac -> phone): can the Mac answer

Capability `readiness-v1` (`ReadinessData.capability`); the Mac sends it only to a phone that negotiated it.

```swift
.readiness(ReadinessData(state: .attention, count: 1, items: [
    .init(id: "openclaw.gateway", title: "The OpenClaw Gateway isn't running. Start it with `openclaw gateway run`.", severity: .warning, fix: "openclaw gateway run")]))
```

```json
{"kind":"readiness","threadId":"","agentId":"main","id":"…","ts":0,
 "data":{"state":"attention","count":1,"items":[{"id":"openclaw.gateway","title":"…","severity":"warning","fix":"…"}]}}
```

- `state` is `ready`, `attention` (warnings) or `blocked` (nothing could answer). `count` is the items
  whose `severity` is `warning` or `blocking`; `ok` items may be listed too. `title` and `fix` are
  user-facing, in the Mac's language; `fix` is optional and the fix itself is done on the Mac.
  The Mac fills them from its readiness model (`ReadinessData(_:)` over `Readiness`,
  [architecture.md](architecture.md#setup-and-readiness)): `id` is the item's stable id, and `fix`
  is the command to copy, the URL, or "Setup › <step>" for a setup step.
- The Mac sends the latest value after each compatible claim (every handshake) and to every served phone
  on each change, from `RelayHost.publishReadiness(_:)` (through `AppModel.publishReadiness(_:)`, which
  keeps it across relay restarts). A Mac that has no value yet sends nothing.
- The phone keeps only the latest and drops it off `.paired`, where the status line already reads
  "Status unknown". While `attention` or `blocked` it shows one line over the composer: the blocking
  item's title, the only item's title, or "N items need attention", then "Fix this on the host". While
  `blocked` the composer is off, the same rule as on the Mac.
- A value that does not decode (an unknown `state` or `severity`) is ignored like an unknown kind.

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

## Attachments

Capability `attachments-v1` (`AttachmentDescriptor.capability`). A phone sends files and fetches
them only when the negotiated capabilities include it; a peer without it ignores `files` and never
sees an `attachment_*` kind. Types and limits are in `packages/YorozuWire/Sources/YorozuWire/Attachments.swift`.

- Limits (`MessageAttachment`): at most 10 files a message (`maxCount`), each at most 50 MB
  (`maxBytes` = 50,000,000, as Finder counts), no total beyond that. Upload chunks carry at most
  256 KiB (`chunkBytes`), download chunks at most 160 KiB (`downloadChunkBytes`), so a download chunk
  event stays under `ChunkData.budget` and is never split.
- Sync never carries bytes: records carry descriptors, and the bytes move only through the kinds
  below, over whichever path the session runs on (relay or direct), and only while `.paired`. Files
  never go into the relay's 5 MiB buffer: while the Mac is away, a message with files waits on the
  phone, text included, and goes as one unit once the Mac is reachable.
- Ids (`messageId`, `attachmentId`) match `^[A-Za-z0-9-]{1,64}$`; hashes are lowercase hex sha256.

### Descriptors

`AttachmentDescriptor{id?, name, mime, bytes, sha256}`, of the whole file: on `message` records (user
messages and results) and `worker_event` records as `files`, and in `attachment_commit` (without
`id`). `id` is the Mac's attachment id. A name is 1-255 UTF-8 bytes and a type 1-128, neither with
control characters; an empty file has the empty sha256 (`AttachmentDescriptor.emptySHA256`).
`AttachmentDescriptor.make(file:name:mime:)` builds one.

Images a worker shares in a progress message are attached to that worker event after it is stored;
the Store re-stamps the event's `seq` then, so the event reaches the phone again with `files` (the
[upsert rule](#change-sequence)).

### Upload

1. For each file in order, the phone sends `attachment_chunk{messageId, index, offset, totalBytes,
   sha256, deadline, data}` (event id = a fresh request id; `deadline` = the message's
   `admissionDeadline`; `data` = base64 of up to 256 KiB at `offset`). One chunk is in flight at a
   time across all uploads, and the next goes only after the reply, so phone -> Mac bytes in flight
   stay near 460 KB on the wire. Empty `data` asks only where the file stands.
2. The Mac stages it in `~/Library/Application Support/<bundle id>/uploads/<device X25519 key>/<messageId>/<index>-<sha256>-<totalBytes>.part`
   (directories 0700, files 0600; a chunk with another `sha256` or `totalBytes` starts that file over), checks the offset against what is staged, writes and fsyncs, and
   answers `attachment_progress{requestId, messageId, index, nextOffset}`:
   - `offset` past the staged size: nothing written, `nextOffset` = the staged size (the phone goes back).
   - `offset` inside it: matching bytes are kept, different ones replace the rest; `nextOffset` = the new size.
   - A file whose last chunk landed is hashed; a wrong hash drops it, `nextOffset` 0, `reason`
     `attachment-corrupt`.
   - A chunk for a message the Mac already stored (a replay after the commit) answers `nextOffset` =
     `totalBytes` and stages nothing.
   The phone continues from `nextOffset`, which is authoritative; it persists the offsets it gets,
   but a stale offset only costs one reply. Both sides resume after a disconnect or relaunch:
   staging lives on disk, the phone keeps its file copies and offsets in its outbox.
3. Once every file is staged, the phone sends `attachment_commit{text, attachments, admissionDeadline}`
   with event id = the message id and `ts` = the send time (renewed by Resend, like a `message`).
   The Mac applies the `message` [host checks](#message-phone---mac-send-a-user-message) (id, fixture
   mode, duplicate -> `receipt`, past deadline -> `expired` and the staging removed) plus: 1-10
   descriptors, each valid and without `id`, else `rejected`. Then each file must be staged whole
   under its descriptor's `sha256` and `bytes` and hash to that `sha256` (a staged file that does not
   is dropped and asked for from offset 0); the first that is not gets `attachment_progress{requestId: messageId, index, nextOffset}` and the
   phone resumes from there. Otherwise the Mac calls `Engine.send(text, attachments: [PendingFile],
   id: messageId, sentAt: ts / 1000)`, which copies the files into the store, removes the staging and
   replies `receipt`; an Engine error is `rejected` with its text (staging is kept, so Resend commits
   again without uploading). The text may be empty when files are attached. Idempotent by message id:
   a replayed or resent commit gets the `receipt` again.
4. The bubble stays Sending (upload progress in its details) until the `receipt` or the stored copy,
   then follows the usual [marks](#marks).

Reasons in `attachment_progress` (`AttachmentReason`): `attachment-storage-full` and
`attachment-storage-failed` are transient (the phone waits 10 s and goes on); any other
(`invalid-attachment-chunk`, `attachment-expired`, `attachment-corrupt`) ends the upload: the
bubble shows Not delivered with Resend.

Staging caps: 1 GB staged in all (two complete messages; each file counts at least its claimed
`totalBytes`, so open uploads cannot claim past the cap) and 64 messages; past either, a new file
gets `attachment-storage-full`. A message folder untouched for 48 h is pruned (checked at most every
10 minutes, on chunks).

### Download

`attachment_download_request{attachmentId, offset, thumbnail?}` asks for the next chunk of a file,
or with `thumbnail: true` of the Mac's JPEG preview of it (at most 512 px on its long edge, made with
ImageIO for images and QuickLookThumbnailing for anything else, cached in
`~/Library/Caches/<bundle id>/thumbs/<attachmentId>.jpg`). The answer is one
`attachment_download_chunk{attachmentId, thumbnail?, offset, totalBytes, sha256, data, reason?}`:
`data` up to 160 KiB from `offset`; `totalBytes` and `sha256` are the file's (the thumbnail's own for
a thumbnail). The phone writes chunks in order to a partial file, verifies size and sha256 at the
end (for a full file, against the record's descriptor too) and resumes a full file from its partial
size. It keeps at most two requests in flight and asks again after 20 s without an answer.

Reasons: `attachment-unavailable` (the attachment is unknown, its file is gone or no longer the size
on record: "File no longer available"), `thumbnail-unavailable` (no preview for that type; show a
file row), `invalid-attachment-chunk`.

### Phone helper

`AttachmentTransfers` (an actor in `YorozuWire`) runs both directions for `PhoneModel`: it sends
through `RelayClient.send`, is fed every incoming event through `handle(_:)`, moves bytes only
between `setLive(true)` (on `.paired`) and `setLive(false)`, and reports through its `updates`
stream (upload progress to persist, commit sent, upload failed, download progress, downloaded,
download failed).

## Jobs

Capability `jobs-v1` (`JobListData.capability`, #319). The Mac sends `job_list` and the job-only
messages only to a phone that negotiated it, and that phone sends `job_control` and job input only
to such a Mac; a phone without it shows no Jobs. Types are in `Mirror.swift`.

### `job_list` (Mac -> phone): every job

```json
{"kind":"job_list","threadId":"","agentId":"main","id":"…","ts":0,
 "data":{"jobs":[{"id":"backup-check","name":"Backup check","summary":"Every day at 07:00 · script, then AI if it changed\n…",
   "nextRun":1760000000000,"lastRun":1759913000000,"lastResult":"done","lastNotable":false,"state":"idle","topicId":"…"}]}}
```

- One row per job of the Mac's current valid set (`Engine.jobStatus(nextRuns:)` with
  `JobScheduler.nextRuns`). `summary`'s first line is the schedule in words; it is nil until written.
  `nextRun`, `lastRun` are epoch ms, `nextRun` nil while paused or retired (or with no next slot),
  `lastRun` the latest run's start. `lastResult` is `uncertain` while the latest run is, else the
  last finished run's state (`done`, `failed`, `stopped`), and `lastNotable` whether it was notable.
  `state` is `running`, `paused`, `needsApproval`, `needsAttention`, `finished` (a one-shot that
  ran) or `idle`; `state` and
  `lastResult` are text so a new value still decodes. `topicId` is the job's sub-chat.
- Always the whole list. The Mac sends the latest after each compatible claim and to every served
  phone when it changes. `EngineBridge` reads it on its snapshot poll only when the change sequence
  or the next runs moved, or 5 s passed, and `RelayHost.publishJobs(_:)` sends it only when it
  differs from the last one.
- The phone keeps the latest in memory (not in its cache). Its Activities list (sub-chats) shows a Scheduled row
  ("N scheduled · M need attention", counting `needsAttention` and `needsApproval`) and leaves job
  topics out of the list and of the running count.

### `job_control` (phone -> Mac): one action

```swift
.jobControl(JobControlData(jobId: job.id, action: .pause /* .resume, .runNow ("run_now"), .delete */))
// answered with
.admissionStatus(AdmissionStatusData(eventId: controlEventId, status: .accepted /* or .rejected */, reason: reason))
```

- Pause, Resume and Delete edit `jobs.toml` (`Engine.pauseJob`, `resumeJob`, `deleteJob`); the
  next `job_list` shows the change. Run now (`Engine.runJobNow`) runs under the no-overlap rule,
  also when paused; a skipped run is `rejected` with `"It didn't run: " + Engine.skipText(reason)`.
  A control whose envelope `ts` is more than 120 s before the Mac's clock is `rejected` with "That
  tap reached the host too late." and does nothing.
  Any Engine error, and fixture mode, is `rejected` with its text. Reasons are the Mac's English
  text, not localized on either side.
- The phone sends one per tap, only while `.paired`, never queued, and keeps that job's actions
  disabled until the answer (or until it leaves `.paired`); a refusal shows under the job's row.
  Delete asks for confirmation first. A replayed event id (among the Mac's last 64) gets its first
  answer again and never runs twice.

### A job's own input and its sub-chat

- A tap on a job opens its sub-chat (`TopicScreen`) with an input at the bottom; every other
  sub-chat stays inspect only. The input sends a [`message`](#message-phone---mac-send-a-user-message)
  with `jobId`, text only (1-6000 UTF-8 bytes), through the outbox with the usual marks; the item
  keeps the job's `topicId` so its bubble shows in the sub-chat until the stored copy arrives.
- The Mac admits it with the usual host checks and `Engine.sendToJob`, which stores it as a
  `job_input` message in the job's topic (idempotent by id) and sets `readAt` once the job's agent
  takes it (the Read mark). An unknown job is `rejected` with "Unknown job.".
- Job-only messages (`job_input`, `job_result`, `job_note`) travel as ordinary `message` records,
  but only to `jobs-v1` phones, which keep them out of the main timeline. A job run's trigger
  (`job_run`) reaches no phone; its tasks and worker events are ordinary records.
- A cache filled without `jobs-v1` has a cursor past the job-only messages, so the first
  `jobs-v1` handshake asks from no cursor (a window start); the cache records that it holds them.

## Push

Push (#320) uses the relay-level `push` (phone) and `notify` (Mac) messages the relay on `main`
already has (`apps/relay/src/protocol.ts`, `worker.ts`), including v1's per-device `previews`, so
neither the content-free alerts nor the [sealed previews](#sealed-previews) (capability
`push-preview-v1`, owner decision of 2026-10-10) needed a relay change. When the Mac sends a
`notify` is in [architecture.md](architecture.md#push-notifications).

### Token registration (phone -> relay)

- `AppDelegate` (`Push.swift`) calls `registerForRemoteNotifications()` on every launch and gives
  the token, as lowercase hex, to `PhoneModel.registerPush`, which keeps it for every `RelayClient`
  it makes (`RelayClient.registerPush(deviceToken:relayKnows:)`). A failure goes to Copy
  diagnostics ("Push registration: failed: …").
- `RelayClient` sends `{"type":"push","deviceToken":<hex>}` on the session's relay socket after
  each relay `joined`, and again when the token is set. The relay keeps one token per device.
- Direct path: a direct session never joins the relay. When the relay has not heard this token
  (`relayKnows` false), `RelayClient` opens one more relay socket beside the session, joins as the
  known device (nonce challenge), sends `push`, then `{"type":"owner"}`, and hangs up at the
  relay's `owner` reply: the room handles one message at a time, so `push` is stored by then.
  Without that reply within 15 s it gives up and the token stays owed; a failed join on that
  socket ends it and never fails the session. `onPushSent` reports each token the relay was told
  on the session's relay socket or stored for that extra one; `PhoneModel` stores it per pairing
  (`pushTokenOnRelayV2.<session key>` in `UserDefaults`) and passes `relayKnows: true` for an
  unchanged token, so that socket opens only once per new token.
- Removing a phone on the Mac revokes it at the relay, which deletes its token with it.

### `notify` (Mac -> relay)

```json
{"class":"reply","eventRef":"<8 chars>","previews":{"<phone Ed25519 key>":{"c":"…","n":"…"}},"threadRef":"<8 chars>","type":"notify"}
```

- These keys only (`RelayHost.notify`): `threadRef` is `YorozuCrypto.threadRef` of the
  main thread id the Mac publishes (`main`),
  `eventRef` is `YorozuCrypto.threadRef(<message id>)` (the first 8 base64url characters of a
  SHA-256), and `previews` as in [Sealed previews](#sealed-previews), left out when no box was
  sealed (a `done`, an empty excerpt, no phone with `push-preview-v1`). Never `actions`.
- Only the four classes the relay accepts; any other makes it drop the Mac's socket with "bad
  notify". Each class's alert body is a fixed relay `loc-key`, which the phone's string catalog
  rewords for v2:

| Mac event (`Message.alert`) | `class` | Relay `loc-key` | Phone, en | Phone, ja |
|---|---|---|---|---|
| A result (`.result`) | `reply` | `Yorozu replied.` | Yorozu replied. | Yorozu が返信しました。 |
| A failure (`.failure`) | `failed` | `Yorozu needs attention.` | A task failed. | タスクが失敗しました。 |
| A question (`.question`) | `approval` | `Yorozu needs your approval.` | Yorozu has a question for you. | Yorozuから質問があります。 |
| The Mac back online | `done` | `Yorozu finished.` | Your host is back online. | ホストがオンラインに戻りました。 |

- es, ko and zh-Hans carry the same v2 meaning for all four keys.
- Notifies the Mac holds while unregistered, and those sent since the last `pong` (a socket left
  half-open by sleep may have lost them), go out on the next `registered` collapsed to the newest
  per class, so at most four (details in [architecture.md](architecture.md#push-notifications)).
- The relay takes at most 60 notifies a minute per room and answers more with
  `{"type":"state","state":"notify rate limit"}`; the Mac logs it and carries on (that wake-up is
  lost, frames are not).

### Sealed previews

Capability `push-preview-v1` (`PushPreview.capability`). The alert shows the message's words; only
the Mac and the phone can read them.

- Key: per phone, HKDF-SHA256 over the pairing's X25519 agreement (the Mac's relay session key and
  the phone's session key, as for the channel), salt `yorozu-v1`, info
  `yorozu-push-preview/mac->device`, 32 bytes (`PushPreview.key`). It is never a channel key, so a
  preview box cannot pass for a channel frame or the other way round.
- Plaintext: compact JSON `{"b":<excerpt>,"c":<class>,"e":<event ref>}` (sorted keys), at most
  256 bytes (the relay's limit); `PushPreview.plaintext()` cuts the body, ending it with "…", until
  it fits. The excerpt is `Message.notificationExcerpt` (at most 180 characters, plain text,
  [architecture.md](architecture.md#push-notifications)), so a Japanese excerpt shows about 70
  characters on the phone.
- Box: ChaCha20-Poly1305 with a fresh random 12-byte nonce per box (CryptoKit), `n` = base64url
  nonce (16 characters), `c` = base64url ciphertext and tag (22–363 characters).
- `previews` maps each served phone that negotiated `push-preview-v1` to its own box, keyed by its
  Ed25519 relay key (43 base64url characters), at most 16. The Mac seals for results, failures and
  questions, never for `done`. Held and re-sent notifies keep the boxes they were sealed with.
- The relay (unchanged on `main`) checks the shapes, picks the phone's box when it sends that
  phone's alert and adds it as top-level `preview {n, c}` with `aps.mutable-content: 1`. A malformed
  map makes it drop the Mac's socket with "bad notify", so the Mac never sends one. A relay that
  ignores `previews` sends the fixed alert.
- Phone: the app derives the same key on every connect and keeps it in the Keychain group it
  shares with the notification service extension (`PreviewKeychain`), never the pairing's private
  keys; Remove host deletes it. The extension opens `preview` with it and, when the box opens,
  decodes and names the push's own `event`, sets the title to the class's alert text from its
  string catalog (the `loc-key` wording below) and the body to the excerpt. A missing box, a box
  that does not open or names another event, a missing key (no pairing, or before the first unlock)
  or an unknown class leaves the alert as the relay sent it: the fixed localized text.
- Neither end logs a plaintext; the Mac's debug log of the `notify` holds only boxes.

### What the relay and APNs see

- No plaintext: the alert is the fixed title "Yorozu" and the class's `loc-key`, plus the phone's
  sealed box, and has no `badge`. The relay and APNs see the class, the two 8-character refs (the
  thread ref is the same for every push to the one thread), the box's length (which bounds the
  excerpt's length), the phone's token and the timing.
- The relay's alert payload: `aps.alert {title, "loc-key"}`, `sound: "default"`, `thread-id` (the
  thread ref), `mutable-content: 1` with a box, for `approval` also `category: "approval-review"`
  (v1's; the v2 phone registers no categories, so no buttons show), plus top-level `ref` (thread
  ref), `cls`, `event` (event ref) and `preview` (the box).

### Silent push and catch-up

- Every registered phone gets the alert. A phone with no live relay socket also gets a silent
  `content-available` push, at most one a minute (relay `BACKGROUND_INTERVAL_MS`). A relay without
  the APNs secrets forwards frames and wakes nobody ([setup.md](setup.md#push-notifications)).
- Phone (`application(_:didReceiveRemoteNotification:)`): only in the background; active or
  inactive (Notification Center pulled down) the foreground link is up and the push is ignored.
  `PhoneModel.wake()`, for a linked phone with no wake running: start the link unless one is up,
  wait up to 20 s for `.paired`, the end of catch-up and an empty Sending set (the outbox resends,
  #314), save the cache and set the badge. Still in the background, it leaves the hang-up to
  #314's background time while that is held, else hangs up a link it dialled itself or one the app
  left to it on going to the background; a foreground link is never hung up. It returns `.newData`
  when the sync cursor moved, else `.noData`.

### Foreground presentation and taps

- `willPresent` applies to pushes only (`UNPushNotificationTrigger`); #314's local notices stay
  unshown in the foreground. No banner while the main timeline is on screen (app active, no pushed
  screen, no Settings sheet, no message details: `PhoneModel.mainShown`); elsewhere a banner, a
  list entry and the sound.
- A tap pops to the main timeline, closes Settings and details, and waits up to 10 s, while the
  link is not `.paired` or catching up, for a held message whose `threadRef(id)` equals the push's
  `event`; it scrolls there (centred), else to the bottom. A back-online push's `event` names no
  message, so it opens at the bottom.

### Badge

- The phone sets it itself (`setBadgeCount`); no count goes through the relay. It is the number of
  Yorozu's messages in the main timeline after the later (by timeline position) of this phone's own
  last read and the Mac's cursor, so a delta that arrives before the Mac echoes this phone's read
  does not raise it again (the owner's own messages never count, as for the unread divider). It is
  set after every applied `sync_delta` (foreground and silent wake) and at once when this phone
  sends `read_state`. With neither read in the timeline (no cursor yet, or one older than the
  window), every Yorozu message there counts. Remove host and new pairings set it to 0. Updates run
  one after another, so the latest count wins.
- When that read moves, the delivered pushes whose `event` names a message at or before it are
  removed. Each foreground removes the delivered back-online pushes (top-level `cls` `done`).
- A read on the Mac clears the phone's badge at its next sync (foreground or silent wake): the
  relay has no badge-only push.
- Permission (`.alert`, `.sound`, `.badge`, one request shared with #314) is asked at a
  foreground launch when the phone is paired (never at a background, silent-push launch), as well
  as at #314's moments; iOS shows the prompt once. The Notifications
  row in Settings shows On, Off or Not asked yet, with Open Settings when off; Copy diagnostics adds
  the permission and the registration state, never the token: whether Apple gave a token (or the
  failure) and whether the relay has stored it for this pairing (`onPushSent`).

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
`settings_changed`, and for jobs (#319) `job_approval_requested`, `job_approved`,
`job_approval_stale`, `job_failed`, `job_interrupted` and `job_skipped` (params in
[architecture.md](architecture.md#state-names)). A new code needs no capability: the fallback covers it.

## Mac-side seams

- `RelayBackend` (`YorozuWire/RelayBackend.swift`): `func handle(_ e: YorozuEvent, from device: String) async -> [YorozuEvent]`,
  `device` being the sender's X25519 key (base64url), used only to key its upload staging.
  `RelayHost` passes it each decrypted phone event other than the peer-info `thread_list`, one at
  a time in arrival order and off the receive path (so hellos and claims never wait on the
  Engine), and seals the returned events back to that same device only. `EngineBridge`
  implements it (`message`, `sync_request`, `read_state`, `task_control`, `search_request`,
  `page_request`, `attachment_chunk`, `attachment_commit`, `attachment_download_request` in;
  `receipt`, `admission_status`, `sync_delta`, `task_control_result`, `search_result`,
  `attachment_progress`, `attachment_download_chunk` out; `job_control` in, `admission_status` out).
  `readiness` and `job_list` are not replies: `RelayHost` sends them itself (above), and it strips
  the job-only message records from every `sync_delta` for a phone without `jobs-v1`.
- Descriptors on records come from `Snapshot.attachments`, read after the page's records (attachment
  rows are written with their owner, or re-stamp it). Downloads resolve a path with
  `Engine.attachmentURL(_:)`. `device_remove` needs the sender's key, so `RelayHost` handles it.
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
