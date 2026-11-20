# 0035. CI workflows: concurrency, allowed actions and plugin checks

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

GitHub Actions runs the checks, releases and promotion. The repository restricts which actions may run, and the plugin cannot be fully installed in CI because it depends on an OpenClaw source checkout.

## Decision

- Concurrency: GitHub keeps one pending run per group. Ordinary PR runs of Promote used to replace a pending Release Mac run, so `promote.yml`'s top-level group is conditional, and that condition must match the job's `if`.
- Allowed actions: the repository allows only GitHub-owned, verified and listed actions, so caching uses `actions/cache`, not `Swatinem/rust-cache`.
- Plugin checks without OpenClaw:
  - The whole plugin typechecks only against an OpenClaw source checkout (`tsconfig.json` extends it). The `standalone` job checks the files that import only node built-ins with the same strictness, without installing OpenClaw.
  - The plugin's pure files' tests import only node built-ins, so they run without OpenClaw or an install.
- `release-guards` runs the external TestFlight audit ([0032](0032-app-store-connect-and-testflight-tooling.md)), the comment ratchet and the Windows commit-type check ([0028](0028-windows-build-versioning-and-ci.md)).

## Consequences

- Plugin changes that touch OpenClaw-dependent files are only fully typechecked on a machine with an OpenClaw checkout.

## Where in the code

- `.github/workflows/promote.yml` — top-level `concurrency`
- `.github/workflows/windows-installer.yml` — `concurrency`, `actions/cache` step
- `.github/workflows/checks.yml` — `windows-core` cache step, `plugin`, `release-guards`
- `.github/workflows/plugin-typecheck.yml` — `standalone`
