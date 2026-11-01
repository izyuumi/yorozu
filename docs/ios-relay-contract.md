# The wire: client ⇄ plugin

The wire between the Yorozu client app (iPhone, iPad, Mac) and the OpenClaw channel plugin, through the relay. Implementations:

| Side | Code |
|---|---|
| Client (Swift, CryptoKit) | `packages/YorozuWire/Sources/YorozuWire/`: `Wire.swift` (Noise, frames, boxes), `WireEvent.swift` (envelope), `RelayConnection.swift` (relay or direct link), `Direct.swift` (probe, race), `DirectCandidates.swift` (hints, candidates, Bonjour), `Pairing.swift`, `DeviceCode.swift`, `PushPreview.swift`, `Crypto.swift` |
| Plugin (TypeScript, `node:crypto`) | `plugins/openclaw-yorozu/src/`: `wire.ts`, `envelope.ts`, `hub.ts` (sessions on either path), `direct.ts` (direct listener), `relay.ts` (relay link and dispatch), `push.ts`, `attachments.ts`, `history.ts`, `sessions.ts`, `reads.ts`, `cron.ts` |
| Relay | `apps/relay/src/`: `protocol.ts` (shared rules), `worker.ts` (deployed), `index.ts` (Node), `mailbox.ts` |

Change a message only with a matching change on both sides. The Swift client and the plugin never run against each other in a test: the relay has tests (`apps/relay/src/*.test.ts`), among them `direct.test.ts`, which runs the plugin's session core and direct listener against a device built on the plugin's own Noise code, directly and through the Node relay; the plugin's pure files have `node --test` tests (`plugins/openclaw-yorozu/test/`); and one fixture (`apps/ios/Tests/Fixtures/activity-content-state.json`) is shared by the plugin, relay and app tests. The rest is checked by compiling and running. Merging a change under `apps/relay/**` deploys the Worker (`.github/workflows/deploy-relay.yml`, `wrangler deploy` on push to `main`).

Layers, outside in:

1. [Relay](#relay): rooms, joins, Ed25519-signed frames, offline buffer, push. Or the [direct path](#direct-path): the plugin's own listener, a probe, the same signed frames.
2. [Frames](#frames): the relay `payload`, binary, base64url.
3. [Handshake](#handshake): Noise IK per connection.
4. [Transport boxes](#transport-boxes): numbered ChaCha20-Poly1305 boxes under the session keys.
5. [Envelope](#envelope): JSON `{kind, data}` inside each box.

## Relay

The relay parses only its own JSON envelope and forwards `payload` unread. Messages are JSON objects with a `type`; anything malformed closes the socket. A `type` the relay does not know is ignored (it still counts against the rate limit), unknown fields are ignored, and so are a `notify` of an unknown `class` and an `activityPush` of an unknown `event`; a job of an unknown `kind` or `state` is dropped from an `activityPush` and the rest go out.

**Connecting.** Every socket gets `{"type":"nonce","nonce":…}` first and must `register` or `join` within 10 s (close `1008 auth timeout`). Both sides dial `<relay>?room=<room id>`: the Worker routes on it before any message; the Node relay ignores it.

- **Room id**: `base64url(sha256(host Ed25519 public key))`, 43 characters (`roomId` in `wire.ts`; the client reads it from the pairing link).
- **Host** sends `register {pubkey, nonceSig}` (Ed25519 over the nonce) and gets `registered {roomId, phones}`. The Worker binds a room to the first key that registers in it. A new registration replaces the old host socket (`4001 replaced`). The relay then replays buffered device frames, each with a `seq`; the host answers `ack {seq}` and unacked frames replay on the next registration.
- **Device** sends `join {roomId, phonePubkey, sig, token?}`. With `token` (first join) `sig` is over the token, which is spent; without, `sig` is over the nonce and the relay must already know the device. Answer: `joined {roomId, ownerOnline, flowControl?}`. Refusals close with `4001` and `unknown token`, `expired token` or `unknown device`, or `4003 bad join signature`.

**Host messages.** `mint` → `token {token, expiresAt}` (10 minutes; at most 8 live per room by default, oldest dropped). `devices {devices: [Ed25519 key…]}` replaces the room's known-device set (devices with a live socket are kept); the plugin sends it after every `registered`. `revoke {pubkey}` forgets that device and its push tokens and closes its sockets (`4001 revoked`). `push {device, token}` registers an APNs token (hex) for a known device (43-character base64url Ed25519 key) and refreshes that device's last-seen time, silently ignoring unknown devices; send only when `registered.pushProxy` is true (`push-proxy`, #532). `notify` ([Push](#push)). `activityToken` and `activityPush` ([Live Activity push](#live-activity-push)). From the relay: `phones {count}` when device sockets come or go, `state {state}` (for example `notify rate limit`), `activityGone {device}`. Both relays' `registered` carries `pushProxy: true`. The Worker's `registered` carries `liveActivity: true` when it has an APNs key; the Node relay's never does.

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
| Known devices per room | 16 | the least recently seen is forgotten when a new token join arrives; a join or host `push` for the device counts as seen |
| `notify` per room | 60 per minute | `state {state: "notify rate limit"}`, not sent |
| `activityPush` per room, a budget of its own | 60 per minute | `state {state: "activity rate limit"}`, not sent |

The client acks flow every 256 KiB or 16 frames. Because every host frame counts against every device's window, the plugin sends bulk data (history pages, attachment chunks) only to the device that asked and only on request.

## Direct path

Capability `direct` ([#532](https://github.com/izyuumi/yorozu/issues/532)): a client reaches the plugin without the relay. The direct path is a byte pipe for the same Noise sessions; it adds no encryption of its own and buffers nothing.

**Listener** (`direct.ts`). The plugin runs its own WebSocket server (not a Gateway route), on by default (`channels.yorozu.direct.enabled`), on port 8738 (`channels.yorozu.direct.port`, 1024–65535, [setup](setup.md#2-config)). It binds one server per local address of an allowed kind, read from the network interfaces when the channel starts: loopback (127.0.0.0/8, `::1`), RFC 1918 (10/8, 172.16/12, 192.168/16), ULA (fc00::/7) and 100.64.0.0/10. Never `0.0.0.0`, `::`, a link-local or a public address; no setting widens that (`directAddress`). A request carrying an `Origin` header (a browser page) is refused. The plugin lists `direct` in its `peer_info` only while at least one server is listening. It follows address changes: it polls the interfaces every 5 s and, when the allowed addresses change, rebinds its servers and resends [`direct_hints`](#kinds).

**Hints** (`direct_hints`, `DirectHints`). The client lists `direct` in its own `peer_info`; the plugin sends such a session `direct_hints` right after the client's `peer_info` and again whenever its addresses change: `port`, the listener's port; `lan`, its private addresses with their prefix lengths (`{address, prefix}`); `tailscale`, its 100.64.0.0/10 and `fd7a:115c:a1e0::/48` addresses (`{address}`); `magicDNS`, the host's Tailscale name, when it has one. Addresses are IPv4 or IPv6 literals. The client drops an invalid address, prefix or name and ignores unknown fields; a `port` outside 1–65535 makes the event unknown. It keeps the latest per pairing room (`DirectHintStore`, user defaults `yorozu.directHints.<room>`), forgets them where it forgets the race winners, and reads them at the start of each race.

**Candidates** (`DirectCandidates.plan`), in this order, each a `ws://<host>:<port>` URL with IPv6 literals bracketed:

1. Loopback, on a Mac only: `ws://127.0.0.1:8738` and `ws://[::1]:8738`. A Mac on the Gateway's machine needs no Local Network permission. Loopback is left out when the host advertises LAN or Tailscale addresses and none matches any local interface, up or down; no address hints means loopback is kept.
2. Each `lan` address whose subnet (the hint's address and prefix) holds an address of an up, non-VPN local interface (`getifaddrs`), on the hints' `port`; only while Local Network is allowed.
3. Each `tailscale` address, then the `magicDNS` name, on the hints' `port`; only while an up VPN-style interface (`utun*`, `ipsec*`, `ppp*`) holds an address in 100.64.0.0/10 or `fd7a:115c:a1e0::/48`. The name is the fallback after the IPs.

Each race logs the left-out hints and why (`skipped 10.77.0.5 (not on this subnet), 192.168.0.9 (Local Network not allowed yet)`); the MagicDNS name is logged only as "the MagicDNS name". A client still holding its pairing secret has no direct candidate and does not browse: it pairs over the relay first.

**Local Network** (iOS, and macOS 15 and later). `LocalNetwork.allowed` (user defaults `yorozu.localNetwork.allowed`, default false) is the owner's go-ahead; while it is false the client skips LAN candidates and Bonjour quietly, on every platform; loopback, Tailscale and the relay need no permission and keep working.

- **Explainer.** Once the first session after pairing opens (`state` ready, not in demo, `LocalNetwork.explained` still false), the app shows a sheet on iPhone, iPad and Mac: "Connect directly on Wi-Fi?", what the direct path does, that messages stay end-to-end encrypted either way, and that iOS asks for Local Network access next (on the Mac: that macOS may ask). Devices paired before the explainer see it once too, after their next connect. Continue sets `allowed` and `explained`, runs `LocalNetwork.refresh()` (an `NWBrowser` probe; on iOS the first one shows the system prompt) and starts a new race (`RacingConnection.raceAgain()`, unless direct already won). Not Now, or swiping the sheet away, sets only `explained`.
- **Denied.** `refresh()` stores whether the system denies Local Network (`LocalNetwork.denied`); LAN is usable only while allowed and not denied (`LocalNetwork.usable`). A denial is quiet: the LAN legs and Bonjour are left out and the race goes on without them. Each time the app becomes active while `allowed && denied`, it runs `refresh()` again, and if the denial is gone it races again, so turning the switch on in Settings takes effect without a relaunch.
- **Settings › Host.** The toggle "Direct on Local Network" sets the same go-ahead (on: `allowed`, `explained`, `refresh()`, a new race; off: `allowed = false`, a new race). While allowed but denied, its footer says that Local Network access is off for Yorozu, so it connects through the relay or Tailscale, with "Open Privacy › Local Network": the app's own page in iOS Settings (`UIApplication.openSettingsURLString`), or System Settings › Privacy & Security › Local Network on the Mac.
- **Connection row.** Settings › Host shows the path the session runs on, right after Status: "Direct (Wi-Fi)", "Direct (local network)", "Direct (Tailscale)", "Direct (this Mac)" or "Relay", from `RelayConnection.Update.route(DirectRoute)`, which the race yields each time a path wins, just before `sessionOpen`. "Direct (local network)" means a LAN route on a network that is not Wi-Fi, such as a wired Mac. Under it, when the route last changed ("Since 18:44" today, else relative); the same route winning again keeps the time. The row is hidden while disconnected; the route is cleared on unpair and on entering demo mode, whose scripted session reports Direct (Wi-Fi).

The app's Info.plist has `NSLocalNetworkUsageDescription` ("Yorozu connects directly to your host on the same network, for faster messages.", in all nine languages) next to `NSBonjourServices`.

**Bonjour.** The plugin advertises `_yorozu._tcp` with instance name `<tag>`, TXT `t=<tag>` and IPv4 A records, never the room id or host name. `tag` is base64url, unpadded, of the first 9 bytes of HMAC-SHA256 keyed with the host's static X25519 public key (the 32 bytes of the link's `key`) over UTF-8 `yorozu-bonjour:<hour epoch>` (`Direct.bonjourTag`); for the key bytes 0, 1, …, 31 and epoch 493000 it is `Iaz7DaMYBz9S`. The plugin re-advertises with the new tag each hour; the client accepts the tags of the previous, current and next hour. While Local Network is usable, each race browses (`NWBrowser`, `.bonjourWithTXTRecord`, `local.`) alongside its candidates; a result whose `t` is one of the pairing's tags is resolved to its IPv4 address and port (a TCP connection's remote endpoint, closed at once), kept only on a subnet of an up, non-VPN interface, and added to the race in flight as one more direct leg unless the race already dials that URL. Browsing stops when a session opens, the race ends, or after 5 s. The app's Info.plist lists `_yorozu._tcp` in `NSBonjourServices`.

**What Bonjour shows an observer.** The tag is derived from the host's key and rotates every hour, so someone watching mDNS can no longer link the advertisement across networks or days by its tag, and it never names the room or the host. What is left: within one hour, and while the host stays on one network, its IP address, port and continuity still link the advertisement; the host machine's own mDNS name and MAC address are outside Yorozu's control. A host clock off by more than an hour only loses Bonjour; the unicast LAN candidates from the plugin's hints still work.

**Messages**, JSON objects with a `type`, both ways:

| Message | Direction | Fields |
|---|---|---|
| `probe` | client → plugin, first | `nonce`: 32 random bytes, base64url |
| `probe` | plugin → client | `pubkey`: the host's Ed25519 key, base64url; `sig`: Ed25519 over UTF-8 `yorozu-direct\|<room id>\|<nonce>` |
| `frame` | both | `payload`, `sig`: one [frame](#frames), signed as on the relay (the client with its Ed25519 key, the plugin with the host's); never batched |
| `accepted` | plugin → client | `sig` of a client frame whose box the plugin opened: the client's ✓ sent |
| `ping` / `pong` | client → plugin / answer | the exact strings `{"type":"ping"}` and `{"type":"pong"}` |

- The client sends nothing but the probe until the answer checks out: `base64url(sha256(pubkey))` equals the pairing's room id and `sig` verifies (`Direct.verifyProbe`, `verifyProbe`). Otherwise it closes the socket. A listener that has not proven the key gets neither the client's key nor an init, and a direct socket never handles `nonce`, `joined` or `owner`, so it can never obtain a join signature.
- Then the client sends its init frame, and the session goes as over the relay: response and `peer_info`, then boxes. The plugin checks every frame's `sig` against the device key the init frame named, opens boxes only under that socket's session, and ignores unknown message types once the session is open.
- Only an allowlisted device's init is answered; pairing over the direct path is not yet possible.
- The client pings every 25 s; the plugin drops a direct socket silent for 90 s.

**Limits and close codes**, a range of their own, never the relay's:

| Limit or event | Value | Close |
|---|---|---|
| Sockets waiting for their handshake | 8 | `4101 unauthorized`, for the ninth |
| Time to an open session | 10 s | `4101` |
| Anything but a probe first, a malformed nonce, anything but an init frame next, a refused handshake (unknown device, stale, replayed), a bad frame signature, an `Origin` header | — | `4101` |
| Another session for the same device, on either path | newest wins | `4102 replaced`, for the older direct socket |
| One WebSocket message | 1 MiB | `4103 too large` (`1009` from the WebSocket layer above 2 MiB) |
| Device removed or revoked | — | `4101` |

**Race** (`RacingConnection`, start times from `RacePolicy`), on iPhone, iPad and Mac alike. The client dials its direct candidates and the relay; with no usable candidate the race is the relay alone. Bonjour results join the race in flight as further direct legs, under the same one-handshake-at-a-time rule. The client remembers which candidate won the last race for each pairing room and network kind (`wifi`, `wired`, `cellular`, `other` or `none`, from the current `NWPath`), and forgets a room's entries when it unpairs or pairs anew. The direct candidates start 50 ms apart, last time's winner first (Happy Eyeballs). The relay starts with them, unless a direct candidate won last time on this network kind: then it waits 300 ms. A failed direct leg starts the next one at once, and once every direct leg has failed the relay starts at once; a failed relay never holds back a direct leg. One leg handshakes at a time, the first ready (probe verified, or relay `joined` with the host online): the plugin keeps a device's newest session, so two inits in flight could leave it holding the loser's. The first path whose session opens wins and the others are closed, so a client on the direct path keeps no relay socket. If the direct leg fails (refused, closed, or 15 s without a session), the next ready leg handshakes, normally the relay, which then goes on as without a race. Any network path change (`NWPathMonitor`) starts a new race, and so do `direct_hints` that arrive over a relay session and name a candidate the race did not dial; hints over a direct session are only stored. When the relay won and reports the host offline, the next session it opens (the host is back) starts a new race if the client holds any direct candidate, once per return; loopback alone does not trigger it when the hints show the host runs on another machine. That race, the one for new hints, and the one after a Local Network change (`raceAgain`, only while the relay holds the session) give the direct candidates the 300 ms head start even after a relay win, so a loopback relay does not take the tie back. The app's own reconnects (the scene leaving the background, its `inactive` step before `active`, so the race starts before the app is in front; the app becoming active; a sent share; a background wake) join a race that began under 10 s ago, won or not, so a launch dials once; they start a new one instead when the race is older, when a pause after a lost session or the relay's retry wait is running, or when the winner's session is no longer open. A lost session, direct or relay (its socket closed), starts a new race at once; only quick losses in a row, of sessions that lived under 10 s, pause first: from the second on, 1 s, 2 s, 4 s and so on up to 30 s, and a session that lives 10 s resets the count. Nothing migrates: each race is a new session, after which the app resends every message without ✓✓. The share extension stays on the relay.

**Each device on its own path** (`hub.ts`). Every session has its path and its send; a new session on either path replaces the device's old one. Relay fan-out leaves out devices connected directly, whose frames go over their own sockets; the silent `sync` notify skips them too. Presence (`foreground`, `active`) counts sessions on both paths, and the relay's `phones {count: 0}` clears it only for relay sessions. The plugin's `messageId` dedupe spans both paths, so a message resent after a race on the other path runs once.

**Push** (`push-proxy`). A direct client opens no relay socket, so it cannot send the relay its APNs token. The plugin lists `push-proxy` while its relay's `registered` said `pushProxy: true`; a client on a direct session then sends [`push_token`](#kinds) whenever it has a token, and the plugin forwards it as `push {device, token}`. Without `pushProxy` the plugin drops it. The Mac registers no token, so in this step nothing sends it yet.

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

Plugin (`acceptHandshake` in `wire.ts`, the decision in `hub.ts`), per init frame:

1. Verifies `sig` against the frame's own Ed25519 key and reads message 1. Any failure: dropped, no answer.
2. Drops it if `ts` is more than 5 minutes (`HANDSHAKE_MAX_AGE_MS`) from its clock either way, or if its `sid` was already answered within that window.
3. Serves a stored device whose Ed25519 key **and** handshake-authenticated X25519 key both match, or a device whose `proof` matches a pending secret (it is then stored, the oldest of 16 making way, and the secret spent). Otherwise it sends the relay `revoke` for that key and drops the frame (on the [direct path](#direct-path), only stored devices are served, and a refusal closes the socket).
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

- **Unknown is answered, not dropped (plugin)**: once a session has its `peer_info`, the plugin answers a known kind whose `data` fails validation with `error bad_request` (carrying the frame's `convId`, `messageId` or `attachmentId` when they are valid ids), an unknown kind or one a device may not send with `error unsupported`, and any frame before `peer_info` with `error bad_request`; each is logged, and the session stays. The client decodes an unknown or malformed kind as `.unknown` and ignores it. Unknown fields are ignored on both sides. Unknown enum values never fail an otherwise valid event: the plugin accepts any string `reaction.by` (it sets `by` itself), `tool.status` and `live_activity` job `kind` and `state` (it drops such jobs before they reach the relay), and `false` for `remove`, `removed` and `deleted`; the client reads an unknown `reaction.by` as absent and drops a history item of an unknown `kind` or a tool call of an unknown `status`, keeping the rest. A `tool` event of an unknown `status` is ignored, so the call keeps its last known status ([decisions](../OWNER_DECISIONS.md#versioning-rules)).
- **Capabilities**: optional features are announced in `peer_info.capabilities`; a change that cannot be expressed that way goes in phases: accept both, then send new, then drop old ([decisions](../OWNER_DECISIONS.md#versioning-rules)).
- **Ids**: `convId` and `messageId` are lowercase UUIDs, `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` (`WireEvent.isId`, `isId`); a known kind with a malformed id is unknown. A conversation's OpenClaw session key is `agent:<agent>:yorozu:direct:owner:thread:<convId>`.
- Times are epoch milliseconds (integers).

### Kinds

"That client" means the plugin seals the answer only for the device that asked.

| `kind` | Direction | `data` |
|---|---|---|
| `peer_info` | both, first box | `protocolMin`, `protocolMax` (both 3), `app`, `name`?, `capabilities` (strings), `mediaMaxBytes`?, `agent`?, `hostVersion`? |
| `message` | client → plugin | `convId`, `messageId` (client-made), `text` (may be empty with attachments), `attachments`?, `replyTo`? |
| `delivered` | plugin → clients | `convId`, `messageId` |
| `run_started` | plugin → clients | `convId`, `messageId` |
| `typing` | plugin → clients | `convId`, `active` |
| `reply` | plugin → clients | `convId`, `messageId` (plugin-made), `text`, `ts`, `attachments`?, `replyTo`? |
| `reaction` | both | `convId`, `messageId`, `emoji`, `remove`? (`true`), `by`? (`user` or `agent`; plugin → clients only) |
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
| `upload` | client → plugin | `attachmentId`, `name`, `mime`, `size`, `index`, `count`, `data` (base64), `sha256`? |
| `upload_ack` | plugin → that client | `attachmentId`, `index`, `done` |
| `upload_status` | client → plugin | `attachmentId`, `size`, `count`, `sha256` |
| `upload_state` | plugin → that client | `attachmentId`, `done`, `have` (`[[start, end], …]`) |
| `download` | client → plugin | `attachmentId`, `index` |
| `chunk` | plugin → that client | `attachmentId`, `index`, `count`, `data` (base64) |
| `live_activity` | client → plugin | `pushToken`? (hex), `jobs`, `turns` ([Live Activity push](#live-activity-push)) |
| `push_token` | client → plugin, only on a direct session to a plugin listing `push-proxy` | `token`: APNs token, hex ([Direct path](#direct-path)) |
| `direct_hints` | plugin → client, only to a client listing `direct`: after its `peer_info` and on every address change | `port`, `lan`: [{`address`, `prefix`}], `tailscale`: [{`address`}], `magicDNS`? ([Direct path](#direct-path)) |

A request and its answer share a kind; a `cron_list`, `device_list` or `pair_invite` with none of the answer fields is a request, and a client ignores one.

#### `peer_info`

Each side sends its own as its first box and acts on nothing else until it has the peer's. Each computes the highest version inside both ranges (`PeerInfo.negotiate` / `negotiate`). With none, the plugin sends `error {code: "update_required"}` and drops the session; the client stops with "update required".

| Field | Client | Plugin |
|---|---|---|
| `app` | the app version | the plugin version (`0.1.0`) |
| `name` | device model | the host's hostname |
| `capabilities` | `attachments`, `devices`, `replies`, `reactions`, `resume`, `direct` | `attachments`, `devices`, `invite`, `replies`, `reactions`, `resume`, `liveActivityPush` while its relay's `registered` said `liveActivity: true`, `direct` while its direct listener is listening, and `push-proxy` while its relay's `registered` said `pushProxy: true` |
| `mediaMaxBytes`, `agent`, `hostVersion` | — | attachment limit; `channels.yorozu.agent`; OpenClaw version |

`direct` and `push-proxy` were introduced by [#532](https://github.com/izyuumi/yorozu/issues/532) (`Direct.capability`, `DIRECT`; `PushProxy.capability`, `PUSH_PROXY`; [Direct path](#direct-path)). The client lists `direct`, which asks the plugin for [`direct_hints`](#direct-path), and not `push-proxy`; it trusts a direct listener for its probe, not for the plugin's capability. `protocolMin` and `protocolMax` stay 3; new behavior is gated on a capability, never on a version.

The client offers attachments, Settings devices, adding a device and replying only when the plugin lists `attachments`, `devices`, `invite` and `replies` (attachments and replies also before it has the plugin's `peer_info`), and sends `replyTo` only to a plugin listing `replies`. The plugin answers `device_list`, `device_patch` and `pair_invite` from any client and reads `foreground.active` whenever present; it gates three things on the client's capabilities: a reply's files, sent to a client without `attachments` as one text line each; `replyTo` on `reply` and history items, left out for a client without `replies`; and `reaction` events and history `reactions`, left out for a client without `reactions`. The client offers reacting only once the plugin's `peer_info` lists `reactions`, and asks ActivityKit for a Live Activity push token only from a plugin listing `liveActivityPush` (otherwise its activity has none, as before). The plugin stores the client's `name` (cut to 64) for `openclaw yorozu devices`.

Right after the client's `peer_info`, the plugin sends that device every stored [`read_cursor`](#read_cursor).

#### Replies: `replyTo`

Capability `replies`. A `message`, `reply`, or `user` or `agent` history item may name the message it answers: `replyTo: {messageId, text?}`. `messageId` is a lowercase UUID (an id that is not makes the event unknown on the client and `bad_request` on the plugin); `text` is the target's text as the sender knew it, for a header when the target is not loaded.

- **Client → agent**: the client sends the target's text (cut to 2,000 characters, `ReplyTo.maxText`). The plugin hands the turn the target as OpenClaw's reply context (`ReplyToId`, `ReplyToBody`); the `message`'s `messageId` is the turn's `MessageSid`.
- **Agent → client**: the agent replies to a message with `[[reply_to_current]]` or `[[reply_to:<messageId>]]`, or the message tool's `replyTo`; the channel's reply mode is `off`, so nothing else quotes. The plugin puts `replyTo` on the first chunk of that reply, with the target's text from the turn's `message` or the transcript.
- The plugin keeps each `replyTo` it saw or sent, `text` cut to 280 characters, by the replying message's id (keyed state namespace `replies`, at most 10,000, oldest dropped), and adds it to that message's history item.
- The client shows a header with the first line of the target (the loaded message's text, else `text`); tapping it scrolls to the target when it is loaded.

#### Reactions: `reaction`

Capability `reactions`. One emoji per person (the user, the agent) per message, on user and agent messages. `emoji` is 1 to 32 UTF-16 units (more makes the event unknown on the client and `bad_request` on the plugin). Adding replaces that person's reaction; `remove: true` clears it when it is `emoji`, and is ignored otherwise.

- **Client → plugin**: the user picked or took back an emoji (picking the one the message already has sends `remove`). `by` from a client is ignored. The plugin queues an OpenClaw system event in the conversation's session, `Yorozu reaction added: 👍 on msg <messageId>` (or `removed`), one pending per message (the newest replaces it); the agent sees it at the start of its next turn, and a reaction never starts one.
- **Agent → client**: the agent calls the `message` tool with `action: "react"`, `messageId` (default: the current turn's message), `emoji`, `remove`?; an empty `emoji` or `remove` clears the agent's reaction. The channel declares `reactions` with `reactionSlots: "single"`.
- The plugin sends every change, with `by`, to every device, the sender included, and keeps each message's reactions by its id (keyed state namespace `reactions`, at most 10,000, oldest dropped). A `user` or `agent` history item carries them as `reactions: {user?, agent?}`; a page replaces the client's copy.
- The client shows them as chips under the bubble; tapping your own takes it back.

#### `tool`

One tool call of an agent run, for a collapsed row under the message it answers. `callId` is OpenClaw's tool call id (not a UUID, at most 128 characters); updates of one call share it and the last `status` wins: `running`, then `done` or `failed`. `name` is the tool's name (at most 128). The client ignores a `tool` of any other `status`, and drops such a call from a history item.

#### History: `conv_list` and `history`

The Gateway transcript is the source of truth; the client caches what it fetched. The client keeps one request in flight and sends the next on the answer, an `error`, or after 30 s.

- `conv_list` lists the agent's Yorozu thread sessions, newest `updatedAt` first, at most 2000, archived ones included. `updatedAt` is the newest user or agent message's own time in the transcript, so renames and pins do not reorder. `rev` is the transcript's newest event seq. `title`, `archived`, `pinnedAt` are as in [`conv_update`](#titles-conv_patch-and-conv_update). A client drops a cached conversation the list omits if it synced it before (has a `rev`) or holds no message of it and has no undelivered message in it, unless the list holds 2000 rows.
- `history` returns one page, oldest first. `before: n`: the newest items with seq below `n`. `after: n`: the oldest items with seq above `n`. Neither: the newest page. `more`: another page lies further that way. At most 60 items and about 192 KiB; items of one transcript event are never split. An unknown conversation answers `items: []`, `more: false`, `rev: 0`.
- The client syncs on every new session: `conv_list`, then `after: <newest cached seq>` for each conversation whose `rev` changed; opening a conversation does the same for it; scrolling up asks `before: <oldest cached seq>` until `more` is false. A `run_started` for a message the client does not hold (another device's) also triggers an `after` fetch.

Items carry `kind`, `id`, `seq` (the transcript event's; shared by items of one event), `ts` (Gateway clock), then:

| `kind` | Fields | From |
|---|---|---|
| `user` | `text`, `attachments`?, `replyTo`?, `reactions`? | a user message from the owner (OpenClaw-internal user-role turns are skipped); `id` is the client's `messageId`; `<file …>` blocks OpenClaw appends for documents are removed |
| `agent` | `text`, `attachments`?, `replyTo`?, `reactions`? | assistant text without `MEDIA:` lines, trimmed and chunked by `textChunkLimit` like live replies, files on the last chunk (or an item with empty `text`); cron deliveries mirrored into the transcript come out here too |
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
| `scheduleText` | The plugin's English wording (`Every 30 minutes`, `Daily at 09:00 (Asia/Tokyo)`, `Weekdays at 08:30`, `Once`, else `Cron <expr>`); the app words `schedule` in its own language and falls back to `scheduleText` for what it does not recognise |
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

Files both ways, each at most the plugin's `mediaMaxBytes` (`channels.yorozu.mediaMaxMb`, else `agents.defaults.mediaMaxMb`, else 128 MB; the client assumes 128 MB until told), in chunks of 160 KiB of raw bytes (`CHUNK_BYTES`, `Attachment.chunkBytes`). An attachment is `{id, name, mime, size}`; `id` is a lowercase UUID made by the side that has the bytes. `count` is `max(1, ceil(size / 160 KiB))`; every chunk but the last is full.

- **Client → agent**: the client refuses an oversized file before copying it. It holds a message with files until a session is up, uploads each file as `upload` chunks, four in flight, each answered `upload_ack` to that device only (30 s timeout per ack), then sends the `message` naming the files whose last ack said `done`. The plugin answers `error {code: "too_large", attachmentId}` for a file over its limit and `bad_request` for a chunk that does not fit its upload; the client then leaves that file out. A finished upload is saved into OpenClaw's media store (`media/inbound`) and indexed in keyed state namespace `attachments`, so re-uploading a stored id is answered `done` at once. The turn gets the files as media facts (`toInboundMediaFactsWithMetadata`).
- **Spool**: the plugin writes each chunk at its offset into `<state dir>/yorozu/upload-spool/<attachmentId>.part` (directory 0700, files 0600), fsyncs it, then atomically replaces `<attachmentId>.json`, which names the chunks held; a restart of the plugin or the Gateway keeps them. Chunks may come in any order and a repeated chunk changes nothing. At most 8 uploads are spooled (the least recently touched is dropped); one idle for 24 hours is dropped at startup or by the next upload, at most once a minute. When every chunk is in, the plugin hashes the file, checks `sha256` if the upload carried one, stores it and drops the spool.
- **Resume**: capability `resume`. To a plugin listing it, the client sends the file's SHA-256 (64 lowercase hex) on every `upload` and starts each upload with `upload_status`; `count` must be the upload's chunk count. `upload_state` answers it: `done: true` (and `have: []`) when that id is stored, else `have`, the chunk indices held, as sorted, merged, half-open ranges. A spool whose `size`, `count` or `sha256` differ from the query is dropped and answered `have: []`. The client sends exactly the chunks outside `have`, and the last chunk again when `have` covers them all. It keeps a ledger per upload (`<attachment folder>/.upload.json`: size, SHA-256, acked ranges; saved every 16 acks or second and on interruption, removed once stored), so a resume survives a relaunch; the plugin's `have` wins over it. `error {code: "hash_mismatch", attachmentId}` means the assembled file's SHA-256 differed and the spool is gone: the client clears its ledger and sends the file again from chunk 0, once per attempt; a second mismatch leaves the file out. To a plugin without `resume` the client sends neither `sha256` nor `upload_status` and starts each upload from chunk 0; a client without it gets the same spool, without the hash check. The share extension resumes the same way within its own run.
- **Agent → client**: a reply's media (`MEDIA:` lines, the message tool, a delivery's `sendMedia`) is staged into `media/outbound` (`resolveOutboundAttachmentFromUrl`, the agent's media roots and limit) and announced in the `reply`'s `attachments`, on the last text chunk or a reply of its own. Nothing more is sent until a device asks: `download` per chunk, answered with `chunk` for that device only. The client fetches an image when shown and a file when tapped, one file at a time, two chunks in flight. It writes each chunk at its offset into `<attachment folder>/.download.part` with a ledger beside it (`.download.json`: size, count, chunks held), so a new session or a relaunch asks only for the missing chunks; it checks the final size, then moves the file to its name. This needs no capability. An unknown or vanished id is answered `error {code: "not_found", attachmentId}`. A file that cannot be staged becomes a `(Couldn't attach <name>: …)` line in the reply.

#### `error` codes

| `code` | Meaning |
|---|---|
| `update_required` | No common protocol version |
| `bad_request` | The receiver knows the kind but cannot act on it: data that fails validation, pinning an archived conversation, an upload chunk that does not fit. For a `message` it arrives instead of `delivered`, and the client marks the message not delivered with the reason and stops resending it |
| `unsupported` | A kind the plugin does not handle from a device |
| `attachment_missing` | A `message` named attachments the plugin does not hold; the turn runs without them, with `convId` and `messageId` |
| `run_failed` | The agent run for `messageId` failed; `message` says why |
| `too_large` | An `upload` or `upload_status` over `mediaMaxBytes` |
| `hash_mismatch` | The assembled upload's SHA-256 differs from its `sha256`; the plugin dropped the chunks, with `attachmentId` |
| `not_found` | A `download` of an attachment the plugin does not hold |
| `internal` | Anything else: a `conv_list` or `history` the plugin could not read, a `conv_patch` it could not apply, an upload it could not store |

A receiver treats an unknown code like `internal`.

## Delivery

All paired devices are one channel peer (`owner`), so the plugin sends `delivered`, `run_started`, `typing`, `tool`, `reply`, `conv_update` and merged `read_cursor`s to every device with a session, each sealed under that device's session.

- ✓ sent: the relay's `accepted` for the frame carrying the `message`, or on the [direct path](#direct-path) the plugin's. ✓✓ delivered: `delivered`, sent as soon as the box opens. Read: `run_started`.
- The client sends `message`s only in an established session and resends any without `delivered` in its next session. The plugin answers a repeated `messageId` (remembered 24 h, up to 10,000) with `delivered` again and does not run it twice.
- Typing: `typing {active: true}` from run start, repeated at least every 10 s (every 8 s in practice), `typing {active: false}` when it ends. The client hides it after 30 s without a repeat.
- Replies arrive whole, one `reply` per chunk of `channels.yorozu.textChunkLimit` (default 4000) characters, never edited. A cron job delivering into a conversation (`delivery: {channel: "yorozu", to: "owner", threadId: <convId>}`) arrives as `reply` too, with no `run_started` or `typing`. Nothing is queued for a device without a session: it catches up through `history`.
- A run that fails for a temporary reason (plugin reload, overloaded or rate-limited model) before any reply or tool call is retried by the plugin (after 5, 15, 30, 60 and 120 s, parked in keyed state namespace `retry`); otherwise the devices get `error run_failed`.
- Slash commands are plain text: `/new` and `/reset` reset that conversation's session; others go to OpenClaw as typed.

## Push

One push per finished agent reply, and per cron delivery with text, through the relay's `notify`, with a preview sealed per device.

- **Token**: an iPhone or iPad sends `{"type":"push","deviceToken":<lowercase hex>}` after every `joined` and whenever iOS hands it a new token; it asks iOS for one on every launch. The relay keeps one token per device (a token claimed by another device key moves to it) and forgets it when the device is revoked. The Mac registers no token.
- **Foreground**: the client sends `foreground {convId, active: true}` while a conversation is on screen with the app active, `foreground {active: …}` without `convId` otherwise, whenever either changes, including just before going to the background, and again on every new session while active (a new session starts with none). The plugin skips a device whose live session last reported that conversation or `active: true`, and a device whose push is off. When the relay reports `phones {count: 0}`, the plugin forgets the foreground of every relay session; a direct session keeps its own.
- **When**: after a turn that sent at least one `reply` (one push, named after its first chunk), or after a delivered payload with text (the outbound adapter's `afterDeliverPayload`). A failed turn does not push. With no device left to alert, no `notify` is sent.
- **`notify`** (host → relay): `{"type":"notify","class":"reply","threadRef":<threadRef(convId)>,"eventRef":<threadRef(messageId)>,"previews"?:{<device Ed25519 key>:{n,c}},"devices":[<device Ed25519 key>,…]}`. `threadRef` is `YorozuCrypto.threadRef` / `threadRef`: the first 8 base64url characters of SHA-256. The relay alerts only the named devices (every registered device when `devices` is absent). It validates: `previews` and `devices` at most 16 entries of 43-character keys, `n` 16 characters, `c` 22 to 363 characters.
- **Relay → APNs** (Worker only): an alert `{"aps":{"alert":{"title":"Yorozu","loc-key":"Yorozu replied."},"sound":"default","thread-id":<threadRef>,"mutable-content":1},"ref":<threadRef>,"cls":"reply","event":<eventRef>,"preview":{n,c}}` (`mutable-content` and `preview` only with a preview). After an alert, a device with no live socket also gets a background push (`content-available`), at most one a minute. The relay also accepts classes `approval`, `done` and `failed`, which this plugin never sends.
- **Read elsewhere**: the plugin remembers, per conversation, the devices it alerted since the last read (in memory). On a merged cursor with `unread: false` it sends `{"type":"notify","class":"sync","threadRef":…,"devices":[…]}` for those devices except the reader. The relay sends each one without a live socket a background push only, not held to the one-a-minute limit. A woken iPhone or iPad connects briefly; the `read_cursor`s on its new session clear what was read.
- **Preview** (`PushPreview`; `push.ts`): key = HKDF-SHA256 over X25519(host static, device static), salt `yorozu-v1`, info `yorozu-push-preview/mac->device`, 32 bytes. Box: ChaCha20-Poly1305 with a fresh 12-byte nonce; `n` and `c` (ciphertext ‖ tag) base64url. Plaintext: JSON with sorted keys `{"b":<first non-empty line of the reply>,"c":"reply","e":<eventRef>,"t":<title>?,"v":<convId>}`, at most 256 bytes: the title is cut to 32 characters, then the body with "…" until it fits. The title is the conversation's [title](#titles-conv_patch-and-conv_update), else its first message's first line (keyed state namespace `push-titles`, slash commands skipped).
- **iPhone, iPad**: the app writes the preview key, on every connect, to a Keychain group shared with the notification service extension, and deletes it on unpair. The extension opens `preview`, requires its `e` to equal the push's `event`, and sets the title to `t` (else "Yorozu replied."), the body to `b` and `userInfo.convId` to `v`; anything that does not open is shown as sent. While the app is active, a notification is not shown as a banner but as the in-app notice. For a `reply` with `v`, it also counts the reply in the widget snapshot (once per `event`, only while the app is not in front, and keeping `b`'s first line only when widget previews are on) and marks that conversation's turn done in the Live Activity; `failed` marks it failed and `approval` adds a needs-you row, all silently (the notification alerts). The activity's state carries only random job tokens, kinds, states, step counts and times (`YorozuActivityState`), and the device keeps what each token is about; with a plugin listing `liveActivityPush` it is also kept current by [counts-only pushes](#live-activity-push). A tap opens the conversation by `convId`, else by `ref` matched against cached conversations. Opening a conversation removes its delivered notifications, and so does any `read_cursor` with `unread: false` (those delivered no later than 15 s after the cursor's `ts`).
- **Mac**: no relay push. While the app is active, a reply in a conversation not on screen shows the in-app notice; while it is not, each reply posts a local notification, one per conversation, replaced by the next, with sound at most once per 10 s per conversation.
- Neither end logs preview plaintext.

### Live Activity push

Capability `liveActivityPush` (iPhone, iPad). Counts-only ActivityKit pushes keep the app's one Live Activity current while the app is suspended. No push-to-start: the app still starts the activity itself.

- **Report** (`live_activity`, client → plugin, `ActivityReport` / `liveactivity.ts`): the app asks for the activity with `pushType: .token` and sends `{pushToken, jobs, turns}` when ActivityKit hands it the token, after every change of its jobs, and again on each new session. `jobs` is the activity's whole content state, times in epoch milliseconds: `token` (16 of `A–Z a–z 0–9 - _`), `kind` (`turn`, `recording`, `transcribing`, `needsYou`), `state` (`running`, `done`, `failed`), `steps`?, `startedAt`, `finishedAt`?; at most 8. `turns` maps the token of each running turn job to its `convId`. When the activity ends on the device the app sends `{jobs: [], turns: {}}` without `pushToken`. Before it suspends, the app waits up to 5 s for the token to reach the plugin.
- **Plugin** (`relay.ts`): it keeps each device's last report in memory and forwards the token to the relay. On a tool call in a conversation it raises that turn job's `steps` to the run's distinct call count; when the turn ends it marks the job `done` (a reply), `failed` (`run_failed`) or removes it (neither); a run parked for retry stays running. Every other job (recording, transcribing, needs you) goes out exactly as the app reported it, so a push never wipes a job only the device knows; the app reports each change of those as it happens. Then, as the app does: finished rows older than 2 minutes go, rows are sorted and capped at 8. It pushes the whole state at priority 10 when a row finished, left or needs you, and otherwise (step counts) at priority 5, at most once per 15 s per device, the last count sent when the 15 s are up. With nothing running it sends `end` instead, with `dismissal-date` when the last finished row has lingered 2 minutes (now, with no rows), and forgets the device. Without `liveActivity: true` from its relay it neither lists the capability nor sends any of this.
- **Host → relay**: `{"type":"activityToken","device":<device Ed25519 key>,"token":<hex>}` registers the token for a device the room knows; without `token` it forgets it. `{"type":"activityPush","device":…,"event":"update"|"end","priority":5|10,"state":{"jobs":[…]},"staleDate"?:<epoch s>,"dismissalDate"?:<epoch s>}`: `state` is `YorozuActivityState` as the app's `JSONDecoder` reads it (dates in seconds since 2001-01-01, the `Codable` default; `apps/ios/Tests/Fixtures/activity-content-state.json` is checked by the plugin's, the relay's and the app's tests). The relay rebuilds `state` from the job fields above only (anything else is dropped, as is a job of an unknown `kind` or `state`; a bad field closes the socket) and counts it against its own per-room budget, apart from `notify`.
- **Relay → APNs** (Worker only): `apns-push-type: liveactivity`, `apns-topic: <APNS_TOPIC>.push-type.liveactivity` (`to.yumi.yorozu.ios.push-type.liveactivity`), the requested `apns-priority`, the same token-based key as alerts, and `{"aps":{"timestamp":<relay time, s>,"event":…,"content-state":…,"stale-date"?:…,"dismissal-date"?:…}}`, never an `alert`. Pushes go out in the order the host sent them. A token APNs calls gone (410, or 400 `BadDeviceToken` in both environments, `ExpiredToken`, `Unregistered`) is deleted and the host gets `activityGone {device}`; an accepted `end` deletes it too, as does revoking the device. The token starts in the APNs environment of the device's own token and moves like it.
- **Old peers**: an old plugin never lists the capability, so the app keeps `pushType: nil`; an old app never reports, so the plugin never pushes; an old relay never says `liveActivity`, so the plugin sends it none of the new messages (a relay from before the tolerant readers closes the socket on an unknown type; a current one ignores it).
- **What the relay and APNs learn**: per device, an activity push token while the activity runs; when each push goes and its priority; and the plaintext state, which is random job tokens, kinds, states, step counts and times, nothing more. No conversation id, title, text or tool name: which conversation a token stands for travels only inside the encrypted session, and its title stays in the device's App Group (`ActivityLabels`), drawn only while previews are on. The relay stores only the token.
- **Apple setup**: the token-based `.p8` key already used for alerts signs Live Activity pushes, and the app needs no capability beyond Push Notifications and `NSSupportsLiveActivities`, both present.

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
| Direct path | `RacingConnection` (`raceAgain`), `RelayConnection` (direct legs), `RelayConnection.Update.route`, `DirectRoute`, `Direct.verifyProbe` | `serveDirect`, `directAddress`, `probeAnswer`, `verifyProbe` (`direct.ts`); `Hub` (`hub.ts`) |
| Direct candidates | `DirectHints`, `DirectHintStore`, `DirectCandidates.plan`, `LocalInterface`, `LocalNetwork` (`allowed`, `denied`, `explained`, `usable`, `refresh`), `Bonjour.browse`, `Direct.bonjourTag` | `directHints`, `watchDirect`, `resolveMagicDNS`, `tailscaleAddress` (`hints.ts`); `serveBonjour`, `bonjourTag` (`bonjour.ts`); `DirectListener.update` (`direct.ts`) |
| Frames | `Frame(payload:)`, `.payload`, `.sid` | `decodeFrame`, `encodeFrame`, `frameSid` |
| Boxes | `Session.seal`, `.open`, `.openEvent` | `Session.seal`, `.open` |
| Envelope | `WireEvent`, `PeerInfo.negotiate`, `WireEvent.newId`, `isId` | `Event`, `parseEvent`, `encodeEvent`, `negotiate`, `isId` |
| Capabilities | `Attachment.capability`, `Devices.capability`, `Invite.capability`, `ReplyTo.capability`, `Reaction.capability`, `ActivityReport.capability`, `Direct.capability`, `PushProxy.capability` | `ATTACHMENTS`, `DEVICES`, `INVITE`, `REPLIES`, `REACTIONS`, `LIVE_ACTIVITY_PUSH`, `DIRECT`, `PUSH_PROXY` |
| Live Activity push | `ActivityReport` (the app's `ActivityReports.swift`, `YorozuActivities`) | `applyTurn`, `plan`, `contentState`, `holdFor` (`liveactivity.ts`) |
| Attachments | `Attachment` (`chunkBytes`, `chunkCount`), `Upload`, `UploadAck`, `Download`, `Chunk` | `CHUNK_BYTES`, `attachments.ts` |
| Push preview | `PushPreview.key`, `.open(userInfo:key:)`, `RelayConnection.registerPush` | `previewKey`, `previewPlaintext`, `sealPreview`, `threadRef` (`push.ts`) |
| Mac pairing code | `DeviceCode` | — |

## Validation differences

Each side validates what it receives; the two are not identical.

- The plugin refuses (`error bad_request`) a `message` with more than 32 attachments, an attachment or `upload` whose `name` or `mime` is empty or over 255 characters, and a `device_patch` whose `id` is over 64 characters. The client keeps within these before sending: the composer will not send more than 32 files, and names and types are trimmed to 1–255 characters (`Attachment.wireName`, `wireMime`).
- The client drops malformed rows of `conv_list` and `history` individually; the plugin does not validate those answers (it only sends them).
