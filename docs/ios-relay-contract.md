# Wire v3: client ⇄ plugin relay contract

The wire between the Yorozu client app (iPhone, iPad, Mac) and the OpenClaw channel plugin (`plugins/openclaw-yorozu`), which holds the host keys and the relay connection itself (#415). Both sides implement against this file:

- Swift, client side: `packages/YorozuWire/Sources/YorozuWire/WireV3.swift` and `V3Event.swift` (CryptoKit only).
- TypeScript, plugin side: `plugins/openclaw-yorozu/src/wire.ts` and `src/envelope.ts` (`node:crypto` only).

Change it only with a matching change on both sides, and keep the [known-answer vectors](#known-answer-vectors) reproducing in both languages. v3 shares nothing with v2 above the relay: every device pairs again once. The v2 contract, deleted with the v2 code in #426, is kept in [history/ios-relay-contract-v2.md](history/ios-relay-contract-v2.md).

Layers, outside in:

1. The relay (`apps/relay` on `main`, unchanged): rooms, joins, signed frames, push.
2. [Frames](#frames): the relay `payload`, binary, base64url.
3. The [handshake](#handshake): Noise IK per connection, so every connection has fresh keys.
4. [Transport boxes](#transport-boxes): numbered ChaCha20-Poly1305 boxes under those keys.
5. The [envelope](#envelope): JSON `{kind, data}` inside each box.

## Relay

Unchanged from v1 and v2. The relay reads only its outer envelope and gates nothing on the protocol version.

- **Room**: `base64url(sha256(host Ed25519 public key))` (`roomId` in TS; the client reads it from the QR, `QrPayload.roomId`). The plugin registers as the room's host with that key (#422).
- **Join**: a client's first join spends the one-time token from the QR and signs the token; every later join signs the relay's connect nonce. Both use the client's Ed25519 key. Tokens last 10 minutes; a room holds at most 16 devices.
- **Frames**: `{"type":"frame","payload":<string>,"sig":<string>}`. `sig` is base64url Ed25519 over the UTF-8 bytes of the `payload` string itself, by the sender's relay key (`YorozuCrypto.signFrame` / `signFrame`). The relay checks it against the socket's key. A host may batch: `{"type":"frame","frames":[{payload,sig},…]}`.
- **`accepted`**: the relay answers every client frame with `{"type":"accepted","sig":…,"buffered":bool}` once it has forwarded it to the host's live socket or stored it for the host. That is the client's ✓ sent.
- **Push**: client `push {deviceToken}` and host `notify` with sealed `previews`, as in v2; the v3 rules are in [Push](#push).

Limits every sender must respect:

- One WebSocket message is at most 1 MiB; a host batch at most 16 frames and 1 MiB in total.
- Every host frame goes to every device socket in the room. A device ignores boxes for other sessions (by `sid`), but each one still counts against every device's 2 MiB unacknowledged window; past it the relay closes the device with `1013 slow receiver`. Devices send `flowAck`. The plugin paces sends across devices and serves large transfers only on request.
- Device → host frames sent while the host is away are buffered (5 MiB, 24 h, oldest dropped) and replayed when it returns, possibly 24 h late. That includes old handshakes; see [freshness](#freshness-and-replays). Host → device frames are never buffered.
- A sealed push preview is at most 256 bytes of plaintext.

## Pairing

`openclaw yorozu pair` (#423) prints the QR, the link and the host fingerprint. The link is v1's shape with `v=3`:

```
yorozu://pair?v=3&relay=<url>&key=<host X25519 pub>&token=<one-time token>&room=<room id>&secret=<secret>
```

- `key`: the host's static X25519 public key, base64url (32 bytes). The client's Noise initiator needs it; it is never sent over the relay.
- `room`: as above. `token`: the relay's one-time join token. `secret`: a host-minted secret the relay never sees.
- `QrPayload.decode` takes it (also as `https://yorozu.yumi.to/pair#<query>`); a client built for v2 refuses `v=3` as "not a Yorozu v1 pairing string".
- **Fingerprint**: the host key's first 8 bytes, uppercase hex in groups of two bytes (`EED8 92A4 B33E 5EC2`): `QrPayload.fingerprint` on the client, `fingerprint()` in the plugin. Both show it at pairing.
- **Proof**: while the client holds the QR's secret, its handshake carries `YorozuCrypto.helloProof(secret, pub, spub)` = `base64url(sha256("<secret>.<pub>.<spub>"))`, where `pub` and `spub` are the client's X25519 static and Ed25519 keys, base64url. It travels encrypted to the host's static key, so the relay never sees even the hash. A valid proof against a pending pairing is what lets the plugin add a device to its allowlist.

Client keys are the existing `PhoneIdentity`: an Ed25519 relay key and an X25519 static key, kept in the Keychain, this device only. The plugin's keys are its Ed25519 relay key and its X25519 static key, in OpenClaw's credentials store, `0600` (#422).

## Frames

The relay `payload` is base64url (unpadded) of one binary frame. Byte 0 is the wire version, `0x03`; a v2 payload is JSON and starts with `{`, so it never parses as v3. Byte 1 is the type.

| Type | Direction | Bytes after the two-byte head |
|---|---|---|
| `0x01` init | client → host | client Ed25519 key (32) ‖ Noise message 1 (96 + payload) |
| `0x02` response | host → client | `sid` (8) ‖ Noise message 2 (48 + payload) |
| `0x03` box | either | `sid` (8) ‖ counter (8, little-endian) ‖ ciphertext and 16-byte tag |

- `sid` names one session: the first 8 bytes of the client's ephemeral public key, which are the first 8 bytes of message 1. It is public.
- Noise messages are at most 65,535 bytes. A box is bounded only by the relay's 1 MiB message: about 760 KiB of plaintext, less per frame inside a host batch.
- Anything else, or a frame too short for its type, is dropped (`V3Frame(payload:)` throws, `decodeFrame` returns null).

## Handshake

`Noise_IK_25519_ChaChaPoly_SHA256`, exactly as in the [Noise spec](https://noiseprotocol.org/noise.html) (revision 34), without PSK:

```
IK:
  <- s
  ...
  -> e, es, s, ss
  <- e, ee, se
```

The client is the initiator: it knows the host's static key from the QR. The plugin is the responder. The protocol name is 32 bytes, so `h` starts as the name itself. HKDF is Noise's (HMAC-SHA256 with two outputs, salt = `ck`), the AEAD nonce is 4 zero bytes ‖ the counter little-endian, and handshake ciphertexts use `h` as associated data.

- **Prologue**: the UTF-8 bytes of `yorozu-v3|<room id>|<client Ed25519 key, base64url>` (`WireV3.prologue` / `prologue`). It binds the session to v3, to the room and to the relay key that signed the init frame; a frame re-signed under another key fails to decrypt.
- **Message 1 payload**: JSON `{"proof":<helloProof>,"ts":<epoch ms>}` (`V3HandshakePayload`), `proof` left out once the client no longer holds the secret. Field order does not matter to the reader.
- **Message 2 payload**: empty. A v3 client ignores whatever is there, so a later version may put a JSON object there.

The client (`V3ClientHandshake`):

1. Opens a relay socket and joins. Once the relay reports the host online (`joined.ownerOnline`, or `owner {online: true}`), it sends the init frame. It sends a new one on every new socket and whenever the relay reports the host back online after being away, since the plugin may have restarted and lost its sessions.
2. Ignores response frames whose `sid` is not its own (other devices' handshakes). A response that fails to verify leaves the handshake waiting, so a forged one cannot spoil the real one.
3. On a valid response, splits: the first key sends, the second receives. It sends its [`peer_info`](#peer_info) as its first box.

The plugin (`acceptHandshake`), for each init frame:

1. Verifies `sig` against the frame's own Ed25519 key and reads message 1. Anything that fails is dropped without an answer, the same as a stranger's frame.
2. Checks [freshness](#freshness-and-replays) of `ts`.
3. Decides whether to serve the device: a stored device whose Ed25519 key **and** X25519 static key (authenticated by the handshake) both match, or a pending pairing whose `helloProof` equals `proof` (it then stores the device, at most 16, and spends the secret: one device per pairing, until the token expires). Otherwise it drops the frame and sends the relay `revoke` for that device. (`acceptHandshake` returns the keys and payload; the decision is in `src/relay.ts`.)
4. Drops a `sid` it has already answered within the freshness window.
5. Sends the response frame, then its own `peer_info` box, both may go in one batch. The new session replaces any older one of that device.

### Freshness and replays

The relay replays buffered client frames up to 24 hours late, so a captured init frame can arrive long after its client gave up on it. The plugin drops an init whose `ts` is more than 5 minutes (`HANDSHAKE_MAX_AGE_MS`) from its own clock in either direction, and remembers answered `sid`s for those 5 minutes. A replayed init therefore never displaces a live session, and a replayed one inside the window gets no second answer. Its response would be useless to the relay anyway: the session keys need the client's ephemeral and static private keys. A client whose clock is more than 5 minutes off cannot connect.

Boxes buffered from an earlier session carry a `sid` the plugin no longer holds and are dropped. A user message lost that way is sent again by the client in its next session (see [Delivery](#delivery)).

## Transport boxes

Each session has two keys, one per direction, and two counters, both starting at 0.

- A box's ciphertext is Noise's `ENCRYPT(k, n, ad = empty, plaintext)` with the sender's key and its next counter `n`. Over a reliable in-order link that is byte for byte a Noise transport message; the difference is that `n` is also written into the frame.
- The receiver opens a box only if its `sid` is the session's and its counter is above the last one it accepted. Gaps are fine (a frame the relay dropped); a counter at or below the last is a replay and is dropped. A box that fails its tag never moves the counter. A box reflected back to its sender fails, since it was sealed under the other direction's key.
- Counters stay at or below 2^53 − 1 (`Number.MAX_SAFE_INTEGER`) so both languages agree on the domain. A side that runs out starts a new handshake.
- Sessions live only in memory and are never stored: rekeying is a new handshake on reconnect. A client keeps one session per socket. The plugin keeps one per device and keeps it across its own relay reconnects, so boxes the relay buffered meanwhile still open.

## Envelope

Every box's plaintext is one UTF-8 JSON object:

```json
{"kind":"message","data":{"convId":"…","messageId":"…","text":"…"}}
```

- `kind` is a string, `data` an object. Key order is free (Swift sorts keys, `JSON.stringify` does not).
- **Unknown is ignored, never an error**: an unknown `kind`, or a known kind whose `data` does not parse, decodes as `.unknown` (Swift) / `{kind: "unknown"}` (TS) and is dropped. Unknown fields inside a known kind are ignored. That is how later issues add kinds and optional fields without breaking older peers.
- **Capabilities**: a later kind or field that a peer must understand is announced in `peer_info.capabilities` and sent only to peers that list it. A change that cannot be expressed that way raises the protocol version.
- **Ids**: `convId` and `messageId` are lowercase UUIDs (`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`; `V3Event.newId()`, `isId`). OpenClaw lowercases session keys, and a conversation's session key is `agent:<agent>:yorozu:direct:owner:thread:<convId>`. A known kind with a malformed id is treated as unknown.
- Times are epoch milliseconds (integers).

### Kinds

| `kind` | Direction | `data` |
|---|---|---|
| `peer_info` | both, first box of a session | `protocolMin`, `protocolMax` (both 3), `app` (version string), `name`? (device model, or the Mac's name), `capabilities` (string array: `attachments`, #430; `devices`, [Settings](#settings-device_list-and-device_patch); `invite`, [adding a device](#adding-a-device-pair_invite)), `mediaMaxBytes`? (plugin: its [attachment](#attachments) limit), `agent`?, `hostVersion`? (plugin: `channels.yorozu.agent` and the OpenClaw version, for Settings) |
| `message` | client → plugin | `convId`, `messageId` (made by the client), `text` (may be empty with attachments), `attachments`? ([attachments](#attachments), each uploaded first) |
| `delivered` | plugin → clients | `convId`, `messageId`: received and decrypted |
| `run_started` | plugin → clients | `convId`, `messageId`: the agent run for it began |
| `typing` | plugin → clients | `convId`, `active` (bool) |
| `reply` | plugin → clients | `convId`, `messageId` (made by the plugin), `text` (may be empty with attachments), `ts`, `attachments`? (announced; [downloaded on request](#attachments)) |
| `error` | both | `code`, `message` (English, for logs), `convId`?, `messageId`?, `attachmentId`? |
| `tool` | plugin → clients | `convId`, `messageId` (the user message whose run made the call), `callId`, `name`, `status` |
| `conv_list` | client → plugin, then plugin → that client | asked with `{}`; answered with `conversations`: [`convId`, `updatedAt`, `rev`, `title`?, `archived`?, `pinnedAt`?] |
| `history` | client → plugin, then plugin → that client | asked with `convId`, `before`?, `after`?; answered with those, `items`, `more`, `rev` |
| `read_cursor` | both | `convId`, `messageId` (the last reply read), `ts` (that reply's `ts`), `unread` (bool) |
| `foreground` | client → plugin | `convId`? (the conversation on screen with the app active; absent or null: none), `active`? (bool: the app is in front at all; clients with `devices`). See [Push](#push) |
| `cron_list` | client → plugin, then plugin → that client | request: `{}`; answer: `jobs` (array of [jobs](#cron_list)), or `jobs: []` and `error` |
| `device_list` | client → plugin, then plugin → that client | request: `{}`; answer: `devices` ([devices](#settings-device_list-and-device_patch)), or `error` |
| `device_patch` | client → plugin | `id` (a device's Ed25519 key), then `push` (bool) or `removed` (`true`); answered with `device_list` |
| `pair_invite` | client → plugin, then plugin → that client | request: `{}`; answer: `link`, `webLink`, `fingerprint`, `expiresAt`, or `error` ([adding a device](#adding-a-device-pair_invite)) |
| `conv_patch` | client → plugin | `convId`, then one of `title` (string; `""` clears the rename), `archived` (bool), `pinned` (bool), `deleted` (`true`). See [Titles](#titles-conv_patch-and-conv_update) |
| `conv_update` | plugin → clients | `convId`, `title`?, `archived`? (only `true`), `pinnedAt`? (epoch ms, only when pinned), `deleted`? (only `true`) |
| `upload` | client → plugin | `attachmentId`, `name`, `mime`, `size`, `index`, `count`, `data` (base64): one chunk of a file the client sends |
| `upload_ack` | plugin → that client | `attachmentId`, `index`, `done` (bool): the chunk arrived; `done` once the whole file is stored |
| `download` | client → plugin | `attachmentId`, `index`: send this chunk |
| `chunk` | plugin → that client | `attachmentId`, `index`, `count`, `data` (base64) |

#### `peer_info`

Each side sends its own as its first box and sends nothing else until it has the peer's. Each computes the highest version inside both ranges (`V3PeerInfo.negotiate` / `negotiate`). With none, the plugin sends `error {code: "update_required"}` and serves that session nothing more; the client shows "Update required" and stops. `capabilities` of both sides decide which optional features are used.

#### `tool`

One tool call of an agent run, for a collapsed row under the message it answers. `callId` is OpenClaw's tool call id (any string up to 128 characters, not a UUID); every update of one call carries the same one, and the last `status` wins: `running` when the call starts, then `done` or `failed`. `name` is the tool's name as the agent calls it (`exec`, `web_search`). Arguments and results stay in the transcript. A `tool` with another `status` value is treated as unknown.

#### History: `conv_list` and `history`

The Gateway transcript is the source of truth (#415); a client caches what it fetched (one file per conversation) and asks again. Both kinds are requests the plugin answers to the asking device's session only: every host frame still reaches every device socket, but a page is sealed once, for the device that wants it. A client keeps one request in flight and sends the next when the answer (or an `error`, or 30 seconds) arrives, so pages reach the relay paced, far under its window.

- `conv_list` lists the owner's Yorozu conversations of the configured agent: sessions keyed `agent:<agent>:yorozu:direct:owner:thread:<convId>`, newest first, at most 2000. Other channels' sessions are not listed. `updatedAt` is the session's, `rev` the transcript's newest event seq: a client whose last page that reached the newest item carried this `rev` has nothing to fetch. `title`, `archived` and `pinnedAt` are as in [`conv_update`](#titles-conv_patch-and-conv_update); archived conversations are listed too, and a client shows them apart. A cached conversation the list no longer holds, which the client synced before (it has a `rev`) or holds no message of, was deleted while the client was away, and the client drops it (not when the list holds 2000 rows and may be cut).
- `history` returns one page of one conversation, oldest first. `before: n`: the newest items with a seq below `n` (scrolling up). `after: n`: the oldest items with a seq above `n` (catching up). Neither: the newest page. `more` says another page lies further the same way. A page holds at most 60 items and about 192 KiB, and never splits the items of one transcript event. A conversation the transcript does not have yet answers `items: []`, `more: false`, `rev: 0`.

Items (`kind`, `id`, `seq`, `ts`, then by kind):

| `kind` | Fields | From |
|---|---|---|
| `user` | `text`, `attachments`? | a user message; `id` is the client's `messageId` (kept in the transcript's transport metadata). Its files are the uploads the plugin stored (from the transcript's media list); the `<file …>` blocks OpenClaw appends for a document's text are left out of `text` |
| `agent` | `text`, `attachments`? | assistant text without its `MEDIA:` lines, trimmed and chunked by `textChunkLimit` as live replies are; one item per chunk, the reply's files on the last (or an item of their own, `text` empty), as live. Cron deliveries are mirrored into the transcript as assistant messages and come out as `agent` too |
| `tools` | `tools`: [`callId`, `name`, `status`] | one row per run, at the run's first tool call; `id` is the run's user `messageId`, as for live `tool` events. `running` only while the run is the transcript's last |
| `reset` | | a `/new` or `/reset` boundary: the session started over (same session id, a reset event in the transcript) |

- `seq` is the transcript event's; items of one event share it. `ts` is epoch ms, Gateway clock. An item text is cut at 60,000 characters.
- An agent chunk's `id` is the transcript message's own id for the first chunk and derived from it (`sha256` as a UUID) for the others. A live `reply` in a turn gets the same ids (the plugin looks up the assistant message core wrote before delivering), so a device that saw it live holds one item after a page. Where that lookup fails (cron deliveries), the client matches a live reply to a page item by its trimmed text.
- An item kind the client does not know is skipped.
- `attachments` (#430) are only those the plugin can still serve: an upload it stored, or a file that went out with a live reply whose transcript id it knew. A page item without them leaves a live item's files in place.

**Client order.** Items from pages carry their `seq`; live items have none until a page holds them. A page item replaces the item with its id (or a live agent item of the same text placed after the items known to be older) and goes after the last item with a lower seq and before the first with a higher seq or a live one with a later timestamp. Live items keep arrival order between those. A client syncs on every new session: `conv_list`, then `after: <newest cached seq>` (or the newest page) for each conversation whose `rev` changed; opening a conversation does the same for it first; reaching the top asks `before: <oldest cached seq>` until `more` is false. A freshly paired device so lists every conversation and loads any of its history.

#### `read_cursor`

One conversation's read state, the same on every device (#429). Replies whose `ts` is at or below the cursor's `ts` are read; later ones are unread, and a client badges each conversation with their count and the app with the sum. `messageId` names the reply the cursor stands on; `ts` (the Gateway clock every `reply` carries: its transcript message's time, the same live and in a history page; the send time only for a reply the plugin could not find in the transcript) is what orders, so a device that lacks some replies still agrees. A client also counts as read every reply up to the one `messageId` names, at its own `ts` for it: a reply cached before plugins sent the transcript time holds its later send time. `unread` is Mark as Unread: the conversation counts as unread (at least 1) whatever the cursor says, until a read clears it.

- A client sends one when the user opens a conversation (cursor at the newest reply, `unread: false`), when a reply arrives while it is open and the app is in the foreground (cursor at the newest reply, `unread` kept: an automatic read does not undo Mark as Unread), on Mark as Read (as opening) and on Mark as Unread (cursor unchanged, `unread: true`). Mark as Unread is offered only once the conversation has a reply and is read.
- The plugin keeps one per `convId` in its keyed state store (namespace `read`). It merges: the cursor only moves forward (the stored one stays if its `ts` is greater), `unread` is the sender's. It sends the merged cursor to every device, the sender included, and every stored cursor to a device right after that device's `peer_info`, so a new or returning device knows them.
- A client applies the plugin's cursor as it comes, except while its own is unanswered: then it keeps the further `ts` and its own `unread` until a cursor at least as far with the same `unread` arrives, and it sends its own again on its next session.

#### Titles: `conv_patch` and `conv_update`

#428. A conversation's title is its session's: the manual rename (the entry's `label`) if there is one, else the generated title (`displayName`), else none. Until there is one, the client shows the first line of the conversation's first message.

- **Generated**: after a turn, a conversation with neither gets a title of its first user message that is not a slash command, from OpenClaw's own generator (`generateConversationLabel`: the agent's `utilityModel`, then its primary model) with core's dashboard title prompt, at most 60 characters, written to `displayName`. It arrives a few seconds after the first reply (one utility-model call). A failed attempt is tried again after the next turn; a rename made meanwhile wins.
- **`conv_patch`** (client → plugin) carries one change. `title`: rename, trimmed and cut to 60 characters by the plugin; `""` clears the rename, so the generated title shows again. `archived: true` / `false`: archive (`archivedAt`, `archiveReason: "manual"`, and the pin cleared, as `sessions.patch` does) or unarchive. `pinned: true` / `false`: pin (`pinnedAt`, kept if already pinned) or unpin; an archived conversation cannot be pinned (`error bad_request`). A client lists pinned conversations first, newest `pinnedAt` first. `deleted: true`: delete the Gateway way: the plugin archives the session first if it is not archived, then deletes the entry with its transcript (moved to the store's deleted-transcript archive, as `sessions.delete` does by default) and drops the conversation's read cursor. None of these touches the session's `updatedAt`, so the list keeps its order. A patch for a conversation the host does not have is answered `conv_update {deleted: true}`; one the plugin cannot apply, `error internal` with its `convId`, to the sender.
- **`conv_update`** (plugin → every device) is a conversation's state now, not a diff: `title` absent means none yet, `archived` absent means not archived, `pinnedAt` absent means not pinned, `deleted: true` means it is gone (the client drops it and its cache, and closes it if it is open). The plugin sends one whenever that state differs from what it last sent for the conversation: after its own writes, and on any other session-entry change it sees (`subscribeSessionChanges`), so a rename or archive in the Control UI reaches every device too. A device that was away catches up through `conv_list`.
- A client applies its own patch as soon as it is on the socket; the `conv_update` confirms it. Without a session the actions are disabled. A `conv_update` for a conversation the client does not have adds it, empty until `history` fills it.
- The [push](#push) title is the conversation's title; before it has one (the first reply's push goes out before the title is made), its first message's first line.

#### `cron_list`

The Automations tab (#432; Crons until 2026-10-17). A client sends `cron_list {}`; the plugin answers that device only (not every served session) with every cron job of `channels.yorozu.agent`, disabled ones included, sorted by name. A job with no `agentId` counts as the system agent's (`agents.defaults.systemAgent.agentId`), else the sole agent's; with neither it is listed for no one. Read-only: there is no cron admin kind; "Edit in chat" asks the agent instead. A data with neither `jobs` nor `error` is a request, so a client ignores one.

| Field | Meaning |
|---|---|
| `id` | OpenClaw's job id |
| `name` | The job's `displayName`, else its `name` |
| `enabled` | false: the client shows the job greyed |
| `schedule` | OpenClaw's schedule object as stored: `kind` (`at`, `every`, `cron`, `on-exit`, `stream`) and its fields |
| `scheduleText` | The plugin's English wording of `schedule`: `Every 30 minutes`, `Daily at 09:00 (Asia/Tokyo)`, `Weekdays at 08:30`, `Once`; any other cron expression as `Cron <expr>`. Clients show it as it is |
| `nextRunAt`?, `lastRunAt`? | Epoch ms, the scheduler's |
| `lastStatus`? | `ok`, `error` or `skipped`; absent before the first run |
| `lastError`? | The last run's error, at most 2,000 characters |
| `delivery`? | Only when the job delivers into a Yorozu conversation: `{channel: "yorozu", threadId: <convId>}`. The client opens that conversation from the row |

The wording lives in the plugin so every client says the same thing without a cron parser of its own; `schedule` travels raw for a client that wants to word it itself later. When the plugin cannot read the cron store the answer is `{jobs: [], error}` and the client keeps its last list under the error. "Edit in chat" opens the job's delivery conversation, or a new one, with `Change cron job "<name>" (id <id>): ` in the composer, unsent.

#### Settings: `device_list` and `device_patch`

The client's Settings (2026-10-17). Only between peers that both list `devices`. A client sends `device_list {}`; the plugin answers that device with every paired device, oldest first: `id` (its Ed25519 relay key), `name`? (its model from `peer_info`), `pairedAt` (epoch ms), `push` (bool, whether the host pushes to it) and `current` (it is the asking device). `device_patch {id, push}` turns that device's push on or off (kept in the allowlist row; absent means on); `device_patch {id, removed: true}` removes it as `openclaw yorozu devices remove` does: the row goes, its session is dropped and the relay forgets it. Either is answered with a fresh `device_list` to the sender, or `{error}` for an unknown id. A client removes itself this way when the user unpairs, before forgetting the host. These two are Yorozu's only admin kinds.

#### Adding a device: `pair_invite`

A paired device adds another, away from the host (owner, 2026-10-17). Only between peers that both list `invite`. A client sends `pair_invite {}`; the plugin mints the same one-time code `openclaw yorozu pair` prints ([Pairing](#pairing)) and answers that device with it: `link` (`yorozu://pair?…`), `webLink` (what the QR carries), `fingerprint` (the host key's) and `expiresAt` (epoch ms, the relay's), or `{error}` while the relay is not reachable. The client shows the QR and a link to send; the new device pairs with it as with one from the host: one device, ten minutes, the fingerprint compared on both. Any paired device may ask: it is already trusted with the conversations and can remove devices.

#### Attachments

Images and files both ways (#430), each at most the plugin's `mediaMaxBytes` (`channels.yorozu.mediaMaxMb`, else `agents.defaults.mediaMaxMb`, else 8 MB), in chunks of 160 KiB of raw bytes (`CHUNK_BYTES`, `V3Attachment.chunkBytes`), so every box stays far under the relay's 1 MiB frame. Both sides speak it only when the other lists `attachments` in `capabilities`; to a client that does not, the plugin sends a reply's files as a line of text each. An attachment is `{id, name, mime, size}`; `id` is a lowercase UUID made by the side that has the bytes, and names the transfer. `count` is `max(1, ceil(size / 160 KiB))`; every chunk but the last is full.

- **Client → agent.** The client checks the size against `mediaMaxBytes` before it copies anything and refuses a larger file in front of the user. It holds a message with files until a session is up (so nothing waits in the relay's 5 MiB offline buffer), uploads each file as `upload` chunks, four in flight, each answered `upload_ack` to that device alone, then sends the `message` naming the files whose last ack said `done`. The plugin refuses a file over its limit with `error {code: "too_large", attachmentId}` and a chunk that does not fit its upload with `bad_request`; the client then leaves that file out of the message and marks it. A finished upload goes into OpenClaw's media store (`media/inbound`) and its id into the keyed state store (namespace `attachments`), so a repeated upload of a stored id is answered `done` at once and a restarted plugin still knows it. Partial uploads live in memory: an upload cut by a lost session starts over from chunk 0 on the next one. The turn gets the files as media facts (`toInboundMediaFactsWithMetadata`): images reach a vision model as image input, a PDF as rendered pages plus its path.
- **Agent → client.** A reply's media (a `MEDIA:` line in the agent's text, the message tool, or a cron delivery's `sendMedia`) is staged into the media store (`media/outbound`, `resolveOutboundAttachmentFromUrl` with the agent's media roots) and announced in the `reply`'s `attachments`, on the last text chunk or on a reply of its own, as one group. Nothing more is sent until a device asks: every host frame reaches every device in the room and counts against its 2 MiB window, so each chunk goes only on that device's `download`, sealed for it alone. A client downloads an image when it is shown and a file when it is tapped, one file at a time with two chunks in flight, and starts over on the next session if one is cut. An id the plugin never announced, or whose file is gone, is answered `error {code: "not_found", attachmentId}`. A file the agent names that cannot be staged (outside the allowed roots, over the limit) becomes a `(Couldn't attach …)` line in the reply's text.

#### `error` codes

| `code` | Meaning |
|---|---|
| `update_required` | No common protocol version |
| `bad_request` | A kind the receiver knows but cannot act on (for example a `message` for a conversation it refuses) |
| `run_failed` | The agent run for `messageId` failed; `message` says why |
| `too_large` | An `upload` over the plugin's `mediaMaxBytes`; `attachmentId` names it |
| `not_found` | A `download` of an attachment the plugin does not hold; `attachmentId` names it |
| `internal` | Anything else, also a `conv_list` or `history` the plugin could not read, or a `conv_patch` it could not apply |

A receiver treats an unknown code like `internal`.

## Delivery

All paired devices share one channel peer (the owner), so the plugin sends `delivered`, `run_started`, `typing` and `reply` to every served session, each sealed under that device's own session key.

- ✓ sent: the relay's `accepted` for the frame that carried the `message`.
- ✓✓ delivered: `delivered` for its `messageId`, sent as soon as the box opens.
- read: `run_started`.
- Typing: `typing {active: true}` from run start, repeated at least every 10 seconds while the run lasts; `typing {active: false}` when it ends. A client also hides it after 30 seconds without a repeat. A command such as `/new` may answer with a `reply` and no typing at all.
- Replies arrive whole, one `reply` per chunk of a long reply (chunked by `channels.yorozu.textChunkLimit`, default 4000 characters), never edited in place. A cron job delivering into a conversation (`delivery: {channel: "yorozu", to: "owner", threadId: <convId>}`) arrives as `reply` too, with no `run_started` or `typing`.
- A `message`'s `text` is bounded only by the relay's 1 MiB frame (about 700 KiB of text). Slash commands are plain text: `/new` and `/reset` reset only that conversation's session, other commands go to OpenClaw as typed.
- A client sends `message`s only inside an established session. Until it sees `delivered` it keeps the message and sends it again in its next session. The plugin drops a `messageId` it has already taken and answers `delivered` again.

## Push

One push per finished agent reply (#431), through the relay's `notify` as in v2 ([history](history/ios-relay-contract-v2.md#push)), with a preview sealed for each device. A cron job delivering into a conversation pushes the same way. There is no mute.

- **Token**: an iPhone or iPad sends the relay `{"type":"push","deviceToken":<lowercase hex>}` after every `joined` on its socket, and again as soon as iOS hands it a new token (`V3Connection.registerPush`). It asks iOS for a token on every launch. The relay keeps one token per device and forgets it when the device is revoked. The Mac client registers no token.
- **When**: once per finished reply, after its last chunk has gone out, never once per chunk. That is the end of an agent turn that sent at least one `reply` (`handleMessage`), or the end of one delivered payload (the outbound adapter's `afterDeliverPayload`, which is how a cron delivery arrives). A turn that only failed (`error run_failed`) does not push.
- **Foreground**: a client sends `foreground {convId}` when a conversation is on screen with the app active, and `foreground {}` (no `convId`) when none is, including just before iOS suspends it. A client with `devices` adds `active` (the app is in front at all), and sends again when only that changes. It sends its current one again on every new session; a new session starts with none. The plugin skips every device whose live session last reported that conversation or `active: true`: an app in front shows its own [in-app notice](#push) instead. It also skips devices whose push is off ([Settings](#settings-device_list-and-device_patch)). When the relay reports that no device socket is left (`phones {count: 0}`), the plugin forgets every device's foreground, in case a device was killed in the foreground. When no device is left, it sends no `notify` at all.
- **`notify`**: `{"type":"notify","class":"reply","threadRef":<threadRef(convId)>,"eventRef":<threadRef(messageId of the first chunk)>,"previews":{<device Ed25519 key>:{n,c}},"devices":[<device Ed25519 key>,…]}`. `threadRef` is `YorozuCrypto.threadRef`, the first 8 base64url characters of SHA-256, so the relay sees no conversation id. `devices` names the devices to alert, and the relay alerts only those (#447, deployed 2026-10-17). A relay without it alerts every registered device; the client does not show such an alert while the app is in front. The relay allows 60 notifies a minute per room.
- **Read elsewhere**: the plugin remembers, per conversation, the devices it alerted since the conversation was last read. When a `read_cursor` without `unread` arrives, it sends `{"type":"notify","class":"sync","threadRef":<threadRef(convId)>,"devices":[…]}` for those devices except the reader. The relay wakes each one whose socket is not live with a background push (`content-available`, no alert), not held to its one-a-minute background interval. A woken iPhone or iPad connects for a few seconds; the plugin's `read_cursor`s on the new session remove what was read. Only for a relay with `sync`: an older one answers `bad notify`.
- **Preview**: `PushPreview` (`packages/YorozuWire`, and `src/push.ts` in the plugin), unchanged from v2 except for two optional fields. The key is HKDF-SHA256 over X25519(host static, device static) with salt `yorozu-v1` and info `yorozu-push-preview/mac->device`, 32 bytes, so it is never a session key. The box is ChaCha20-Poly1305 with a fresh 12-byte nonce. The plaintext is JSON `{"b":<first line of the reply>,"c":"reply","e":<eventRef>,"t":<title>?,"v":<convId>}`, at most 256 bytes. The title is cut to 32 characters first, then the body is cut with "…" until the whole fits. The title is the conversation's [title](#titles-conv_patch-and-conv_update) (#428); before it has one, its first message, first line (stored per conversation in the plugin's state, namespace `push-titles`). A conversation that began with a delivery has none until it is titled.
- **iPhone, iPad**: the app keeps the preview key in the Keychain group it shares with the notification service extension (`PreviewKeychain`, readable after the first unlock). It writes the key on every connect and deletes it on unpair. The extension opens `preview`, checks that its `e` equals the push's `event`, and sets the title to `t` (else "Yorozu replied."), the body to `b` and `userInfo.convId` to `v`. Anything that does not open is shown as the relay sent it. In the foreground no notification is shown as a banner: a reply in a conversation not on screen shows as the in-app notice, a capsule at the top with its title and first line (tap opens it, swipe up or 3 seconds dismisses it, the next one replaces it, an optional light haptic). A tap opens its conversation, found by `convId`, else by the relay's `ref` matched against the cached conversations. Opening a conversation removes its delivered notifications, and so does any `read_cursor` without `unread`, sent or received: those delivered no later than 15 seconds after the cursor's `ts`. Alerts, sounds and badges are asked for after pairing (the first `peer_info`) and at every launch while paired; iOS shows the prompt only once.
- **Mac**: no relay push. While the app is in front, a new `reply` in a conversation not on screen shows the in-app notice. While it runs behind other apps, each new `reply` posts a local notification, one per conversation, replaced by the next. Only the first chunk within 10 seconds plays a sound.
- Neither end logs a preview's plaintext. The plugin logs how many devices it alerted and skipped.

## Known-answer vectors

Every input below is `sha256("yorozu-v3 vector: <label>")`. Swift generated these vectors with both roles. The TypeScript reproduced every field byte for byte, and Swift checked the TypeScript's output in turn. Both implementations also pass the independent `Noise_IK_25519_ChaChaPoly_SHA256` vector in [cacophony](https://github.com/haskell-cryptography/cacophony/blob/master/vectors/cacophony.txt) (handshake, handshake hash and four transport messages). Hex unless noted.

**Inputs**

| | Private (label) | Public |
|---|---|---|
| Client X25519 static (`device static`) | `472981471d3db9944ab7b4adb340a1a712c773ea35d8f37bd1efcdc42c7cd577` | `f13a8bed59b6f0cd491faa6519820c9a5d25cb80cdaa88f636c4dcc117f6916e` |
| Client Ed25519 seed (`device signing`) | `9585003d4bc331d9e01c6761ee4e9156364fcd178a10f6cd254ed785fae615c9` | `00afcb53bd049e3d59475d9c24dacc6827e54271d426279bf358f29b73413aab` |
| Host X25519 static (`host static`) | `c43ff659320eca515ef8504603797fd914e70aeccf283cbb24a061274d689d9d` | `eed892a4b33e5ec2131d452cafc3704febb2573bb8dd4b52767bc9ba51494e61` |
| Host Ed25519 seed (`host signing`) | `2f2ea35ebecd22b3f6fbc52b81accd61ea577ea954f07684249841f687b7304b` | `58ff94bc161ae501a7a2bbaf14f85d40aa8a384081e207629213fafe3a4f9579` |
| Client ephemeral (`device ephemeral`) | `513d28b79d173cf33f06dc70e798f34a9710df46429144a1adb4bbd87f5eebf9` | `dd06249f994a25caa535945ce1791dafeeba84e70d7638fa5248901442594f6f` |
| Host ephemeral (`host ephemeral`) | `7fc74ca1e4e4b958ac784ec6d611f8fe225402d3ce9cbd6fb301a4087fd76341` | `d2a27772f14897fc6e84923c2bab923d1447dc9777cc79250b1fa4fd83e0b460` |

QR secret `yorozu-vector-secret`, `ts` `1760000000000`, relay `wss://relay.example`, token `dG9rZW4`.

**Pairing**

- Room id: `hI_OlBO5JKlna6g8b2wyZ-LXaoXbMvib3Mmr4mU8dTw`
- Fingerprint: `EED8 92A4 B33E 5EC2`
- Link: `yorozu://pair?v=3&relay=wss://relay.example&key=7tiSpLM-XsITHUUsr8NwT-uyVzu43UtSdnvJulFJTmE&token=dG9rZW4&room=hI_OlBO5JKlna6g8b2wyZ-LXaoXbMvib3Mmr4mU8dTw&secret=yorozu-vector-secret`
- `helloProof`: `TuRTfSHfcOngVAJdjjgYi74ZhAFrvWCUV1vcybaFW0c`

**Handshake**

- Prologue (UTF-8): `yorozu-v3|hI_OlBO5JKlna6g8b2wyZ-LXaoXbMvib3Mmr4mU8dTw|AK_LU70Enj1ZR12cJNrMaCflQnHUJieb81jym3NBOqs`
- Message 1 payload (UTF-8): `{"proof":"TuRTfSHfcOngVAJdjjgYi74ZhAFrvWCUV1vcybaFW0c","ts":1760000000000}`
- Message 1:
  ```
  dd06249f994a25caa535945ce1791dafeeba84e70d7638fa5248901442594f6fba0f982567d4dec76edc9749bf8927f4
  fefb729652502f3d3bfc5a6527d743f8a3ea1ef869d412d2331f6179d004ab2886f17cf9c63e0a82798838dd8b153c1b
  8b83821481647a127be71f5602da4d347104b319b3928a522c5aa1cb46dcabad3ad020c986dcd0b24ac4ddba76c6ba05
  6d91dd76105a0b168921684e1bb2a59ecff67a4bdb9712d56219
  ```
- Init frame payload (base64url):
  ```
  AwEAr8tTvQSePVlHXZwk2sxoJ-VCcdQmJ5vzWPKbc0E6q90GJJ-ZSiXKpTWUXOF5Ha_uuoTnDXY4-lJIkBRCWU9vug-YJWfU
  3sdu3JdJv4kn9P77cpZSUC89O_xaZSfXQ_ij6h74adQS0jMfYXnQBKsohvF8-cY-CoJ5iDjdixU8G4uDghSBZHoSe-cfVgLa
  TTRxBLMZs5KKUixaoctG3KutOtAgyYbc0LJKxN26dsa6BW2R3XYQWgsWiSFoThuypZ7P9npL25cS1WIZ
  ```
- Message 2 (empty payload): `d2a27772f14897fc6e84923c2bab923d1447dc9777cc79250b1fa4fd83e0b460dfa4365365e8149fec8378a759c91cec`
- Response frame payload: `AwLdBiSfmUolytKid3LxSJf8boSSPCurkj0UR9yXd8x5JQsfpP2D4LRg36Q2U2XoFJ_sg3inWckc7A`
- `sid`: `dd06249f994a25ca`
- Handshake hash: `9cc67735edc3440f98d51ea14749f0e20da36c16509d35b8fedfa0f0b68d0d10`

Ed25519 signatures are not fixed (CryptoKit's are randomized); each side checks that the other's signature over the init frame payload verifies.

**Transport** (plaintexts are UTF-8, exactly these bytes)

Client → plugin, counter 0, plaintext `{"data":{"app":"0.8.0","capabilities":[],"name":"iPhone","protocolMax":3,"protocolMin":3},"kind":"peer_info"}`:

```
0303dd06249f994a25ca0000000000000000945c6860d1fbb144a0e84d5f74e59e8ab07b61cb40de683c94de3ad004d6
f9c83760a90e5a23d409d117fd1fe44051ae99eb0b7cef80b44c18845385c1d9d2f278c3564073e675d19ef196aa9370
f4b578d1be4af76d3b958e8b0e0ae18c48d54c709105b458de3b6d15e9f0ee8a9640248f25992ef00875a5b41392d7
```

Client → plugin, counter 1, plaintext `{"data":{"convId":"0b5c3a52-8f3e-4b8e-9a51-2d6f0c1e7a90","messageId":"6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b","text":"こんにちは"},"kind":"message"}`, frame payload:

```
AwPdBiSfmUolygEAAAAAAAAAweAcRUT-nEGJjnwZjI1XU0N7h6OFIXg_XU2uYmn7KvtBmPSu8XYEKuhm09FGNJ1b46nVOpRQ
JX-XA6cyDOkvKhpzNptVrl4T9VX5uOZW3v5k6PUdcv2OD6eCokXJgxNHwCLQM5WSRXjpMRMw3_CNwvaySLNLPqcu1YvjbT1K
U61w86oJzYUk9yWn6Z1quOIIJY4vn4t1ZHnldPk1TRCKDKlvddNZKl0
```

Plugin → client, counter 0, plaintext `{"data":{"app":"0.1.0","capabilities":[],"name":"Mac","protocolMax":3,"protocolMin":3},"kind":"peer_info"}`, frame payload:

```
AwPdBiSfmUolygAAAAAAAAAAPN5CvY_FAr8Jlk4JiqTJNO7CtHU5OJEjkwnpf1xiHmbAfN5BtEKIsF3RgUtZmWbiY_sK0_Vd
uNJEgG3Zo2vJeD9hurxhdX1EC8lPYHfo2vokCD47-Wu5mQ7zjeewMfwcnm6OcGJcS0kgyGjyHNLv9yDNe68-oj-lZeg
```

Plugin → client, counter 1, plaintext `{"data":{"convId":"0b5c3a52-8f3e-4b8e-9a51-2d6f0c1e7a90","messageId":"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d","text":"Hello!","ts":1760000001500},"kind":"reply"}`:

```
0303dd06249f994a25ca0100000000000000ab4924ea2152deaf8bc0ca65c159f79278007ff23b7354fe092b1bdaff4b
f575de97783c90cb32c996951391314611127a7e72aa3ab78e7fbc6eaebeb25aabe28d7ac790d14328231635c815bd97
128349f832a9af06a6ff652edb34bc540a081ee1c8356e1ed91d1948ea00f17fe51097ee4d287de84075940f1fcb8439
7dee0d8086c9fbf552353c5065dbb2689a96a7fec3423c972a170d2558bec0c9929ce34668ff8274b89c057dba66a5afe2
```

The same run also checks that the second box opened again is refused as a replay, that a box reflected to its sender fails, that an init with `ts` more than 5 minutes either side of the host clock, under another room or to another host key is refused, that a signature by another key fails, and that a v2 payload is not a v3 frame.

## API

| Need | Swift (`YorozuWire`) | TypeScript (`src/wire.ts`, `src/envelope.ts`) |
|---|---|---|
| Keys | `PhoneIdentity.generate()` | `x25519Keypair()`, `ed25519Keypair()` |
| Relay signature | `YorozuCrypto.signFrame` / `verifyFrame` | `signFrame(priv, payload)`, `verifyFrame(pub, payload, sig)` |
| Room, fingerprint, proof | `QrPayload.roomId` (from the QR), `QrPayload.fingerprint`, `YorozuCrypto.helloProof` | `roomId`, `fingerprint`, `helloProof` |
| Pairing link | `QrPayload(v: 3, …).encoded()`, `QrPayload.decode` | `beginPairing()` (`src/relay.ts`) |
| Handshake | `V3ClientHandshake(identity:pairing:)`, `.frame`, `.finish(_:) -> V3Session` | `acceptHandshake({host, room, payload, sig}) -> AcceptedHandshake \| null` |
| Relay link (join, handshake per socket, reconnects, `accepted`, `flowAck`) | `V3Connection` (client only) | the host loop in `src/relay.ts` |
| Frames | `V3Frame(payload:)`, `.payload`, `.sid` | `decodeFrame`, `encodeFrame`, `frameSid` |
| Boxes | `V3Session.seal(_:)`, `.open(_:)`, `.openEvent(_:)` | `Session.seal(bytes) -> payload`, `.open(frame) -> Buffer \| null` |
| Envelope | `V3Event` (`Codable`), `V3PeerInfo.negotiate`, `V3Event.newId`, `isId` | `Event`, `parseEvent`, `encodeEvent`, `negotiate`, `isId` |
| Attachments | `V3Attachment` (`capability`, `chunkBytes`, `chunkCount`), `V3Upload`, `V3UploadAck`, `V3Download`, `V3Chunk` | `Attachment`, `ATTACHMENTS`, `CHUNK_BYTES`, `src/attachments.ts` |
| Noise itself (vectors) | `NoiseIKHandshake` | `NoiseIK` |
| Push preview (#431) | `PushPreview.key`, `.open(userInfo:key:)`, `V3Connection.registerPush` | `previewKey`, `previewPlaintext`, `sealPreview`, `threadRef` (`src/push.ts`), `notifyReply` (`src/relay.ts`) |
| Settings | `V3Devices.capability`, `V3DeviceList`, `V3DeviceInfo`, `V3DevicePatch`, `V3Foreground.active` | `DEVICES`, `DeviceList`, `DeviceInfo`, `DevicePatch` (`src/envelope.ts`); `device_list`, `device_patch`, `sync` in `src/relay.ts` |
| Adding a device | `V3Invite.capability`, `V3PairInvite` | `INVITE`, `PairInvite` (`src/envelope.ts`); `pair_invite` in `src/relay.ts` |
