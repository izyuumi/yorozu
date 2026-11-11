# Yorozu for Windows

The Windows client for Yorozu, built with Tauri 2. It is in progress: so far this directory holds only the Rust workspace (`core`, the platform-neutral crate that will carry the wire, pairing and state machines) and the CI isolation check.

## Docs live here

Windows documentation belongs in this directory, not in `docs/` or the root `README.md`. Those feed `apps/mcp/src/content.json`, and a change to that file deploys the website.

## Run

From the repository root:

```sh
cargo test --manifest-path apps/windows/Cargo.toml --workspace
node apps/windows/scripts/filter-dry-run.mjs
```

The pull request check (`windows` in `.github/workflows/checks.yml`) runs both on `windows-latest`, then builds the workspace.

## CI isolation

Nothing under `apps/windows/` triggers a release or a deploy. Release Mac covers `apps/**`, so it excludes this directory with `'!apps/windows/**'`; the other push workflows never matched it.

`scripts/filter-dry-run.mjs` enforces the rule. It reads the `on: push` filters of every workflow in `.github/workflows/`, applies GitHub's path matching to sample files, and fails if a Windows path would start a push workflow, or if `apps/ios` would stop starting Release iOS and Release Mac. Run it after changing any workflow's `paths`.
