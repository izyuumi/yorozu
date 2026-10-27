# Yorozu v2

Yorozu is a chat channel for OpenClaw: native apps for iPhone, iPad and Mac that talk to your own OpenClaw agent, like Signal or Telegram would, end to end encrypted.

- **A channel plugin** (`plugins/openclaw-yorozu`, TypeScript) runs inside your OpenClaw Gateway. It holds the host keys and connects out to the relay; the Gateway opens no port.
- **One SwiftUI app** (`apps/ios`) for iPhone, iPad and Mac: conversations, history from the Gateway's transcripts, tool calls shown collapsed, attachments, push, read marks synced across devices, and a Crons tab.
- **The relay** passes sealed boxes between them. Every connection runs a Noise IK handshake, and push previews are sealed per device.
- **OpenClaw does the rest**: the agent, its sessions, memory and cron. Each Yorozu conversation is one OpenClaw thread session.

Yorozu 0.9 lives on `main`. Older versions are in the history and the GitHub releases.

## Start

```sh
openclaw plugins install --link plugins/openclaw-yorozu --force --accept-capabilities
openclaw gateway restart
openclaw yorozu pair          # scan the QR, or paste the link, in the app
```

The full steps, config keys and troubleshooting: [docs/setup.md](docs/setup.md). Building the client: [docs/release.md](docs/release.md).

## Docs

- [Status](docs/status.md)
- [Architecture](docs/architecture.md)
- [Setup](docs/setup.md)
- [Release](docs/release.md)
- [Plugin reference](plugins/openclaw-yorozu/README.md)
- [OpenClaw channel SDK facts](docs/openclaw-channel.md)
- [Wire v3 contract](docs/ios-relay-contract.md)
- [Owner decisions](OWNER_DECISIONS.md)
- [Working rules](AGENTS.md)

## License

MIT, see [LICENSE](LICENSE).
