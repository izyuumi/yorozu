# Yorozu v2

Native SwiftUI personal assistant for macOS, backed by an OpenClaw Gateway.

## Current

- **Native Mac app**: SwiftUI (macOS 15+) generated with [Tuist](https://tuist.dev) from
  `apps/mac/Project.swift`. The UI is in `Sources/ProjectXApp` and the engine, store and harnesses are in `Sources/ProjectXCore`.
- **Secretary and topic sub-chats**: one main conversation. A secretary model replies directly
  or delegates substantive work to a topic. Each topic is a sub-chat with its own
  persistent worker session, which you can steer, correct, retry or stop.
- **OpenClaw workers**: thinking work runs in the topic's OpenClaw session. Coding work runs as
  Claude Code or Codex inside OpenClaw. Each coding worker gets its own git worktree, cut
  from `projectx`.
- **Markdown memory**: user-owned Markdown files in `~/Yorozu/memory`, plus a rebuildable
  SQLite index in `~/Library/Caches/<bundle id>`. Private app state lives in
  `~/Library/Application Support/<bundle id>`.
- **Signing**: Developer ID with hardened runtime, using the same bundle ID as v1, so it updates the existing app in place.

## Build and run

The first build resolves Swift packages and can take a few minutes.

```sh
swift build                          # compile check
scripts/build_native.sh              # tuist generate + xcodebuild → build/Yorozu.app
scripts/build_native.sh --restart    # also quits the running dev app, swaps the bundle, relaunches
```

The script only replaces `build/Yorozu.app` and never touches `/Applications/Yorozu.app`.
`version.txt` sets the marketing version.

`PROJECTX_MODE` selects `live` (default), `fixture` or `offline`; invalid values fall back to offline. Live mode
uses the dedicated `projectx` OpenClaw agent. Set `PROJECTX_TRANSPORT=native` to use the native
Gateway client instead of the CLI transport.

## Roadmap

1. **v0.6.0: iOS relay client**: remote control from iOS through the end-to-end encrypted relay.
2. **cua computer use**: let workers drive Mac apps.

## License

MIT, see [LICENSE](LICENSE).
