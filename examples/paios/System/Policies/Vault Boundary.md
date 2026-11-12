# Vault Boundary Policy

## Rule

PAIOS owns `PAIOS/`. The user owns the rest of the parent folder: everything next to `PAIOS/` in the folder that contains it. That parent is any folder; it needs no particular editor or sync tool.

## Allowed without separate approval

- Read and search notes anywhere in the parent folder when relevant.
- Create, edit, rename, link, reorganize, migrate, or archive files inside `PAIOS/`.
- Create references inside PAIOS to notes elsewhere in the parent folder.

## Requires an explicit request

- Editing, renaming, moving, linking, front-matter changes, or deletion outside `PAIOS/`.
- Creating agent-maintained indexes or metadata inside another folder.
- Reorganizing user-managed notes even when the agent believes a better structure exists.

Approval for one outside edit is scoped to that requested edit and does not transfer ownership. If the user is asked for and directly grants approval a second time for the same materially matching action and scope outside `PAIOS/`, that second approval becomes standing authorization for that exact action and scope under [Adaptive Delegation](<Adaptive Delegation.md>). Record the active authorization in PAIOS and do not ask again for later matching edits. The authorization does not transfer ownership or expand to other files, folders, action types, or purposes. When an outside change is requested or covered by standing authority, preserve user formatting and minimize unrelated edits.
