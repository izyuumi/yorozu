# 0006. Direct path and the connection race

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

Besides the relay, the plugin runs its own WebSocket listener on private addresses (#532, capability `direct`). The client races the relay against the direct candidates, Happy Eyeballs style, and must never trust a listener it has not authenticated.

## Decision

- Listener (plugin):
  - One `ws` server per address on `port`, on loopback, RFC 1918, ULA and 100.64.0.0/10 only: never a wildcard, link-local, mapped or public address.
  - At most 8 sockets wait for their handshake, each for 10 s. A direct socket silent for `IDLE_MS` is gone; the client pings every 25 s.
  - `accept` checks the `Origin` header: a browser page could reach loopback, and the app sends no Origin.
  - `ws` closes a message over `maxPayload` with 1009 before the plugin sees it; up to that, oversized messages get 4103.
  - Only addresses the listener actually bound are advertised as hints (`directHints`). Hint polling is serial, keeping rebinding and DNS results in interface order; stop waits for an in-flight refresh.
  - `transmit` routes each message through OpenClaw's effect authority.
  - Accepted socket events lose the plugin instance's async scope, which OpenClaw's runtime store needs, so `accept` captures it with `AsyncLocalStorage.snapshot()`.
  - The module imports only node built-ins and the pure wire and hub files, and the WebSocket server is injected, so `node --test` and the relay's end-to-end test run it without OpenClaw.
- Probe and authentication:
  - Before its Noise init, a device sends `{"type":"probe","nonce"}`. The host answers with its Ed25519 key and a signature over the room and nonce.
  - The answer holds only if the key is the room's (the room id is its hash) and it signed this nonce.
  - A direct listener is nobody until its probe answer proves the room's key, and never a relay: it gets no join signature over a nonce of its choosing.
  - After the probe, the same signed frames as on the relay.
- Candidates:
  - Loopback on the Mac at the default port, always, since stored hints can be stale.
  - LAN addresses on a subnet of an up, non-VPN interface, once Local Network is allowed ([0007](0007-local-network-explainer.md)).
  - Tailscale IPs, then the MagicDNS name, while an up VPN interface holds a Tailscale address. Loopback and Tailscale do not need Local Network permission.
  - Loopback may reach the host when there are no address hints or a hint matches a local interface.
  - `skipped` names each left-out hint and why, for the log.
  - Darwin may hand a netmask sockaddr shorter than its type, so only `sa_len` bytes are read.
  - Bonjour (`_yorozu._tcp`): the instance name and TXT `t` rotate hourly to limit discovery tracking. A wall-clock jump past the timer rotates at once. The resolver connects over TCP to learn the address a service answers on, then closes; it is touched only on its queue. The Info.plist declares the service; it is browsed only once the owner allowed Local Network.
  - Bonjour responder: one receive socket per process; replies use per-interface sockets, since macOS cannot send from the group bind. Known-answer and additional records are validated too, so malformed datagrams never elicit traffic.
  - `LocalNetwork.refresh` waits past ready: a policy denial can arrive after the browser starts.
- Race policy:
  - The first path whose Noise session opens wins and the others are closed.
  - Last time's winner on this network kind starts first, the other direct candidates 50 ms apart, the relay 300 ms late behind a direct winner, and at once when every direct leg has failed. A failed direct leg starts the next pending one at once. A failed relay never holds back a direct leg.
  - One leg handshakes at a time: the plugin keeps a device's newest session, so two inits in flight could leave it holding the loser's.
  - A granted direct handshake gets 3 s while the relay remains; otherwise the normal 15 s limit applies. Nothing buffers on the direct path, so a handshake with no answer fails the leg. A format fallback continues the same granted attempt.
  - Failed granted candidates, Bonjour and relay hints included, are skipped per room and network kind for 10 minutes. Direct success clears its failure; path changes and removing a pairing clear the room. Permission retries ignore failures for that race only. While pairing, failures are neither recorded nor skipped.
  - `preferDirect`: when the race is for a direct path that may have come back (the host returned, permission changed), the relay waits out its head start even after a relay win; otherwise a loopback relay could take the tie again.
  - The winner store keys a direct candidate by its URL, never the relay URL, whose query holds the room id.
- Races and reconnects:
  - A network path change or a lost session starts a new race. Nothing migrates; the app resends its unacknowledged outbox on the new session. Only changes after the first reported path count.
  - Each race reads the stored `direct_hints`; Bonjour results join as they come. On the relay, hints naming a candidate this race did not dial start a new race at once; a direct winner just keeps them.
  - The app's reconnect (scene active, a sent share, a background wake) joins a healthy race under 10 s old, won or not, since it began for the same reason (at launch the race can be won before the scene's reconnect comes). A stale race, a pause after a lost session, a relay waiting out its retry, or a winner whose session is no longer open gives way to a new race. A race being set up counts as in flight. `endRace` returns the new round taken before any wait, so a race that began during the wait has a newer one.
  - Permission changes can make direct candidates usable while a relay session is healthy, or while pairing (the Local Network explainer's Continue), when it always races again.
  - A direct winner is lost on any state but ready; a relay winner only when its socket closes, since it rides out a host going offline on the same socket. The next race may find the other path. `.ready` comes just before `.sessionOpen`, and the holder keeps its turn through both.
  - A direct leg does not redial; its race decides what comes next.
  - `RelayConnection.reconnect` joins a dial under 10 s old that is still connecting or has opened (at launch, `start` and the scene becoming active come together); otherwise, and while waiting out a retry or offline, it dials at once.
  - URLSession reports no open without a delegate, so the first message proves the socket open.
  - `NetworkKind` comes from one path monitor shared by the app. The first path arrives asynchronously, so a race started at launch waits for it rather than racing as "none".
- App wiring:
  - `AppModel` keeps observable copies of `LocalNetwork.allowed`, `.explained` and `.denied`, which live in user defaults where the racer reads them.
  - The race starts on the way back to the foreground, before the scene is active (#532 item 8); `resume` then joins it.

## Consequences

- On the LAN or loopback, the app connects without the relay, and the relay stays as fallback.
- An unauthenticated listener can never get a signature it could replay at the relay.

## Where in the code

- `plugins/openclaw-yorozu/src/direct.ts` — `IDLE_MS`, `directAddress`, `probeAnswer`, `DirectOptions.transmit`, `serveDirect`, `accept`, `listen`
- `plugins/openclaw-yorozu/src/hints.ts` — `directHints`, `watchDirect`
- `plugins/openclaw-yorozu/src/bonjour.ts` — query parsing, `receiveSocket`, tag rotation timer
- `packages/YorozuWire/Sources/YorozuWire/Direct.swift` — `Direct`, `Direct.verifyProbe`, `RacingConnection` and its `joinWindow`, `changes`, `reconnect`, `raceAgain`, `endRace`, `race`, `hurry`, `networkChanges`
- `packages/YorozuWire/Sources/YorozuWire/RacePolicy.swift` — `NetworkKind`
- `packages/YorozuWire/Sources/YorozuWire/RelayConnection.swift` — `RelayConnection.reconnect`, `message`, `closed`, `deadline`, `handle`, `key`
- `packages/YorozuWire/Sources/YorozuWire/DirectCandidates.swift` — `Direct.bonjourTag`, `LocalInterface.maskBytes`, `LocalNetwork`, `LocalNetwork.refresh`, `DirectCandidates.plan`, `DirectCandidates.hostMayBeLocal`, `Bonjour.Resolver`
- `apps/ios/Sources/Client/AppModel.swift` — `localNetworkAllowed`, `race(pairing:local:)`, `prewarm()`
- `apps/ios/Sources/YorozuIOS/Root.swift` — scene phase handler
- `apps/ios/Project.swift` — `NSBonjourServices`
