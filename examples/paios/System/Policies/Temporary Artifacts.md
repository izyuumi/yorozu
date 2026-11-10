# Temporary Artifacts Policy

## Purpose

Agents clean up after themselves. Every screenshot, scratch file, worktree, download, script, or directory an agent creates for its own use is that agent's responsibility to remove. Leaving it behind is an incomplete task, same as leaving a browser tab open.

Why: agent scratch (screenshots, renders, merged worktrees, downloaded pages) piles up quickly on owner-visible surfaces such as the desktop and downloads folder if no rule says who removes it.

## Rules

1. **Whatever you create for yourself, you delete.** Applies to screenshots, frame captures, OCR dumps, intermediate HTML/PNG renders, QR images, test logs, scratch Markdown, downloaded pages, throwaway scripts, `node_modules` from spikes, and git worktrees whose branch is merged or abandoned.
2. **Never create scratch on owner-visible surfaces.** `~/Desktop`, `~/Downloads`, `~/Documents`, `~/Pictures`, and the synced vault outside `PAIOS/` belong to the owner. Screen-capture and computer-use tools must write somewhere agent-owned, or the agent moves the output out immediately after reading. If a tool defaults to the desktop, pass an explicit output path.
3. **Use one scratch location per task and name it.** Prefer `mktemp -d` under `$TMPDIR`, or `$PAIOS_AGENT_TMP/<task>-XXXXXX` if you configure one. Workspace `tmp/` is acceptable only for the duration of the task. Do not invent new top-level scratch directories in the workspace.
4. **Delete at step end, not task end.** Remove a capture once it has been read. Remove a worktree once its branch is merged. Remove a render once the published report is verified.
5. **Delete on failure too.** Error, abandonment, or interruption still ends with cleanup before reporting back. Aborted tasks are the main source of debris.
6. **Use `trash`, never `rm -rf`, for anything outside a `mktemp` directory.** Recoverable beats gone.
7. **Never delete what you did not create.** Owner files, other agents' live scratch, lock files, and dated `backups/` or `archive/` directories stay unless the owner explicitly asks.
8. **Delegation passes the duty down.** Every worker spec (for example a coding agent's prompt) states that the worker removes its own scratch and worktree before reporting done. The parent verifies on return.
9. **Report what stays.** If an artifact must persist (a report source, a worktree with unmerged work, a file the owner asked to see), say so and why in the completion message.

## What counts as durable, not temporary

- Published report sources until the report is superseded.
- Git worktrees whose branch has unmerged commits.
- PAIOS session journals, Reports, and Attachments.
- Anything the owner asked to keep.

## Before reporting done

Check: no captures on the desktop, no scratch left in `tmp/` from this task, no merged worktrees, no stray files in the downloads folder. If a check cannot be run, say so.
