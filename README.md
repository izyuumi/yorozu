# Yorozu

Yorozu is an end-to-end-encrypted chat channel for OpenClaw: a native app for iPhone, iPad and Mac that talks to your own OpenClaw agent. OpenClaw runs the agent, sessions, memory and cron; Yorozu only carries messages.

## Components

- `plugins/openclaw-yorozu`: the TypeScript channel plugin inside the OpenClaw Gateway. Holds the host keys and connects out to the relay.
- `apps/relay`: the relay, a Cloudflare Worker that passes sealed frames between plugin and devices and sends push.
- `apps/ios`: the SwiftUI client for iPhone, iPad and Mac (Tuist project).
- `packages/YorozuWire`: the shared Swift wire package.
- `apps/web`: the website, yorozu.yumi.to (Astro on Cloudflare): `pnpm --filter @yorozu/web dev|build|test`; deploys on merge (`deploy-web.yml`).

## Install

```sh
openclaw plugins install --link plugins/openclaw-yorozu --force --accept-capabilities
openclaw gateway restart
openclaw yorozu pair          # scan the QR, or paste the link, in the app
```

Full steps, config keys and troubleshooting: [docs/setup.md](docs/setup.md).

## Build

```sh
mise install                                     # Tuist, pinned in mise.toml
swift build --package-path packages/YorozuWire   # the wire package
scripts/build_native.sh [--restart]              # the Mac app, into /Applications/Yorozu.app
pnpm install && pnpm --filter @yorozu/relay test # the relay's typecheck and tests
```

Compile checks, releases and CI: [docs/release.md](docs/release.md).

## Docs

- [Status](docs/status.md)
- [Architecture](docs/architecture.md)
- [Setup](docs/setup.md)
- [Release](docs/release.md)
- [Plugin reference](plugins/openclaw-yorozu/README.md)
- [OpenClaw channel SDK facts](docs/openclaw-channel.md)
- [Wire contract](docs/ios-relay-contract.md)
- [Owner decisions](OWNER_DECISIONS.md)
- [Working rules](AGENTS.md)

## License

MIT, see [LICENSE](LICENSE).
