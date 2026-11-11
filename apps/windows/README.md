# Yorozu for Windows

The Windows client for Yorozu: a Tauri 2 app with a Rust core (`core`) that owns sockets, crypto and keys. Its v1 is cut down to pairing by pasted link and chat over the relay. So far the app is a shell: it installs, opens one window and shows the pairing screen, which isn't wired yet.

## Install

Every pull request and every merge to `main` that touches this directory builds an unsigned installer.

1. On GitHub, open the pull request's checks or the repository's Actions tab, and pick the newest "Windows installer" run (of the pull request, or of `main`).
2. Under Artifacts, download `yorozu-windows-<commit>` and unzip it. It holds `Yorozu_0.1.0_x64-setup.exe`. Artifacts are kept for 90 days; "Run workflow" on `main` builds a fresh one at any time.
3. Run the setup. The installer isn't signed, so Windows SmartScreen stops it: choose "More info", then "Run anyway".

The app needs Windows 10 version 1803 or later and the WebView2 runtime. Windows 11 has the runtime built in; on Windows 10 the setup downloads it if it's missing. The app installs for the current user only, into `%LOCALAPPDATA%\Yorozu`, without asking for administrator rights.

Uninstalling keeps the pairing, so a reinstall is still paired. To remove it as well, tick "Delete the application data" in the uninstaller.

## Docs live here

Windows documentation belongs in this directory. `apps/mcp/scripts/generate.ts` builds `apps/mcp/src/content.json` from the root `README.md`, the top-level `docs/*.md` and the plugin README, and a change to that file deploys the website.

## Run

From the repository root:

```sh
pnpm install --frozen-lockfile --filter @yorozu/relay
bash apps/windows/ci/core.sh
```

The install is for the conformance test (`conformance/host/`), which runs the real Node relay from `apps/relay` under Node 24 or later. The script also needs the toolchain pinned in `rust-toolchain.toml`, which rustup installs on first use. The pull request job `windows-core` in `.github/workflows/checks.yml` runs the same script.

The app itself (`app/`: the React UI, and the Tauri shell in `app/src-tauri`) is built, tested, installed and smoke-run on Windows by `ci/app.ps1`, which the "Windows installer" workflow runs. To check the shell on another system:

```sh
cd apps/windows/app && pnpm install --frozen-lockfile && pnpm build
cd .. && cargo test -p yorozu-windows
```

The UI has to be built first: the shell embeds `app/dist` at compile time.

## CI isolation

Nothing under `apps/windows/` triggers a release or a deploy. Release Mac covers `apps/**`, so it excludes this directory with `'!apps/windows/**'`; no other push workflow matches it. Nothing for Windows goes under `scripts/`, because a push there starts Release Mac.

## Commit and PR titles

A pull request scoped `(windows)`, or one whose every changed file is under `apps/windows/` or is `.github/workflows/windows-installer.yml`, must not raise the app's minor or major version or reach the release notes. In `scripts/version.sh` a `feat` raises the minor; a `!` or a `BREAKING CHANGE:`/`BREAKING-CHANGE:` footer raises the major, or the minor while the major is 0. `scripts/release_notes.sh` lists `feat`, `fix` and `perf`.

Its title and every non-merge commit subject must be one of:

- `chore(windows): …`, `build(windows): …`, `ci(windows): …`, `test(windows): …` or `docs(windows): …`;
- `Revert "…"`, which matches none of those patterns.

Forbidden: `!` in the title or a subject, and a line starting `BREAKING CHANGE: ` or `BREAKING-CHANGE: ` in the pull request body or a commit message.

The `release-guards` job runs `ci/commit-type.sh` on every pull request except Dependabot's, which the step's `if:` skips. It runs on the pull request's push events, not on a title or body edit, so the merger checks the title again before merging. `ci/commit-type.test.sh` tests the script.

## Rollback

W0 to W3 are the four stacked pull requests that added this client, titled with the suffixes (W0) to (W3).

1. Revert W3, then W2, then W1, one PR each, titled `Revert "<original title>"`.
2. One PR removes the `windows-core` job, the `windows_core` output and the `commit-type.sh` step from `checks.yml`, and deletes `.github/workflows/windows-installer.yml` if W1 was not reverted.
3. One PR deletes `apps/windows/**`. The directory is still excluded from Release Mac, so there is no release.
4. One PR removes the `'!apps/windows/**'` exclusion from `release-mac.yml` and W0's `OWNER_DECISIONS.md` and `docs/history/decisions-log.md` edits.

Never revert W0 as one commit: that would delete `apps/windows/**` in the same push that removes the exclusion and start Release Mac.
