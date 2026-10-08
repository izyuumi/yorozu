# Yorozu v2

Yorozu is a native macOS personal assistant: one conversation with a secretary model that answers quick turns and hands substantive work to background workers in topic sub-chats, backed by a local OpenClaw Gateway and user-owned Markdown memory. An iOS app talks to the Mac through an end-to-end-encrypted relay; this is branch `projectx` of a public repository, and v1 lives on `main`.

## Rules

- Write everything in Swift; a separate long-running background process, if one is ever needed, is Rust.
- Tests and CI are on hold for this branch until the owner lifts it. Verify by compiling (commands below) and by running the app; leave `tests/`, `scripts/test_native.sh` and CI config alone.
- The repository is public. Commit code and docs only: say "the owner", write paths as `~/…` or repo-relative, and keep names, emails, secrets, key IDs and personal notes out of files and commit messages. Commit only your own changes; the owner's uncommitted files stay as they are.
- Commit messages follow Conventional Commits and every commit is signed (signing is configured).
- Feature work: fetch the base branch, then work in a dedicated git worktree on a new branch named for the topic alone, one per independent feature. Work only in your own worktree. Once its work is merged and the tree is clean, `git worktree remove` it (plain, without `--force`) and delete the branch if nothing else uses it.
- In an OpenClaw-managed worktree (branch `openclaw/…`), the task contract replaces the feature-work rule: stay in that worktree and merge, push and restart exactly as the contract says.
- One dev app: `build/Yorozu.app` in the main checkout, rebuilt in place by `scripts/build_native.sh`; leave `/Applications/Yorozu.app` and other bundles alone.
- Upload to TestFlight (`scripts/upload_ios.sh --confirm`) only when the owner asks for that upload: each upload uses up its build number for good.
- Approved cleanup of build outputs and stale app copies: confirm the list, then `rm -rf` it.
- UI layout: size views from their container with the platform's native mechanisms; fixed numbers belong only inside a custom component that owns its geometry. Read [docs/ui-layout.md](docs/ui-layout.md) before changing SwiftUI layout in `Sources/ProjectXApp` or `apps/ios`.

## Build and run

```sh
mise install                        # Tuist, at the version pinned in mise.toml
swift build                         # Sources/ProjectXCore only
scripts/build_native.sh             # build/Yorozu.app
scripts/build_native.sh --restart   # build/Yorozu.app, relaunched
```

App code (`Sources/ProjectXApp`) compiles only through `build_native.sh`; iOS code only through the iOS Xcode project ([docs/release.md](docs/release.md#ios-compile-check-without-uploading)).

## Docs

- Status: [docs/status.md](docs/status.md) has what is done, in progress or stuck, the roadmap, and open items with their defaults. Read when choosing or scoping work.
- Architecture: [docs/architecture.md](docs/architecture.md) covers components, message flows, routing, workers, memory and state names. Read before changing `Sources/`.
- Gateway: [docs/openclaw-integration.md](docs/openclaw-integration.md) covers calls, session keys, timeouts and gotchas. Read before touching `Harness.swift` or `NativeGateway.swift`, or before probing the Gateway.
- Hermes: [docs/hermes-integration.md](docs/hermes-integration.md) covers calls, profiles, session and run ids, limits and the OpenClaw migration hazards. Read before touching `Hermes*.swift` or before probing Hermes.
- Relay wire: [docs/ios-relay-contract.md](docs/ios-relay-contract.md) is the Mac ⇄ phone contract. Read before changing `Sources/ProjectXApp/Relay`, `apps/ios` or `packages/YorozuWire`.
- Setup: [docs/setup.md](docs/setup.md) covers tools, the OpenClaw agent entry, models, signing, credentials, Keychain items, data paths and environment variables. Read when a path, variable or machine requirement is in question.
- Release: [docs/release.md](docs/release.md) covers versions, Mac rebuilds, TestFlight uploads, build numbers and the iOS compile check. Read before bumping a version or uploading.
- Computer use: [docs/cua-integration.md](docs/cua-integration.md) is the R3 design. Read before cua work.
- Owner decisions: [OWNER_DECISIONS.md](OWNER_DECISIONS.md). Check before changing product behaviour.
