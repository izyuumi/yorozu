# Relay

The Yorozu relay: a Cloudflare Worker with one Durable Object `Room` per host (`src/worker.ts`),
and a Node variant of the same protocol (`src/index.ts`, `Dockerfile`). The Worker also keeps one-time
mailboxes (`Mailbox`, `src/mailbox.ts`) for pairing a Mac from a paired iPhone or iPad; the Node relay has none. It routes Ed25519-signed
envelopes and forwards their sealed payloads unread; `src/protocol.ts` holds the shared limits and
envelope shapes. The phone-side contract is [docs/ios-relay-contract.md](../../docs/ios-relay-contract.md).

## Deploys and typecheck

The deployed relay also serves older Yorozu versions still in the field, so a change stays backward compatible. Deploys go from `main` on merge, after the tests (`.github/workflows/deploy-relay.yml`). It installs through the repository's pnpm workspace:

```sh
pnpm install --frozen-lockfile --filter ./apps/relay
cd apps/relay
npx tsc -p . --noEmit                 # Node relay
npx tsc -p tsconfig.worker.json       # Worker relay
```
