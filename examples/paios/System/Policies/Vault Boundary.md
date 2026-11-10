# Vault Boundary Policy

## Rule

PAIOS owns `PAIOS/`. The user owns the remainder of the vault.

## Allowed without separate approval

- Read and search notes anywhere in the vault when relevant.
- Create, edit, rename, link, reorganize, migrate, or archive files inside `PAIOS/`.
- Create references inside PAIOS to notes elsewhere in the vault.

## Requires an explicit request

- Editing, renaming, moving, linking, front-matter changes, or deletion outside `PAIOS/`.
- Creating agent-maintained indexes or metadata inside another folder.
- Reorganizing user-managed notes even when the agent believes a better structure exists.

Approval for one outside edit is scoped to that requested edit and does not transfer ownership. If the user is asked for and directly grants approval a second time for the same materially matching outside-vault action and scope, that second approval becomes standing authorization for that exact action and scope under [[Adaptive Delegation]]. Record the active authorization in PAIOS and do not ask again for later matching edits. The authorization does not transfer ownership or expand to other files, folders, action types, or purposes. When an outside change is requested or covered by standing authority, preserve user formatting and minimize unrelated edits.
