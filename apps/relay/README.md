# Relay

Routes Ed25519-signed frames between a host (the OpenClaw plugin) and its paired devices, buffers device frames while the host is away, and wakes iPhones and iPads through APNs. It reads only its outer envelope; payloads are forwarded unread. The wire it speaks is in [docs/ios-relay-contract.md](../../docs/ios-relay-contract.md#relay). The deployed relay also serves older app versions, so a change must stay backward compatible ([OWNER_DECISIONS.md](../../OWNER_DECISIONS.md)).

Two implementations of one protocol, sharing limits, envelope parsing and close codes in `src/protocol.ts`:

| | Worker (`src/worker.ts`, deployed) | Node (`src/index.ts`, `Dockerfile`) |
|---|---|---|
| Rooms | One Durable Object `Room` per room, routed on `?room=` | In memory, room taken from the key; `?room=` ignored |
| State | Durable Object storage: known devices, tokens, buffer, push tokens | Memory only: lost on restart |
| Flow control | `flowBytes` on each frame, devices answer `flowAck` | The socket's send buffer |
| APNs | Sends alerts and background pushes (`src/apns.ts`) when its secrets are set | None: `notify` is checked and dropped |
| Mailboxes (Mac pairing) | `Mailbox` Durable Object, `/mailbox/<id>` (`src/mailbox.ts`) | None |
| Connection limit | `CONNECT_LIMIT` rate limit: 30 new sockets a minute per address | `RELAY_MAX_CONNS_PER_IP` open sockets per address (default 32); `RELAY_TRUST_PROXY` sets trusted proxy hops |

Both read `RELAY_MAX_TOKENS_PER_ROOM` (default 8) and `RELAY_NOTIFY_PER_MINUTE` (default 60). The Worker also reads `RELAY_ACTIVITY_PER_MINUTE` (default 60), the separate budget for Live Activity pushes. The Worker's APNs secrets are listed in [docs/setup.md](../../docs/setup.md).

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
