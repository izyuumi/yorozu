# The wire: client ⇄ plugin

The wire between the Yorozu client app (iPhone, iPad, Mac) and the OpenClaw channel plugin, through the relay. Implementations:

| Side | Code |
|---|---|
| Client (Swift, CryptoKit) | `packages/YorozuWire/Sources/YorozuWire/`: `Wire.swift` (Noise, frames, boxes), `WireEvent.swift` (envelope), `RelayConnection.swift` (relay link), `Pairing.swift`, `DeviceCode.swift`, `PushPreview.swift`, `Crypto.swift` |
| Plugin (TypeScript, `node:crypto`) | `plugins/openclaw-yorozu/src/`: `wire.ts`, `envelope.ts`, `relay.ts` (relay link and dispatch), `push.ts`, `attachments.ts`, `history.ts`, `sessions.ts`, `reads.ts`, `cron.ts` |
| Relay | `apps/relay/src/`: `protocol.ts` (shared rules), `worker.ts` (deployed), `index.ts` (Node), `mailbox.ts` |

Change a message only with a matching change on both sides. No test exercises the client and plugin against each other: the relay has tests (`apps/relay/src/*.test.ts`), the rest is checked by compiling and running.

Layers, outside in:

1. [Relay](#relay): rooms, joins, Ed25519-signed frames, offline buffer, push.
2. [Frames](#frames): the relay `payload`, binary, base64url.
3. [Handshake](#handshake): Noise IK per connection.
4. [Transport boxes](#transport-boxes): numbered ChaCha20-Poly1305 boxes under the session keys.
5. [Envelope](#envelope): JSON `{kind, data}` inside each box.

## Relay

The relay parses only its own JSON envelope and forwards `payload` unread. Messages are JSON objects with a `type`; anything malformed closes the socket.

**Connecting.** Every socket gets `{"type":"nonce","nonce":…}` first and must `register` or `join` within 10 s (close `1008 auth timeout`). Both sides dial `<relay>?room=<room id>`: the Worker routes on it before any message; the Node relay ignores it.

- **Room id**: `base64url(sha256(host Ed25519 public key))`, 43 characters (`roomId` in `wire.ts`; the client reads it from the pairing link).
- **Host** sends `register {pubkey, nonceSig}` (Ed25519 over the nonce) and gets `registered {roomId, phones}`. The Worker binds a room to the first key that registers in it. A new registration replaces the old host socket (`4001 replaced`). The relay then replays buffered device frames, each with a `seq`; the host answers `ack {seq}` and unacked frames replay on the next registration.
- **Device** sends `join {roomId, phonePubkey, sig, token?}`. With `token` (first join) `sig` is over the token, which is spent; without, `sig` is over the nonce and the relay must already know the device. Answer: `joined {roomId, ownerOnline, flowControl?}`. Refusals close with `4001` and `unknown token`, `expired token` or `unknown device`, or `4003 bad join signature`.

**Host messages.** `mint` → `token {token, expiresAt}` (10 minutes; at most 8 live per room by default, oldest dropped). `devices {devices: [Ed25519 key…]}` replaces the room's known-device set (devices with a live socket are kept); the plugin sends it after every `registered`. `revoke {pubkey}` forgets that device and its push token and closes its sockets (`4001 revoked`). `notify` ([Push](#push)). From the relay: `phones {count}` when device sockets come or go, `state {state}` (for example `notify rate limit`).

**Device messages.** `owner` → `owner {online}`; the relay also sends `owner {online}` whenever the host socket comes or goes. `push {deviceToken}` (hex) after `joined`. `flowAck {bytes}` (decimal string) only when `joined.flowControl` is true.

**Frames.** `{"type":"frame","payload":<string>,"sig":<string>}`: `sig` is base64url Ed25519 over the UTF-8 bytes of `payload`, by the socket's key (`YorozuCrypto.signFrame` / `signFrame`), checked by the relay (`4003 bad frame signature`).

- Device → host: forwarded to the live host socket, else buffered. The device gets `{"type":"accepted","sig":…,"buffered":bool}` once the frame is forwarded or stored: the client's ✓ sent.
- Host → devices: every host frame goes to every device socket in the room, never buffered. A host may batch `{"type":"frame","frames":[{payload,sig},…]}` (at most 16, host only); devices receive plain single frames. The Worker adds `flowBytes` (cumulative bytes sent to that socket) to each.

**Heartbeat.** The exact string `{"type":"ping"}` is answered `{"type":"pong"}` without charging the rate limit (the Worker answers at the edge). The client pings every 25 s and redials after 10 s without a pong; the plugin pings every 30 s.

**Limits.**

| Limit | Value | Over it |
|---|---|---|
| One WebSocket message | 1 MiB | close `1009` |
| Messages per socket | 60 per second, 1 s burst | close `4029` |
| Unacknowledged bytes to one device | 2 MiB (Worker: `flowBytes` minus last `flowAck`; Node: socket buffer) | close `1013 slow receiver` |
| Device → host buffer while the host is away | 5 MiB and 24 h | oldest dropped |
| Known devices per room | 16 | the least recently joined is forgotten when a new token join arrives |
| `notify` per room | 60 per minute | `state {state: "notify rate limit"}`, not sent |

The client acks flow every 256 KiB or 16 frames. Because every host frame counts against every device's window, the plugin sends bulk data (history pages, attachment chunks) only to the device that asked and only on request.

## Pairing

`openclaw yorozu pair` (or a [`pair_invite`](#adding-a-device-pair_invite)) mints a relay token and a 32-byte secret, and prints:

```
yorozu://pair?v=3&relay=<url>&key=<host X25519 pub>&token=<one-time token>&room=<room id>&secret=<secret>
```

The QR carries the same query in a fragment: `https://yorozu.yumi.to/pair#<query>`, a universal link the iOS app claims.

- `key`: the host's static X25519 public key, base64url, 32 bytes; never sent over the relay. `token`: the relay's one-time join token. `room`: as above. `secret`: base64url; the relay never sees it.
- `QrPayload.decode` takes either form. `key`, `token` and `secret` must be unpadded base64url. `relay` must be `wss://`, or `ws://` to `localhost`, `127.0.0.1` or `::1`. A link without `v` is read as the current wire, and `RelayConnection` accepts only that or `v=3`. The plugin still sends `v=3` until every client in use reads links without it.
- **Fingerprint**: the first 8 bytes of `key`, uppercase hex in groups of two bytes (`EED8 92A4 B33E 5EC2`): `QrPayload.fingerprint`, `fingerprint()`. The CLI prints it and the client shows it for comparison before it pairs.
- **Proof**: while the client holds the secret, handshake message 1 carries `helloProof = base64url(sha256("<secret>.<pub>.<spub>"))`, where `pub` and `spub` are the client's X25519 static and Ed25519 keys, base64url (`YorozuCrypto.helloProof` / `helloProof`). It travels encrypted to the host's static key.
- The secret is pending in the plugin's memory until the token's `expiresAt`, and is spent by the first device whose proof matches: one device per code. A Gateway restart forgets it. The client drops its copy after the first session opens.

Client keys (`PhoneIdentity`): an Ed25519 relay key and an X25519 static key, made fresh for each pairing. Host keys: an Ed25519 relay key and an X25519 static key ([architecture](architecture.md#data-on-each-side) has where each is stored).

### Pairing from another device

A Mac, which has no camera, can pair from a code that a paired iPhone or iPad scans. The plugin is not involved beyond answering an ordinary `pair_invite`; the hand-over uses a one-time mailbox on the relay (Worker only).

- **Code** (`DeviceCode`): `https://yorozu.yumi.to/add#v=1&relay=<url>&box=<id>&key=<pub>&name=<name>`. `relay` defaults to `wss://relay.yumi.to` and passes the same check as a pairing link's; `box` is 16 random bytes and `key` a fresh X25519 public key, both base64url; `name` is cut to 64 characters (empty: "Mac"). The Mac shows a new code every 10 minutes while its pairing screen is up. The iOS app claims `/add` as a universal link.
- **Mailbox**: the Mac waits on `wss://<relay host>/mailbox/<box>`; the paired device sends `POST https://<relay host>/mailbox/<box>` with the letter as the body. One letter per mailbox: `204` stored, `409` one is already there, `410` ten minutes after the mailbox was first touched, `400` bad id or letter (empty, over 4096 characters or not base64url), `413` `Content-Length` over 4096, `429` connection rate limit. A waiting socket gets the letter at once, a later one on connect. A message sent on the socket closes it (`1008`).
- **Letter**: base64url of ephemeral X25519 public key (32) ‖ nonce (12) ‖ ChaCha20-Poly1305 ciphertext and tag of the invite's `webLink`. Key: HKDF-SHA256 over the X25519 shared secret, salt = ephemeral key ‖ code key, info `yorozu-device-code`, 32 bytes (`DeviceCode.seal` / `DeviceCode.open`).
- **Checks**: the paired device asks "Add … ?" and the Mac shows the host fingerprint before pairing. A stranger who saw the code could drop a link first; the fingerprints then differ and the owner cancels.

## Frames

The relay `payload` is unpadded base64url of one binary frame. Byte 0 is the type (a JSON payload starts with `{` and never parses). Frames come in two formats, moving from the old to the new in three steps: the plugin accepts both (now); clients send the new one (0.11); the plugin drops the old one, when the owner decides.

- **New**: one type byte, `0x11` init, `0x12` response, `0x13` box, then the bytes below. Prologue `yorozu|…`.
- **Old**, what clients send until 0.11: the byte `0x03`, then the type `0x01`, `0x02` or `0x03`, then the bytes below. Prologue `yorozu-v3|…`.

The plugin answers each session in the format of the init frame that opened it, and opens a box only in that format.

| Type | Direction | Bytes after the head |
|---|---|---|
| init | client → host | client Ed25519 key (32) ‖ Noise message 1 (96 to 65,535) |
| response | host → client | `sid` (8) ‖ Noise message 2 (48 to 65,535) |
| box | either | `sid` (8) ‖ counter (8, little-endian, at most 2^53 − 1) ‖ ciphertext and 16-byte tag |

- `sid`: the first 8 bytes of message 1, which are the first 8 bytes of the client's ephemeral key. Public.
- A box is bounded only by the relay's 1 MiB message: roughly 760 KiB of plaintext.
- Anything else, or a frame outside these lengths, is dropped (`Frame(payload:)` throws, `decodeFrame` returns null).

## Handshake

`Noise_IK_25519_ChaChaPoly_SHA256` as in the [Noise spec](https://noiseprotocol.org/noise.html) revision 34, no PSK:

```
IK:
  <- s
  ...
  -> e, es, s, ss
  <- e, ee, se
```

The client is the initiator (it knows the host's static key from the pairing link); the plugin is the responder. The 32-byte protocol name is the initial `h`. HKDF is Noise's (HMAC-SHA256, two outputs); the AEAD nonce is 4 zero bytes ‖ counter little-endian; handshake ciphertexts use `h` as associated data.

- **Prologue**: UTF-8 `yorozu|<room id>|<client Ed25519 key, base64url>` for new frames, `yorozu-v3|…` for old ones (`Wire.prologue`, old only until 0.11 / `prologue`). It binds the session to the room and to the key that signed the init frame.
- **Message 1 payload**: JSON `{"proof":<helloProof>,"ts":<epoch ms>}` (`HandshakePayload`), `proof` omitted once the client no longer holds the secret.
- **Message 2 payload**: empty. The client ignores its contents.
- **Split**: the initiator sends with the first key and receives with the second; the responder the reverse.

Client (`RelayConnection`, `ClientHandshake`):

1. Sends an init frame after `joined` when `ownerOnline`, again whenever `owner {online: true}` follows an offline report (the plugin may have restarted), and again after 15 s without a response and `peer_info`.
2. Ignores responses for other `sid`s. A response that fails to verify leaves the handshake waiting, so a forged one cannot spoil the real one.
3. On a valid response, sends its `peer_info` as its first box.

Plugin (`acceptHandshake` in `wire.ts`, the decision in `relay.ts`), per init frame:

1. Verifies `sig` against the frame's own Ed25519 key and reads message 1. Any failure: dropped, no answer.
2. Drops it if `ts` is more than 5 minutes (`HANDSHAKE_MAX_AGE_MS`) from its clock either way, or if its `sid` was already answered within that window.
3. Serves a stored device whose Ed25519 key **and** handshake-authenticated X25519 key both match, or a device whose `proof` matches a pending secret (it is then stored, the oldest of 16 making way, and the secret spent). Otherwise it sends the relay `revoke` for that key and drops the frame.
4. Sends the response frame and its `peer_info` box together. The new session replaces the device's previous one.

### Freshness and replays

The relay can replay a buffered init up to 24 h late. The 5-minute `ts` window and the answered-`sid` memory mean a replay never displaces a live session or gets a second answer (and a response is useless without the client's private keys). A client whose clock is more than 5 minutes off cannot connect. Boxes buffered from an earlier session carry a `sid` the plugin no longer holds and are dropped; the client resends undelivered messages in its next session.

## Transport boxes

Each session has one key and one counter per direction, counters starting at 0.

- A box's ciphertext is Noise's `ENCRYPT(k, n, ad = empty, plaintext)` with the sender's key and next counter `n`, and `n` is written into the frame.
- The receiver opens a box only if its `sid` matches and its counter is above the last one accepted; gaps are fine. A box that fails its tag does not move the counter. A box reflected to its sender fails (other direction's key).
- Counters stay at or below 2^53 − 1 so both languages agree. Sessions live only in memory: rekeying is a new handshake. The client keeps one session per socket; the plugin keeps one per device across its own relay reconnects.

## Envelope

Every box's plaintext is one UTF-8 JSON object `{"kind": <string>, "data": <object>}`. Key order is free (Swift sorts keys, `JSON.stringify` does not).

- **Unknown is answered, not dropped (plugin)**: once a session has its `peer_info`, the plugin answers a known kind whose `data` fails validation with `error bad_request` (carrying the frame's `convId`, `messageId` or `attachmentId` when they are valid ids), an unknown kind or one a device may not send with `error unsupported`, and any frame before `peer_info` with `error bad_request`; each is logged. The client decodes an unknown or malformed kind as `.unknown` and ignores it. Unknown fields are ignored on both sides.
- **Capabilities**: optional features are announced in `peer_info.capabilities`; a change that cannot be expressed that way raises the protocol version.
- **Ids**: `convId` and `messageId` are lowercase UUIDs, `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` (`WireEvent.isId`, `isId`); a known kind with a malformed id is unknown. A conversation's OpenClaw session key is `agent:<agent>:yorozu:direct:owner:thread:<convId>`.
- Times are epoch milliseconds (integers).

### Kinds

"That client" means the plugin seals the answer only for the device that asked.

| `kind` | Direction | `data` |
|---|---|---|
| `peer_info` | both, first box | `protocolMin`, `protocolMax` (both 3), `app`, `name`?, `capabilities` (strings), `mediaMaxBytes`?, `agent`?, `hostVersion`? |
| `message` | client → plugin | `convId`, `messageId` (client-made), `text` (may be empty with attachments), `attachments`? |
| `delivered` | plugin → clients | `convId`, `messageId` |
| `run_started` | plugin → clients | `convId`, `messageId` |
| `typing` | plugin → clients | `convId`, `active` |
| `reply` | plugin → clients | `convId`, `messageId` (plugin-made), `text`, `ts`, `attachments`? |
| `tool` | plugin → clients | `convId`, `messageId` (the user message whose run made the call), `callId`, `name`, `status` |
| `error` | both | `code`, `message` (English, for logs), `convId`?, `messageId`?, `attachmentId`? |
| `conv_list` | request `{}`; answer to that client | `conversations`: [`convId`, `updatedAt`, `rev`, `title`?, `archived`?, `pinnedAt`?] |
| `history` | request; answer to that client | request `convId`, `before`?, `after`?; answer adds `items`, `more`, `rev` |
| `read_cursor` | both | `convId`, `messageId`, `ts`, `unread` |
| `foreground` | client → plugin | `convId`? (absent or null: none), `active`? |
| `conv_patch` | client → plugin | `convId` and `title`?, `archived`?, `pinned`?, `deleted`? (`true`) |
| `conv_update` | plugin → clients | `convId`, `title`?, `archived`? (`true`), `pinnedAt`?, `deleted`? (`true`) |
| `cron_list` | request `{}`; answer to that client | `jobs`, or `jobs: []` and `error` |
| `device_list` | request `{}`; answer to that client | `devices`, or `error` |
| `device_patch` | client → plugin | `id`, `push`? or `removed`? (`true`); answered with `device_list` |
| `pair_invite` | request `{}`; answer to that client | `link`, `webLink`, `fingerprint`, `expiresAt`, or `error` |
| `upload` | client → plugin | `attachmentId`, `name`, `mime`, `size`, `index`, `count`, `data` (base64) |
| `upload_ack` | plugin → that client | `attachmentId`, `index`, `done` |
| `download` | client → plugin | `attachmentId`, `index` |
| `chunk` | plugin → that client | `attachmentId`, `index`, `count`, `data` (base64) |

A request and its answer share a kind; a `cron_list`, `device_list` or `pair_invite` with none of the answer fields is a request, and a client ignores one.

#### `peer_info`

Each side sends its own as its first box and acts on nothing else until it has the peer's. Each computes the highest version inside both ranges (`PeerInfo.negotiate` / `negotiate`). With none, the plugin sends `error {code: "update_required"}` and drops the session; the client stops with "update required".

| Field | Client | Plugin |
|---|---|---|
| `app` | the app version | the plugin version (`0.1.0`) |
| `name` | device model | the host's hostname |
| `capabilities` | `attachments`, `devices` | `attachments`, `devices`, `invite` |
| `mediaMaxBytes`, `agent`, `hostVersion` | — | attachment limit; `channels.yorozu.agent`; OpenClaw version |

The client offers attachments, Settings devices and adding a device only when the plugin lists `attachments`, `devices` and `invite`. The plugin answers `device_list`, `device_patch` and `pair_invite` from any client and reads `foreground.active` whenever present; the only thing it gates on the client's capabilities is a reply's files, sent to a client without `attachments` as one text line each. The plugin stores the client's `name` (cut to 64) for `openclaw yorozu devices`.

Right after the client's `peer_info`, the plugin sends that device every stored [`read_cursor`](#read_cursor).

#### `tool`

One tool call of an agent run, for a collapsed row under the message it answers. `callId` is OpenClaw's tool call id (not a UUID, at most 128 characters); updates of one call share it and the last `status` wins: `running`, then `done` or `failed`. `name` is the tool's name (at most 128). Any other `status` makes the event unknown.

#### History: `conv_list` and `history`

The Gateway transcript is the source of truth; the client caches what it fetched. The client keeps one request in flight and sends the next on the answer, an `error`, or after 30 s.

- `conv_list` lists the agent's Yorozu thread sessions, newest `updatedAt` first, at most 2000, archived ones included. `updatedAt` is the newest user or agent message's own time in the transcript, so renames and pins do not reorder. `rev` is the transcript's newest event seq. `title`, `archived`, `pinnedAt` are as in [`conv_update`](#titles-conv_patch-and-conv_update). A client drops a cached conversation the list omits if it synced it before (has a `rev`) or holds no message of it and has no undelivered message in it, unless the list holds 2000 rows.
- `history` returns one page, oldest first. `before: n`: the newest items with seq below `n`. `after: n`: the oldest items with seq above `n`. Neither: the newest page. `more`: another page lies further that way. At most 60 items and about 192 KiB; items of one transcript event are never split. An unknown conversation answers `items: []`, `more: false`, `rev: 0`.
- The client syncs on every new session: `conv_list`, then `after: <newest cached seq>` for each conversation whose `rev` changed; opening a conversation does the same for it; scrolling up asks `before: <oldest cached seq>` until `more` is false. A `run_started` for a message the client does not hold (another device's) also triggers an `after` fetch.

Items carry `kind`, `id`, `seq` (the transcript event's; shared by items of one event), `ts` (Gateway clock), then:

| `kind` | Fields | From |
|---|---|---|
| `user` | `text`, `attachments`? | a user message from the owner (OpenClaw-internal user-role turns are skipped); `id` is the client's `messageId`; `<file …>` blocks OpenClaw appends for documents are removed |
| `agent` | `text`, `attachments`? | assistant text without `MEDIA:` lines, trimmed and chunked by `textChunkLimit` like live replies, files on the last chunk (or an item with empty `text`); cron deliveries mirrored into the transcript come out here too |
| `tools` | `tools`: [`callId`, `name`, `status`] | one row per run, at its first tool call; `id` is the run's user `messageId`; a call without a result is `running` only while the run is the transcript's last |
| `reset` | — | a `/new` or `/reset` boundary |

- Text is cut at 60,000 characters.
- An agent chunk's `id` is the transcript message's id for the first chunk and a SHA-256-derived UUID for the others. A live `reply` in a turn takes the same ids and `ts` (the plugin finds the assistant message core wrote before delivery), so a page replaces the live item. Where that lookup fails (cron deliveries), the client matches by trimmed text.
- `attachments` lists only files the plugin can still serve.
- The client skips item kinds it does not know.

#### `read_cursor`

One read state per conversation, shared by every device. Replies with `ts` at or below the cursor's `ts` are read; the client badges each conversation with the count of later agent replies, and the app with the sum. `messageId` names the reply the cursor stands on. `unread: true` (Mark as Unread) counts the conversation as unread (at least 1) until a read clears it.

- The client sends one when the user opens a conversation or marks it read (cursor at the newest reply, `unread: false`), when a reply arrives while it is open and the app is active (`unread` kept), and on Mark as Unread (cursor unchanged, `unread: true`). An unanswered cursor is sent again on the next session.
- The plugin keeps one per `convId` (keyed state namespace `read`) and merges: the cursor only moves forward, `unread` is the sender's. It sends the merged cursor to every device, the sender included. A merged cursor with `unread: false` triggers a [`sync`](#push) notify.

#### Titles: `conv_patch` and `conv_update`

A conversation's title is the session entry's `label` (manual rename), else `displayName` (generated), else none; until then the client shows the first line of the first message.

- **Generated**: after a turn, a conversation with neither gets a title of its first user message that is not a slash command, from OpenClaw's `generateConversationLabel` (the agent's `utilityModel`, then its primary model) with core's dashboard title prompt, at most 60 characters, written to `displayName`. A failed attempt is retried after the next turn; a rename made meanwhile wins.
- **`conv_patch`**: the client sends one change per patch; the plugin applies every field present, `deleted` first and alone. `title`: trimmed, cut to 60 characters, `""` clears the rename. `archived`: sets `archivedAt` and `archiveReason: "manual"` and clears `pinnedAt`, or clears the archive. `pinned`: sets `pinnedAt` (kept if already pinned) or clears it; pinning an archived conversation is `error bad_request`. `deleted: true`: archives if needed, deletes the entry with its transcript archived (as `sessions.delete` does) and drops the read cursor. None of these changes the conversation's order. A patch for a conversation the host does not have produces `conv_update {deleted: true}`; one that fails, `error internal` with `convId` to the sender.
- **`conv_update`** goes to every device and is the conversation's state, not a diff: absent `title`, `archived`, `pinnedAt` mean none, not archived, not pinned; `deleted: true` means gone (the client drops it and its cache). The plugin sends one whenever that state differs from what it last sent, after its own writes and on any session-entry change it sees (`subscribeSessionChanges`), so changes from the Control UI reach devices too. A `conv_update` for an unknown conversation adds it, empty until `history` fills it.

#### `cron_list`

The client's Automations tab. The plugin answers with every cron job of `channels.yorozu.agent`, disabled ones included, sorted by name. A job with no `agentId` belongs to `agents.defaults.systemAgent.agentId`, else the default agent; with neither it is listed for no one. Read-only: there is no cron write kind.

| Field | Meaning |
|---|---|
| `id` | OpenClaw's job id |
| `name` | The job's `displayName`, else its `name` |
| `enabled` | false: shown greyed |
| `schedule` | OpenClaw's schedule object as stored (`kind`: `at`, `every`, `cron`, `on-exit`, `stream`, and its fields) |
| `scheduleText` | The plugin's English wording (`Every 30 minutes`, `Daily at 09:00 (Asia/Tokyo)`, `Weekdays at 08:30`, `Once`, else `Cron <expr>`); clients show it as is |
| `nextRunAt`?, `lastRunAt`? | The scheduler's |
| `lastStatus`? | `ok`, `error` or `skipped` |
| `lastError`? | At most 2,000 characters |
| `delivery`? | Only when it delivers into a Yorozu conversation: `{channel: "yorozu", threadId: <convId>}` |

When the plugin cannot read the cron store the answer is `{jobs: [], error}` and the client keeps its last list under the error. "Edit in Chat" opens the job's delivery conversation, or a new one, with a draft for the agent; nothing is sent until the owner sends it.

#### Settings: `device_list` and `device_patch`

`device_list` answers every paired device, oldest first: `id` (its Ed25519 relay key), `name`?, `pairedAt`, `push` (whether the host pushes to it), `current` (it is the asking device). `device_patch {id, push}` turns that device's push on or off; `device_patch {id, removed: true}` removes it as `openclaw yorozu devices remove` does (row deleted, session dropped, relay `revoke`). Both are answered with a fresh `device_list`, or `{error}` for an unknown id. On Unpair the client removes itself this way, then forgets the host.

#### Adding a device: `pair_invite`

The plugin mints the same one-time code as `openclaw yorozu pair` ([Pairing](#pairing)) and answers `link` (`yorozu://pair?…`), `webLink` (what the QR carries), `fingerprint` and `expiresAt` (the relay's), or `{error}` while the relay is unreachable. The client shows it as a QR and a link, or seals `webLink` into a [Mac's mailbox](#pairing-from-another-device).

#### Attachments

Files both ways, each at most the plugin's `mediaMaxBytes` (`channels.yorozu.mediaMaxMb`, else `agents.defaults.mediaMaxMb`, else 8 MB; the client assumes 8 MB until told), in chunks of 160 KiB of raw bytes (`CHUNK_BYTES`, `Attachment.chunkBytes`). An attachment is `{id, name, mime, size}`; `id` is a lowercase UUID made by the side that has the bytes. `count` is `max(1, ceil(size / 160 KiB))`; every chunk but the last is full.

- **Client → agent**: the client refuses an oversized file before copying it. It holds a message with files until a session is up, uploads each file as `upload` chunks, four in flight, each answered `upload_ack` to that device only (30 s timeout per ack), then sends the `message` naming the files whose last ack said `done`. The plugin answers `error {code: "too_large", attachmentId}` for a file over its limit and `bad_request` for a chunk that does not fit its upload; the client then leaves that file out. A finished upload is saved into OpenClaw's media store (`media/inbound`) and indexed in keyed state namespace `attachments`, so re-uploading a stored id is answered `done` at once. Partial uploads live in memory (at most 8, dropped after 30 minutes idle) and start over on a new session. The turn gets the files as media facts (`toInboundMediaFactsWithMetadata`).
- **Agent → client**: a reply's media (`MEDIA:` lines, the message tool, a delivery's `sendMedia`) is staged into `media/outbound` (`resolveOutboundAttachmentFromUrl`, the agent's media roots and limit) and announced in the `reply`'s `attachments`, on the last text chunk or a reply of its own. Nothing more is sent until a device asks: `download` per chunk, answered with `chunk` for that device only. The client fetches an image when shown and a file when tapped, one file at a time, two chunks in flight, starting over on a new session. An unknown or vanished id is answered `error {code: "not_found", attachmentId}`. A file that cannot be staged becomes a `(Couldn't attach <name>: …)` line in the reply.

#### `error` codes

| `code` | Meaning |
|---|---|
| `update_required` | No common protocol version |
| `bad_request` | The receiver knows the kind but cannot act on it: data that fails validation, pinning an archived conversation, an upload chunk that does not fit. For a `message` it arrives instead of `delivered`, and the client marks the message not delivered with the reason and stops resending it |
| `unsupported` | A kind the plugin does not handle from a device |
| `attachment_missing` | A `message` named attachments the plugin does not hold; the turn runs without them, with `convId` and `messageId` |
| `run_failed` | The agent run for `messageId` failed; `message` says why |
| `too_large` | An `upload` over `mediaMaxBytes` |
| `not_found` | A `download` of an attachment the plugin does not hold |
| `internal` | Anything else: a `conv_list` or `history` the plugin could not read, a `conv_patch` it could not apply, an upload it could not store |

A receiver treats an unknown code like `internal`.

## Delivery

All paired devices are one channel peer (`owner`), so the plugin sends `delivered`, `run_started`, `typing`, `tool`, `reply`, `conv_update` and merged `read_cursor`s to every device with a session, each sealed under that device's session.

- ✓ sent: the relay's `accepted` for the frame carrying the `message`. ✓✓ delivered: `delivered`, sent as soon as the box opens. Read: `run_started`.
- The client sends `message`s only in an established session and resends any without `delivered` in its next session. The plugin answers a repeated `messageId` (remembered 24 h, up to 10,000) with `delivered` again and does not run it twice.
- Typing: `typing {active: true}` from run start, repeated at least every 10 s (every 8 s in practice), `typing {active: false}` when it ends. The client hides it after 30 s without a repeat.
- Replies arrive whole, one `reply` per chunk of `channels.yorozu.textChunkLimit` (default 4000) characters, never edited. A cron job delivering into a conversation (`delivery: {channel: "yorozu", to: "owner", threadId: <convId>}`) arrives as `reply` too, with no `run_started` or `typing`. Nothing is queued for a device without a session: it catches up through `history`.
- A run that fails for a temporary reason (plugin reload, overloaded or rate-limited model) before any reply or tool call is retried by the plugin (after 5, 15, 30, 60 and 120 s, parked in keyed state namespace `retry`); otherwise the devices get `error run_failed`.
- Slash commands are plain text: `/new` and `/reset` reset that conversation's session; others go to OpenClaw as typed.

## Push

One push per finished agent reply, and per cron delivery with text, through the relay's `notify`, with a preview sealed per device.

- **Token**: an iPhone or iPad sends `{"type":"push","deviceToken":<lowercase hex>}` after every `joined` and whenever iOS hands it a new token; it asks iOS for one on every launch. The relay keeps one token per device (a token claimed by another device key moves to it) and forgets it when the device is revoked. The Mac registers no token.
- **Foreground**: the client sends `foreground {convId, active: true}` while a conversation is on screen with the app active, `foreground {active: …}` without `convId` otherwise, whenever either changes, including just before going to the background, and again on every new session while active (a new session starts with none). The plugin skips a device whose live session last reported that conversation or `active: true`, and a device whose push is off. When the relay reports `phones {count: 0}`, the plugin forgets every device's foreground.
- **When**: after a turn that sent at least one `reply` (one push, named after its first chunk), or after a delivered payload with text (the outbound adapter's `afterDeliverPayload`). A failed turn does not push. With no device left to alert, no `notify` is sent.
- **`notify`** (host → relay): `{"type":"notify","class":"reply","threadRef":<threadRef(convId)>,"eventRef":<threadRef(messageId)>,"previews"?:{<device Ed25519 key>:{n,c}},"devices":[<device Ed25519 key>,…]}`. `threadRef` is `YorozuCrypto.threadRef` / `threadRef`: the first 8 base64url characters of SHA-256. The relay alerts only the named devices (every registered device when `devices` is absent). It validates: `previews` and `devices` at most 16 entries of 43-character keys, `n` 16 characters, `c` 22 to 363 characters.
- **Relay → APNs** (Worker only): an alert `{"aps":{"alert":{"title":"Yorozu","loc-key":"Yorozu replied."},"sound":"default","thread-id":<threadRef>,"mutable-content":1},"ref":<threadRef>,"cls":"reply","event":<eventRef>,"preview":{n,c}}` (`mutable-content` and `preview` only with a preview). After an alert, a device with no live socket also gets a background push (`content-available`), at most one a minute. The relay also accepts classes `approval`, `done` and `failed`, which this plugin never sends.
- **Read elsewhere**: the plugin remembers, per conversation, the devices it alerted since the last read (in memory). On a merged cursor with `unread: false` it sends `{"type":"notify","class":"sync","threadRef":…,"devices":[…]}` for those devices except the reader. The relay sends each one without a live socket a background push only, not held to the one-a-minute limit. A woken iPhone or iPad connects briefly; the `read_cursor`s on its new session clear what was read.
- **Preview** (`PushPreview`; `push.ts`): key = HKDF-SHA256 over X25519(host static, device static), salt `yorozu-v1`, info `yorozu-push-preview/mac->device`, 32 bytes. Box: ChaCha20-Poly1305 with a fresh 12-byte nonce; `n` and `c` (ciphertext ‖ tag) base64url. Plaintext: JSON with sorted keys `{"b":<first non-empty line of the reply>,"c":"reply","e":<eventRef>,"t":<title>?,"v":<convId>}`, at most 256 bytes: the title is cut to 32 characters, then the body with "…" until it fits. The title is the conversation's [title](#titles-conv_patch-and-conv_update), else its first message's first line (keyed state namespace `push-titles`, slash commands skipped).
- **iPhone, iPad**: the app writes the preview key, on every connect, to a Keychain group shared with the notification service extension, and deletes it on unpair. The extension opens `preview`, requires its `e` to equal the push's `event`, and sets the title to `t` (else "Yorozu replied."), the body to `b` and `userInfo.convId` to `v`; anything that does not open is shown as sent. While the app is active, a notification is not shown as a banner but as the in-app notice. A tap opens the conversation by `convId`, else by `ref` matched against cached conversations. Opening a conversation removes its delivered notifications, and so does any `read_cursor` with `unread: false` (those delivered no later than 15 s after the cursor's `ts`).
- **Mac**: no relay push. While the app is active, a reply in a conversation not on screen shows the in-app notice; while it is not, each reply posts a local notification, one per conversation, replaced by the next, with sound at most once per 10 s per conversation.
- Neither end logs preview plaintext.

## API map

| Need | Swift (`YorozuWire`) | TypeScript (`plugins/openclaw-yorozu/src`) |
|---|---|---|
| Keys | `PhoneIdentity.generate()` | `x25519Keypair`, `ed25519Keypair`; host keys in `keys.ts` |
| Relay signature | `YorozuCrypto.signFrame`, `verifyFrame` | `signFrame`, `verifyFrame` |
| Room, fingerprint, proof | `QrPayload.roomId`, `.fingerprint`, `YorozuCrypto.helloProof` | `roomId`, `fingerprint`, `helloProof` |
| Pairing link | `QrPayload.encoded()`, `QrPayload.decode` | `beginPairing` (`relay.ts`) |
| Handshake | `ClientHandshake`, `.finish(_:) -> Session` | `acceptHandshake` |
| Noise, both roles | `NoiseIKHandshake` | `NoiseIK` |
| Relay link | `RelayConnection` | `runRelayHost` (`relay.ts`) |
| Frames | `Frame(payload:)`, `.payload`, `.sid` | `decodeFrame`, `encodeFrame`, `frameSid` |
| Boxes | `Session.seal`, `.open`, `.openEvent` | `Session.seal`, `.open` |
| Envelope | `WireEvent`, `PeerInfo.negotiate`, `WireEvent.newId`, `isId` | `Event`, `parseEvent`, `encodeEvent`, `negotiate`, `isId` |
| Capabilities | `Attachment.capability`, `Devices.capability`, `Invite.capability` | `ATTACHMENTS`, `DEVICES`, `INVITE` |
| Attachments | `Attachment` (`chunkBytes`, `chunkCount`), `Upload`, `UploadAck`, `Download`, `Chunk` | `CHUNK_BYTES`, `attachments.ts` |
| Push preview | `PushPreview.key`, `.open(userInfo:key:)`, `RelayConnection.registerPush` | `previewKey`, `previewPlaintext`, `sealPreview`, `threadRef` (`push.ts`) |
| Mac pairing code | `DeviceCode` | — |

## Validation differences

Each side validates what it receives; the two are not identical.

- The plugin refuses (`error bad_request`) a `message` with more than 32 attachments, an attachment or `upload` whose `name` or `mime` is empty or over 255 characters, and a `device_patch` whose `id` is over 64 characters. The client keeps within these before sending: the composer will not send more than 32 files, and names and types are trimmed to 1–255 characters (`Attachment.wireName`, `wireMime`).
- The client drops malformed rows of `conv_list` and `history` individually; the plugin does not validate those answers (it only sends them).
