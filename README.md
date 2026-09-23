# Yorozu

Out-of-box personal AI assistant for macOS, remote-controlled from iOS through a blind
end-to-end encrypted relay. Install, grant permissions once, scan one QR, start talking.

Downloads and privacy policy: <https://yorozu.yumi.to>

## How it works

The Mac app runs a Node sidecar that owns the conversation. Each thread is answered by one of
two backends, fixed when the thread is created:

| Thread agent | Answered by |
| --- | --- |
| `yorozu` (the default) | the OpenClaw Gateway (`@openclaw/gateway-client`) on loopback, which owns agent execution, providers, tools, permissions and PAIOS |
| `claude-code`, `codex` | a native CLI coding agent in-process, one session per thread, running in a folder under `~/Projects` |

The phone never reaches the Mac directly. Both ends meet at a relay that forwards ciphertext and
can read none of it: frames are ChaCha20-Poly1305 sealed under a key derived from an X25519
exchange, and the relay only ever sees signatures, lengths and timing.

A Mac is set up as either a **host** — it runs OpenClaw and the sidecar, owns the thread logs, and
is what everything else pairs with — or a **client**, which pairs with a host exactly as a phone
does and runs no agent of its own. A host's own chat skips the relay and talks to its sidecar over
a `0600` Unix socket.

See [docs/architecture.md](docs/architecture.md) for the pairing handshake, the relay protocol,
blind push notifications, and the thread/sync model.

## Layout

| Path | What it is |
| --- | --- |
| `apps/mac` | SwiftUI menu bar app and the `yorozu-native` helper (SwiftPM, macOS 15+) |
| `apps/ios` | SwiftUI iOS app, Tuist-generated project (iOS 18+) |
| `apps/relay` | blind websocket relay — a Cloudflare Worker and a self-hostable `ws` server |
| `apps/web` | the static `yorozu.yumi.to` site (Cloudflare, no build step) |
| `packages/runtime` | the Node sidecar: relay bridge, OpenClaw Gateway client, native agent runners |
| `packages/shared` | protocol event types shared by the TypeScript workspaces |
| `packages/shared-swift` | SwiftUI views and the chat model shared by both apps |

`packages/runtime` also carries a dormant in-house provider loop that ships but never runs — see
[docs/legacy-runtime.md](docs/legacy-runtime.md).

## Development

Requires Node 26+, pnpm 11, the latest stable Xcode, and [Tuist](https://tuist.dev) for the iOS
project. CI pins `latest-stable` because the hosted image's default Xcode can lag.

```sh
pnpm install
pnpm -r build
```

**Mac app** — the sidecar must be built first, and the package has two executables, so name the
one you want:

```sh
pnpm --filter @yorozu/runtime build
swift run --package-path apps/mac YorozuMac
```

That dials `wss://relay.yumi.to` and spawns `node ../../packages/runtime/dist/serve.js`.

TCC keys its grants on bundle ID and code signature, and a bare `swift run` binary has neither,
so every rebuild would look like a new app. For anything touching Accessibility, Screen Recording
or Automation, wrap the build in a signed bundle instead — grants then stick across rebuilds:

```sh
./scripts/dev-bundle.sh                 # writes apps/mac/.build/Yorozu.app, id to.yumi.yorozu.beta
open apps/mac/.build/Yorozu.app
```

**iOS app** — the Xcode project is generated from `apps/ios/Project.swift` and is not checked in:

```sh
tuist generate --no-open --path apps/ios
xcodebuild build -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

**Relay**, locally:

```sh
pnpm --filter @yorozu/relay build && node apps/relay/dist/index.js    # PORT, default 8787
```

### Tests

```sh
pnpm -r test                                              # runtime, shared, relay
env -u SDKROOT swift test --package-path packages/shared-swift
env -u SDKROOT swift test --package-path apps/mac
python3 scripts/test-release.py                           # isolated publication checks
```

The `env -u SDKROOT` is load-bearing — an inherited `SDKROOT` makes SwiftPM build against the
wrong SDK. `apps/ios/e2e/run.sh` is the end-to-end proof: it stands up a relay, a fake provider
and the sidecar, builds the app onto a throwaway simulator, and asserts a streamed reply and a
tool call reach the phone.

CI (`.github/workflows/ci.yml`) runs the Node, Swift, and iOS jobs on macOS, plus workflow
validation, ShellCheck, isolated release-publication tests, and a relay container build and
WebSocket check on Linux. Release Please
maintains a release PR; merging it runs the signed Mac release workflow.
See [the release guide](docs/releasing.md) for credentials and retries.

### Configuration

The main sidecar settings are:

| Variable | Default |
| --- | --- |
| `YOROZU_STATE_DIR` | `~/Library/Application Support/Yorozu` — keys, threads, devices, settings |
| `YOROZU_RELAY_URL` | `wss://relay.yumi.to` |
| `OPENCLAW_BIN` | `openclaw` on `PATH` |
| `YOROZU_PROJECTS_DIR` | `~/Projects` — the folders a coding-agent thread can start in |
| `YOROZU_RUNTIME_CMD` | unset — the Mac app runs the bundled sidecar, else the dev checkout it was built from. Set to override: split into words like `sh` would (quotes and backslashes, no expansion) and run directly, not through a shell, with the state directory as working directory, so use absolute paths |

Automatic thread titles also use the provider-chain settings described in
[the runtime guide](docs/legacy-runtime.md#provider-code-that-remains-live).

## Install

1. Download the newest DMG from <https://yorozu.yumi.to/mac>, drag **Yorozu** to Applications,
   and launch it. It is a menu bar app — it appears in the status bar, not the Dock.
2. Setup asks how this Mac will be used. **Host Yorozu on this Mac** runs OpenClaw and the agent
   here; **Connect to another Mac** makes it a client of a host you already have, and needs only
   a pairing code. You can change this later in Settings.

A host then continues:

3. Pair your devices from the code on screen — scan the QR with the iOS app, paste the copied
   string into it, or message the `yorozu://` link to yourself and tap it. This step can be
   skipped and redone from Settings → **Devices** → **Pair Another Device…**.
4. Grant the capabilities you want. Everything on the page is optional, each row deep-links to
   its System Settings pane and re-checks itself, and the same list is always available from
   Settings → **Permissions**. Start at Login and Never Sleep are on that page too — never-sleep
   is a `caffeinate` child process the app owns, and it dies with the app.
5. Install and configure OpenClaw. Yorozu connects to its loopback Gateway; provider credentials,
   models, tools, permissions, browser and PAIOS all stay in OpenClaw, never in Yorozu.

Updates are Sparkle and install themselves: the app checks hourly, downloads in the background,
and installs the next time it is not frontmost. State lives outside the bundle, so the room, the
keys and every paired phone survive an update.

## Documentation

| Document | What it covers |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | pairing and crypto, relay protocol, blind push, threads and sync, both apps |
| [docs/releasing.md](docs/releasing.md) | DMG build, notarization, Sparkle, TestFlight, self-hosting the relay |
| [docs/legacy-runtime.md](docs/legacy-runtime.md) | the dormant in-house provider loop and what it still backs |
| [docs/spec-v1.5.md](docs/spec-v1.5.md), [docs/spec-v1.html](docs/spec-v1.html) | the original product specs |
| [docs/app-store/listing-0.2.0.md](docs/app-store/listing-0.2.0.md) | App Store Connect listing copy |
| [docs/provider-mark-assets.md](docs/provider-mark-assets.md) | provenance of the provider marks |
| [docs/history/](docs/history/) | dated point-in-time records; not current documentation |

## License

MIT — see [LICENSE](LICENSE). Third-party marks and their terms are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
