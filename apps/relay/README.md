# Relay

The Yorozu relay: a Cloudflare Worker with one Durable Object `Room` per host (`src/worker.ts`),
and a Node variant of the same protocol (`src/index.ts`, `Dockerfile`). It routes Ed25519-signed
envelopes and forwards their sealed payloads unread; `src/protocol.ts` holds the shared limits and
envelope shapes. The phone-side contract is [docs/ios-relay-contract.md](../../docs/ios-relay-contract.md).

## Source of truth: `main`

The deployed relay serves v1 users on `main`, so `main` stays the single source of truth until the
owner decides otherwise:

- Deploys go from `main` only, never from `projectx`.
- This copy on `projectx` is `apps/relay/` from `main`, unchanged, so v3 needs can be checked against
  it here. It is not kept in sync automatically; refresh it with `git checkout origin/main -- apps/relay`.
- A relay change is a pull request to `main` that stays backward compatible with v1, then copied here.

## Typecheck on `projectx`

`main` installs this package through its pnpm workspace and lockfile; `projectx` has neither, so
install it standalone, as the `Dockerfile` does:

```sh
cd apps/relay
npm install --no-package-lock --ignore-scripts
npx tsc -p . --noEmit                 # Node relay
npx tsc -p tsconfig.worker.json       # Worker relay
```
