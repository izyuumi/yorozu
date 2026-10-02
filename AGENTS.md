# Repository instructions

## Releases and commits

Follow [docs/RELEASE_WORKFLOW.md](docs/RELEASE_WORKFLOW.md) for release-related work,
including versioning, candidate builds, release notes, beta/stable promotion, and hotfixes.
All commits must use Conventional Commit messages and be cryptographically signed.

## UI layout

Follow [docs/ui-layout.md](docs/ui-layout.md): size from the container with the platform's
native mechanisms, never from a hard-coded number, unless building a custom component that
owns its own geometry.

## Commands

`pnpm check` builds and tests every JS package (if `pnpm` is missing, use `corepack pnpm`);
`pnpm test:swift` runs the Swift tests (`env -u SDKROOT` is required).
iOS UI tests: [apps/ios/Tests/UITests/README.md](apps/ios/Tests/UITests/README.md).

## OpenClaw channel plugin

Before changing `packages/openclaw-channel`, read its
[Development](packages/openclaw-channel/README.md#development) section.

## Worktrees

One worktree and branch per task, named for the topic with no prefix; never touch another
checkout. After the PR is pushed and the worktree is clean, `git worktree remove` it (never
`--force`); delete merged branches and `git fetch --prune`.
