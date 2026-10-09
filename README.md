# Yorozu v2

A native macOS personal assistant backed by a local OpenClaw Gateway, with an iPhone client.

- **One conversation.** A secretary model answers quick turns itself and hands substantive work to background workers. Each topic gets a sub-chat you can inspect while you keep talking.
- **Workers.** Thinking work runs in OpenClaw sessions; coding work runs Claude Code or Codex in managed git worktrees.
- **Memory you own.** Useful facts and knowledge are saved automatically as Markdown files in `~/Yorozu/memory`, with a rebuildable search index.
- **iPhone.** Pair from the Mac's Pair a Client Device sheet; messages travel through an end-to-end-encrypted relay.

This branch, `projectx`, is Yorozu v2. Yorozu v1 lives on `main`.

## Build

```sh
mise install                 # Tuist
scripts/build_native.sh      # builds build/Yorozu.app
```

Requirements: [docs/setup.md](docs/setup.md). Releases: [docs/release.md](docs/release.md).

## Docs

- [Status and roadmap](docs/status.md)
- [Architecture](docs/architecture.md)
- [OpenClaw integration](docs/openclaw-integration.md)
- [iOS relay contract](docs/ios-relay-contract.md)
- [cua integration (R3 design)](docs/cua-integration.md)
- [Owner decisions](OWNER_DECISIONS.md)
- [Working rules](AGENTS.md)

## License

MIT, see [LICENSE](LICENSE).
