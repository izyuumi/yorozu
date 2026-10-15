# Yorozu v2

Yorozu is an OpenClaw chat channel (#415): a TypeScript channel plugin inside the owner's OpenClaw Gateway (`plugins/openclaw-yorozu`) talks over the end-to-end-encrypted relay to one SwiftUI client app for iPhone, iPad and Mac (`apps/ios`), and OpenClaw runs the agent, sessions, memory and cron. Yorozu itself runs no agent logic. This is branch `projectx` of a public repository, and v1 lives on `main`.

## Rules

- Write Swift wherever possible, for a native feel, and never Python. Code that has to live in another ecosystem uses its language (for example a TypeScript plugin inside the OpenClaw Gateway); a separate long-running background process of our own is Rust.
- Tests and CI are on hold for this branch until the owner lifts it. Verify by compiling (commands below) and by running the app; leave `tests/`, `scripts/test_native.sh` and CI config alone.
- The repository is public. Commit code and docs only: say "the owner", write paths as `~/…` or repo-relative, and keep names, emails, secrets, key IDs and personal notes out of files and commit messages. Commit only your own changes; the owner's uncommitted files stay as they are.
- Commit messages follow Conventional Commits and every commit is signed (signing is configured).
- Feature work: fetch the base branch, then work in a dedicated git worktree on a new branch named for the topic alone, one per independent feature. Work only in your own worktree. Once its work is merged and the tree is clean, `git worktree remove` it (plain, without `--force`) and delete the branch if nothing else uses it.
- In an OpenClaw-managed worktree (branch `openclaw/…`), the task contract replaces the feature-work rule: stay in that worktree and merge, push and restart exactly as the contract says.
- One app: `/Applications/Yorozu.app`, the client's Mac build (bundle id `to.yumi.yorozu.ios`), rebuilt in place by `scripts/build_native.sh` from the main checkout (owner, 2026-10-12); never make a second copy with its bundle id: any other Mac build runs from derived data under an id of its own ([docs/release.md](docs/release.md#compile-checks)).
- Upload to TestFlight (`scripts/upload_ios.sh --confirm`) only when the owner asks for that upload: each upload uses up its build number for good.
- Approved cleanup of build outputs and stale app copies: confirm the list, then `rm -rf` it.
- UI layout: size views from their container with the platform's native mechanisms; fixed numbers belong only inside a custom component that owns its geometry. Read [docs/ui-layout.md](docs/ui-layout.md) before changing SwiftUI layout in `apps/ios`.

## Build and run

```sh
mise install                                    # Tuist, at the version pinned in mise.toml
swift build --package-path packages/YorozuWire   # the wire package only
scripts/build_native.sh                         # the client's Mac app, into /Applications/Yorozu.app
scripts/build_native.sh --restart               # the same, relaunched
```

The client app (`apps/ios`: iPhone, iPad and Mac) compiles only through its Tuist-generated Xcode project: `build_native.sh` for the Mac app in `/Applications`, the compile checks in [docs/release.md](docs/release.md#compile-checks) otherwise. The plugin typechecks per [its README](plugins/openclaw-yorozu/README.md#typecheck).

## Docs

Read these yourself when their topic comes up; nobody will paste them in. When the owner asks about the app, its state, plans or behaviour, or before starting any work, first read docs/status.md and OWNER_DECISIONS.md. Read the others when their area is involved. Open owner steps are in the newest comment of the latest open `projectx` queue issue (`gh issue list --label projectx`).

- Status: [docs/status.md](docs/status.md) has what is done and how it was checked, open items with their defaults, the roadmap and known limits. Read first when discussing the app or choosing or scoping work.
- Architecture: [docs/architecture.md](docs/architecture.md) covers the plugin, relay and client, the session mapping, the message flow and the data on each side. Read before changing `plugins/openclaw-yorozu`, `apps/ios` or `packages/YorozuWire`.
- Plugin: [plugins/openclaw-yorozu/README.md](plugins/openclaw-yorozu/README.md) is the reference for each plugin file's behaviour, and [docs/openclaw-channel.md](docs/openclaw-channel.md) has the OpenClaw SDK facts behind it and the Gateway gotchas. Read before changing the plugin or probing the Gateway.
- Relay wire: [docs/ios-relay-contract.md](docs/ios-relay-contract.md) is the wire v3 client ⇄ plugin contract (Noise handshake, envelope, kinds, vectors). Read before changing any message between client and plugin, or `apps/relay`.
- Setup: [docs/setup.md](docs/setup.md) covers tools, plugin install, config keys, pairing, devices, signing, push, credentials and troubleshooting. Read when installing, pairing, or when a config key, path or machine requirement is in question.
- Release: [docs/release.md](docs/release.md) covers versions, the Mac build, TestFlight uploads, build numbers and the compile checks. Read before bumping a version, building or uploading.
- Owner decisions: [OWNER_DECISIONS.md](OWNER_DECISIONS.md) records every product decision, dated. Read first when discussing the app, and check it before changing product behaviour. History is in [docs/history/decisions-log.md](docs/history/decisions-log.md).
- History: `docs/history/` keeps the removed secretary system's docs (architecture, setup, status, Gateway, Hermes, cua) and the v2 wire. Read only when asked about the old system.
