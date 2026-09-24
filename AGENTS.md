# Repository instructions

## Releases and commits

Follow [docs/RELEASE_WORKFLOW.md](docs/RELEASE_WORKFLOW.md) for release-related work,
including versioning, candidate builds, release notes, beta/stable promotion, and hotfixes.
All commits must use Conventional Commit messages and be cryptographically signed.

## Parallel feature work and cleanup

- Before starting a new feature, fetch the target base branch and create a dedicated Git
  worktree with a new `codex/<feature>` branch. Give each agent working on an independent
  feature its own worktree and branch so agents can work simultaneously.
- Work only in your task's worktree. Do not switch, reset, or overwrite another agent's
  checkout or the user's working changes.
- After creating a PR, verify all intended changes are committed and pushed. Once the
  worktree is clean and no agent needs it, remove it with `git worktree remove <path>`.
  Never force removal or discard uncommitted work to clean up.
- Keep the PR's source branch while the PR is open. After it is merged or deliberately
  closed, delete the task's local and remote branches only if their work is preserved and
  no active worktree or agent uses them. Run `git fetch --prune` for the relevant remote to
  remove stale remote-tracking references.
