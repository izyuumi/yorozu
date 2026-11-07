# Relay

Routes Ed25519-signed frames between a host (the OpenClaw plugin) and its paired devices, buffers device frames while the host is away, and wakes iPhones and iPads through APNs. It reads only its outer envelope; payloads are forwarded unread. The wire it speaks is in [docs/ios-relay-contract.md](../../docs/ios-relay-contract.md#relay). The deployed relay also serves older app versions, so a change must stay backward compatible ([OWNER_DECISIONS.md](../../OWNER_DECISIONS.md)).

Two implementations of one protocol, sharing limits, envelope parsing and close codes in `src/protocol.ts`:

| | Worker (`src/worker.ts`, deployed) | Node (`src/index.ts`, `Dockerfile`) |
|---|---|---|
| Rooms | One Durable Object `Room` per room, routed on `?room=` | In memory, room taken from the key; `?room=` ignored |
| State | Durable Object storage: known devices, tokens, buffer, push tokens | Memory only: lost on restart |
| Retention | One alarm per room: a room with no connection for 30 days is deleted outright, and its host rebuilds it on its next `register` and `devices` announce; no device is dropped for idling ([contract](../../docs/ios-relay-contract.md#relay)) | None |
| Nonce join of an unknown device | `4011 host offline` while no announce is stored since creation or wipe (even if the host registered then disconnected), or a connected host hasn't announced on its current socket, else `4001 unknown device`. Older rooms retry until the host's next announce. | `4011 host offline` until the host announces after a relay start or a new registration, else `4001 unknown device` |
| Flow control | `flowBytes` on each frame, devices answer `flowAck` | The socket's send buffer |
| APNs | Sends alerts and background pushes (`src/apns.ts`) when its secrets are set | None: `notify` is checked and dropped |
| Mailboxes (Mac pairing) | `Mailbox` Durable Object, `/mailbox/<id>` (`src/mailbox.ts`) | None |
| Connection limit | `CONNECT_LIMIT` rate limit: 30 new sockets a minute per address | `RELAY_MAX_CONNS_PER_IP` open sockets per address (default 32); `RELAY_TRUST_PROXY` sets trusted proxy hops |

Both read `RELAY_MAX_TOKENS_PER_ROOM` (default 8) and `RELAY_NOTIFY_PER_MINUTE` (default 60). The Worker also reads `RELAY_ACTIVITY_PER_MINUTE` (default 60), the separate budget for Live Activity pushes. The Worker's APNs secrets are listed in [docs/setup.md](../../docs/setup.md).

The host owns the device roster. Its latest `devices` announce vouches for the listed rows and removes omitted rows, except a phone connected at that moment, which stays as a pending row; `revoke` also removes a row and closes its sockets with `4001 revoked`. Token joins add pending rows, capped at 16 independently of vouched rows. At that bound a fresh device gets `4011 host offline` without spending its token or evicting another device. Existing rows can still nonce-rejoin. Capacity never changes roster authority.

The Worker keeps `p:` values as numeric timestamps for older readers and persists the vouched keys separately in `vouched`; other rows are pending. On migration, legacy rows count as vouched when roster authority is `host`, otherwise pending. This classification is saved before a new host registration resets authority to `unconfirmed`.

## Develop

The package is in the repository's pnpm workspace.

```sh
pnpm install --frozen-lockfile --filter @yorozu/relay
pnpm --filter @yorozu/relay test        # Worker typecheck, then vitest: Node and Worker projects
cd apps/relay
npx tsc -p . --noEmit                   # Node relay typecheck
npx tsc -p tsconfig.worker.json         # Worker typecheck
```

`src/conformance.test.ts` is one scenario list run against both relays (from `index.test.ts` and `worker.test.ts`); the Worker tests run in `@cloudflare/vitest-pool-workers` with `wrangler.toml`. `vitest.config.ts` refuses a `compatibility_date` newer than the test pool's workerd.

## Deploy

The Worker deploys from `main` through `.github/workflows/deploy-relay.yml`: on every push touching `apps/relay/**` (or by hand), after the tests, with `wrangler deploy`. Bindings and routes are in `wrangler.toml`.

The Node relay builds as a container from the repository root and listens on `PORT` (default 8787):

```sh
docker build -f apps/relay/Dockerfile .
```
