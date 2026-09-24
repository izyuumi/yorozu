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
is what everything else pairs with — or a **client**, which pairs with host Macs exactly as a phone
does and runs no agent of its own. Clients keep all paired hosts connected, with one combined
thread list and search. Host labels and pickers appear only with multiple saved Macs; a single
Mac stays automatic. **Settings → Connection / Hosts** adds or manages connections; each thread and share
destination stays attached to its owning Mac. A host's own chat skips the relay and talks to its sidecar over
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
  -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
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
scripts/check-mac-multi-host.sh                           # isolated client/session lifecycle
scripts/test-ios-host-persistence.sh                      # legacy migration and host isolation
python3 scripts/test-release.py                           # isolated publication checks
```

The `env -u SDKROOT` is load-bearing — an inherited `SDKROOT` makes SwiftPM build against the
wrong SDK. `apps/ios/e2e/run.sh` is the end-to-end proof: it stands up a relay, a fake provider
and the sidecar, builds the app onto a throwaway simulator, and asserts a streamed reply and a
tool call reach the phone. It also pairs a second host, checks replies from both in the combined
list, then removes one and confirms the other remains usable.
Set `SIMULATOR_RUNTIME` to an installed runtime ID (for example,
`com.apple.CoreSimulator.SimRuntime.iOS-26-4`) to test a specific iOS release.

CI (`.github/workflows/ci.yml`) runs the Node, Swift, and iOS jobs on macOS, plus workflow
validation, ShellCheck, isolated release-publication tests, and a relay container build and
WebSocket check on Linux. Successful CI on `main` or `release/*` can produce a matching Mac
prerelease and TestFlight candidate. Release Please prepares version/changelog PRs; stable
publication explicitly promotes a tested candidate. All commits must be signed Conventional
Commits. See [the release workflow](docs/RELEASE_WORKFLOW.md) for the runbook and
[release setup](docs/releasing.md) for credentials.

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

Updates use Sparkle: the app checks hourly and downloads in the background. Automatic and
manual installs wait for this Mac's Yorozu agents to finish, then count down 10 idle seconds.
New tasks take priority; approval waits and unknown agent status keep the update queued.
Mac and phone show progress and offer **Postpone 1 hour**. Drafts and pending submissions
survive restart. See [queued updates](docs/queued-updates.md) for the full behavior.

Want changes from `main` before the next stable release? Install the [Mac beta](https://yorozu.yumi.to/beta), then enable **Settings → Updates → Receive beta updates**. Successful main CI publishes a signed, notarized candidate and matching TestFlight build. Turn the setting off to receive stable updates once the stable marketing version catches up; it does not downgrade an installed beta.

## Documentation

See the [documentation index](docs/README.md) for guides, design references, and App Store
material. For guided device setup, use [Start.md](Start.md).

## License

MIT — see [LICENSE](LICENSE). Third-party marks and their terms are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
