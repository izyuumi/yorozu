# 0012. App lifecycle, status and stored-names migration

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

`AppModel` drives connection state, the outage banner, stall detection and scene changes. The app also moved its on-disk folders to new names while other code reads and deletes them concurrently.

## Decision

- Outage banner (`OutageMemory`): `.hostOffline` is an outage; `.offline` is one unless the app stopped the transport; `.connecting` and `.handshaking` keep the last outage; anything else clears it.
- The chat and the list can show the same banner side by side; VoiceOver hears it once.
- Stall detection: a running turn's stall clock restarts on progress. Typing keepalives alone don't count as progress.
- Scene lifecycle: a return to the foreground bumps `generation`, which also invalidates background-wake snapshots. The scene phase handler's `#if !os(iOS)` step is left out on iOS, to preserve the background visit set by `enterBackground()`.
- Observation: `AppModel.queue` mirrors its `loadingOlder` into the observed property, so queue churn alone redraws nothing.
- Stored-names migration:
  - Writes always use the new name; `StoredNames` resolves reads until migration completes.
  - `StoredNames` is shared by the background migration and foreground reads and deletes. Copies happen outside the lock; committing and deleting share it so a wipe cannot resurrect a staged file.
  - Listing reads old first and new second, and reads try new first, which also covers a file committed between the two listings.
  - If a failed open lost its file to the migration, it retries once at the new URL.
  - Delete removes the old directory first: if deletion fails, the new copy is kept too rather than resurrecting old data.
  - With no old directory, migration makes no filesystem changes, not even creating the new directory.
  - The tree walk never follows symbolic links and never deletes an old tree containing entries it didn't handle.
  - `moveItem` never overwrites, so after it the destination is checked: a concurrent writer may have won the name.

## Consequences

- The migration can run at any time without losing or resurrecting data.

## Where in the code

- `apps/ios/Sources/Client/OutageMemory.swift` — `OutageMemory.apply(_:)`
- `apps/ios/Sources/YorozuIOS/StatusBanner.swift` — `StatusBanner.announce(_:)`
- `apps/ios/Sources/Client/AppModel.swift` — `progressed(_:)`, `queue`
- `apps/ios/Sources/Client/SceneLifecycle.swift` — `SceneLifecycle`
- `apps/ios/Sources/YorozuIOS/Root.swift` — scene phase handler
- `apps/ios/Sources/Client/StoredNamesMigration.swift` — `StoredNames`, `fileNames(_:)`, `withLocal(_:in:_:)`, delete, migrate
- `apps/ios/Sources/Client/SupportDirectory.swift` — support directory helper
