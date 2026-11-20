# 0028. Windows build, versioning and commit types

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

The Windows app shares the Mac and iOS apps' version but builds on its own runner with its own toolchain. Windows-only changes must not move the shared version or the release notes.

## Decision

- Line endings: `*.sh` is `eol=lf` in `apps/windows/.gitattributes`, so `bash ci/version.sh` runs on a default Git for Windows checkout (`core.autocrlf true`). The installer workflow also sets `core.autocrlf false` first, so the bash version scripts and `scripts/version.sh` keep LF on the runner. It checks out with `fetch-depth: 0` because `version.sh` needs the tags.
- `apps/windows/app` is its own pnpm workspace, so the repository's root workspace and lockfile stay untouched.
- `ci/core.sh`:
  - The "no aws-lc-rs" check accepts cargo's non-zero exit when no package matches; any other failure must not pass silently.
  - `cargo test` excludes the Tauri crate (`yorozu-windows`), which needs WebView2; `app.ps1` builds it on Windows.
  - The conformance step runs the client's expectations against the real Node relay and plugin Hub (after `pnpm install --filter @yorozu/relay`); the probe tests need `YOROZU_PROBE_BIN`.
- `ci/app.ps1`:
  - The version the built app must carry: in CI the stamp step exports `YOROZU_VERSION` (`scripts/version.sh` output), independent of the files it wrote; a local run takes it from `tauri.conf.json`. Either way `tauri.conf.json` and `package.json` must hold it. The installer name, the product version and the smoke checks all use it.
  - It excludes `yorozu-probe`, a test-only binary with the plaintext store; `core.sh` builds and runs it.
  - CI's cache restores `apps/windows/target`, so any old bundle is removed first: only this build's installer may pass.
- The "checked-in Windows version vs the latest stable release" step only warns: the build stamps the shared version anyway, so stale checked-in files never fail the job.
- `ci/version.sh` reads, writes and checks the Windows app's version, which matches the Mac and iOS apps'. It lives in four places: `app/package.json`, `app/src-tauri/tauri.conf.json`, `Cargo.toml` (`[workspace.package]`) and `Cargo.lock` (the workspace members).
  - Subcommands: `get` (if all places agree), `set <x.y.z>` (changes only the version lines), `check <x.y.z>`, `stable` (latest stable tag without the v), `shared` (what `scripts/version.sh` gives Mac and iOS builds of this commit).
  - Each awk program finds the one version line of its place; with `v` set it rewrites that line's quoted value, keeping any trailing bytes such as a CR, otherwise it prints the value.
  - awk writes a temp file (awk has no portable in-place edit) and `cat` copies it into the original, which keeps the original's mode.
  - `set` stops before writing anything unless every place has a version line to rewrite.
  - The test's `changed` helper treats `git diff --no-index` exit 1 as "files differ"; anything above 1 is a git error and stops the test.
  - The installer name and the smoke line use the same version: `tauri.conf.json`'s and the workspace's.
- Commit types (`ci/commit-type.sh`): keeps Windows-only pull requests out of the app's version and release notes. Inputs are `TITLE`, `BODY` (may be empty) and `BASE`; it checks `BASE..HEAD`.
  - Allowed: the five Windows types, or any revert. A `Revert "…"` subject matches neither the feat nor the breaking pattern in `scripts/version.sh` and does not start with feat, fix or perf, so it moves neither the minor or major version nor the release notes.
  - Paths are listed with `core.quotePath=false` and `--no-renames`, so non-ASCII paths are unquoted and a rename lists both sides.
  - Subjects are captured first, so a git failure stops the script.
  - The script rejects Dependabot's title; the workflow skips Dependabot's pull requests before it runs.
  - In CI, `BASE` is `HEAD`'s first parent: `HEAD` is the merge ref, so its first parent is the base it was built on, while `base.sha` can be older.
- Pull request runs of the installer workflow cancel each other; every commit on `main` gets its own run.

## Consequences

- The Windows version never drifts from the shared one in shipped builds.

## Where in the code

- `apps/windows/.gitattributes`
- `apps/windows/app/pnpm-workspace.yaml`
- `apps/windows/ci/core.sh`, `apps/windows/ci/app.ps1`
- `apps/windows/ci/version.sh` — `json_awk`, `toml_awk`, `lock_awk`, `write_place`, `set`
- `apps/windows/ci/version.test.sh` — `changed`
- `apps/windows/ci/commit-type.sh`, `apps/windows/ci/commit-type.test.sh`
- `apps/windows/core/tests/version.rs`
- `.github/workflows/windows-installer.yml`
- `.github/workflows/checks.yml` — `release-guards` (Windows commit types)
