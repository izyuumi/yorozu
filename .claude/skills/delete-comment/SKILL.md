---
name: delete-comment
description: Delete code comments the repo way — use when asked to delete or clean up comments, when `node scripts/comments.mjs check` fails, or to shrink the comment baseline.
---

# delete-comment

This repository keeps no code comments. Reasons live in ADRs (`docs/adr/`), hacks in GitHub issues, and everything else in the code itself.

## Classify each comment, then act

| Kind | What it is | Action |
|---|---|---|
| Tautology | Repeats what the code says (names, types, obvious steps). | Delete. |
| Excuse | Apologises for or explains a hack, workaround or TODO. | Delete, and file one GitHub issue that groups the related hacks (paths and symbols, no line numbers). |
| Stale | No longer true of the code, or history ("as before", "used to"). | Delete. |
| Decision Record | A why, constraint, measured number, platform or SDK behaviour, or invariant someone would need. | Move it into an ADR under `docs/adr/`: add it to the existing ADR whose area matches, else write the next numbered one and add its row to the index in `docs/adr/README.md`. |

A comment that mixes kinds is split: the true decision part goes to the ADR, the rest is deleted. ADRs follow the MADR-lite template in `docs/adr/README.md`, list paths with symbols (never line numbers) and say "the owner", never a name.

## What stays

- License headers (SPDX, `@license`, a leading copyright).
- Machine directives: everything matched by the `directives` array in `scripts/comments.mjs` (shebangs, `swift-tools-version`, lint and formatter suppressions, `@ts-…`, `SAFETY:` and others). Read the array; don't guess.
- Vendored and generated paths in its `ignore` list (e.g. the hero kit, pnpm lockfiles, `apps/relay/compat/`, `apps/web/.astro/`).

## Commands

    node scripts/comments.mjs list [--json] [path ...]   # every comment block, with its file
    node scripts/comments.mjs stats                      # comments, comment lines and directives per language
    node scripts/comments.mjs check                      # fails on a comment not in the baseline, or a stale baseline entry
    node scripts/comments.mjs baseline                   # rewrites scripts/comment-baseline.json from the tree
    node --test scripts/comments.test.mjs                # the scanner's own tests

## The ratchet

- `scripts/comment-baseline.json` lists the comments still allowed. It may only shrink.
- CI runs `node scripts/comments.mjs check --base <first parent>` in the `release-guards` job of `.github/workflows/checks.yml`; it fails on any baseline entry added since the base.
- After deleting comments, run `baseline` to drop their entries, and commit the smaller file.
- Never add entries by hand, and never run `baseline` to absorb a new comment: remove the comment instead.

## Rules for edits

- Remove comments only. Change no code token: no renames, reformatting or logic changes in the same commit.
- Keep a blank line only where it separated code before; don't leave dangling blank runs where a comment block was.
- Verify by building and running the repo's tests (AGENTS.md lists them: the client compile checks and `YorozuTests`, `swift test --package-path packages/YorozuVoice`, the relay's tests, the plugin's `node --test` tests), plus `node scripts/comments.mjs check`.

## Estimating lines shed

1. `node scripts/comments.mjs stats` before you start; note the comment-line totals.
2. Delete, then run `stats` again; the difference is the comment lines removed.
3. `git diff --stat` shows the total lines removed per file, blank lines included.
